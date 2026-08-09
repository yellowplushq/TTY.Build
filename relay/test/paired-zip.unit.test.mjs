import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { appleDoubleWithPairingCode, injectPairingCode } from "../src/paired-zip.mjs";
import { handlePairedDownload } from "../src/site.mjs";

const encoder = new TextEncoder();

function crc32(bytes) {
  let crc = 0xFFFFFFFF;
  for (const byte of bytes) {
    crc ^= byte;
    for (let k = 0; k < 8; k += 1) {
      crc = crc & 1 ? 0xEDB88320 ^ (crc >>> 1) : crc >>> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

/// Minimal stored-entry zip builder, enough to look like the release
/// archive: [local entries][central directory][EOCD].
function buildZip(entries) {
  const chunks = [];
  const central = [];
  let offset = 0;
  for (const [name, content] of entries) {
    const nameBytes = encoder.encode(name);
    const data = encoder.encode(content);
    const checksum = crc32(data);
    const local = new Uint8Array(30 + nameBytes.length + data.length);
    const view = new DataView(local.buffer);
    view.setUint32(0, 0x04034B50, true);
    view.setUint16(4, 20, true);
    view.setUint32(14, checksum, true);
    view.setUint32(18, data.length, true);
    view.setUint32(22, data.length, true);
    view.setUint16(26, nameBytes.length, true);
    local.set(nameBytes, 30);
    local.set(data, 30 + nameBytes.length);
    chunks.push(local);

    const entry = new Uint8Array(46 + nameBytes.length);
    const entryView = new DataView(entry.buffer);
    entryView.setUint32(0, 0x02014B50, true);
    entryView.setUint16(4, 20, true);
    entryView.setUint16(6, 20, true);
    entryView.setUint32(16, checksum, true);
    entryView.setUint32(20, data.length, true);
    entryView.setUint32(24, data.length, true);
    entryView.setUint16(28, nameBytes.length, true);
    entryView.setUint32(42, offset, true);
    entry.set(nameBytes, 46);
    central.push(entry);
    offset += local.length;
  }
  const centralSize = central.reduce((sum, entry) => sum + entry.length, 0);
  const eocd = new Uint8Array(22);
  const eocdView = new DataView(eocd.buffer);
  eocdView.setUint32(0, 0x06054B50, true);
  eocdView.setUint16(8, entries.length, true);
  eocdView.setUint16(10, entries.length, true);
  eocdView.setUint32(12, centralSize, true);
  eocdView.setUint32(16, offset, true);
  const out = new Uint8Array(offset + centralSize + 22);
  let cursor = 0;
  for (const chunk of [...chunks, ...central, eocd]) {
    out.set(chunk, cursor);
    cursor += chunk.length;
  }
  return out;
}

function readEOCD(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  for (let at = bytes.length - 22; at >= 0; at -= 1) {
    if (view.getUint32(at, true) === 0x06054B50) {
      return {
        entries: view.getUint16(at + 10, true),
        centralSize: view.getUint32(at + 12, true),
        centralOffset: view.getUint32(at + 16, true),
      };
    }
  }
  throw new Error("EOCD missing");
}

const RELEASE_LIKE = [
  ["Pedals.app/", ""],
  ["Pedals.app/Contents/", ""],
  ["Pedals.app/Contents/Info.plist", "signed-bytes-do-not-touch"],
];

test("injection appends the AppleDouble entry without moving original bytes", () => {
  const original = buildZip(RELEASE_LIKE);
  const injected = injectPairingCode(original, "90285513");

  const before = readEOCD(original);
  const after = readEOCD(injected);
  assert.equal(after.entries, before.entries + 1);
  // Original local entries are byte-identical at the same offsets.
  assert.deepEqual(
    injected.subarray(0, before.centralOffset),
    original.subarray(0, before.centralOffset),
  );
  const text = new TextDecoder("latin1").decode(injected);
  assert.match(text, /__MACOSX\/\._Pedals\.app/);
  assert.match(text, /build\.air\.pedals\.pairing-code/);
  assert.match(text, /90285513/);
});

test("the AppleDouble payload carries exactly the pairing attribute", () => {
  const payload = appleDoubleWithPairingCode("01234567");
  const view = new DataView(payload.buffer);
  assert.equal(view.getUint32(0), 0x00051607);
  assert.equal(view.getUint32(4), 0x00020000);
  const text = new TextDecoder("latin1").decode(payload);
  assert.match(text, /ATTR/);
  assert.match(text, /build\.air\.pedals\.pairing-code/);
  assert.match(text, /01234567$/);
  assert.throws(() => appleDoubleWithPairingCode("nope"));
});

test("unwritable archives fall back to null instead of corrupting", () => {
  assert.equal(injectPairingCode(encoder.encode("not a zip"), "90285513"), null);
});

test("macOS ditto restores the stamped xattr from an injected zip", (t) => {
  if (process.platform !== "darwin") {
    t.skip("requires macOS ditto/xattr");
    return;
  }
  const workdir = mkdtempSync(join(tmpdir(), "pedals-paired-zip-"));
  try {
    const zipPath = join(workdir, "paired.zip");
    writeFileSync(zipPath, injectPairingCode(buildZip(RELEASE_LIKE), "90285513"));
    execFileSync("ditto", ["-x", "-k", zipPath, join(workdir, "out")]);
    const value = execFileSync(
      "xattr",
      ["-p", "build.air.pedals.pairing-code", join(workdir, "out", "Pedals.app")],
      { encoding: "utf8" },
    ).trim();
    assert.equal(value, "90285513");
    // The signed payload file survives byte-for-byte.
    assert.equal(
      execFileSync(
        "cat",
        [join(workdir, "out", "Pedals.app", "Contents", "Info.plist")],
        { encoding: "utf8" },
      ),
      "signed-bytes-do-not-touch",
    );
  } finally {
    rmSync(workdir, { recursive: true, force: true });
  }
});

test("the paired download endpoint stamps the upstream release zip", async () => {
  const original = buildZip(RELEASE_LIKE);
  const fetched = [];
  const response = await handlePairedDownload(
    new Request("https://pedals.air.build/download/90285513/macos.zip"),
    { DESKTOP_RELEASE_REPOSITORY: "yellowplushq/pedals" },
    "90285513",
    async (url) => {
      fetched.push(String(url));
      return new Response(original);
    },
  );

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.match(
    response.headers.get("content-disposition"),
    /attachment; filename="Pedals-macOS\.zip"/,
  );
  assert.deepEqual(fetched, [
    "https://github.com/yellowplushq/pedals/releases/latest/download/Pedals-macOS.zip",
  ]);
  const body = new Uint8Array(await response.arrayBuffer());
  assert.equal(readEOCD(body).entries, RELEASE_LIKE.length + 1);
  assert.match(new TextDecoder("latin1").decode(body), /__MACOSX\/\._Pedals\.app/);
});

test("the paired download endpoint answers HEAD and unconfigured repos safely", async () => {
  const head = await handlePairedDownload(
    new Request("https://pedals.air.build/download/90285513/macos.zip", {
      method: "HEAD",
    }),
    { DESKTOP_RELEASE_REPOSITORY: "yellowplushq/pedals" },
    "90285513",
    async () => {
      throw new Error("HEAD must not fetch upstream");
    },
  );
  assert.equal(head.status, 200);
  assert.equal(head.body, null);

  const unconfigured = await handlePairedDownload(
    new Request("https://pedals.air.build/download/90285513/macos.zip"),
    {},
    "90285513",
    async () => {
      throw new Error("unconfigured must not fetch upstream");
    },
  );
  assert.equal(unconfigured.status, 503);
});
