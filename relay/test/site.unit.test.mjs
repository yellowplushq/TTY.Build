import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  APPCAST_ASSET,
  handleDesktopDownload,
  handleWebsiteAsset,
  MACOS_ASSET,
  MACOS_ZIP_ASSET,
} from "../src/site.mjs";

function request(path, options = {}) {
  return new Request(`https://pedals.air.build${path}`, options);
}

test("the stable download path redirects to the latest desktop release", async () => {
  const req = request("/download/macos");
  const response = handleDesktopDownload(
    req,
    { DESKTOP_RELEASE_REPOSITORY: "yellowplushq/pedals" },
    new URL(req.url),
  );

  assert.equal(response.status, 302);
  assert.equal(
    response.headers.get("location"),
    `https://github.com/yellowplushq/pedals/releases/latest/download/${MACOS_ASSET}`,
  );
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("the stable appcast path redirects to the latest signed update feed", () => {
  const req = request("/appcast.xml", { method: "HEAD" });
  const response = handleDesktopDownload(
    req,
    { DESKTOP_RELEASE_REPOSITORY: "yellowplushq/pedals" },
    new URL(req.url),
  );

  assert.equal(response.status, 302);
  assert.equal(
    response.headers.get("location"),
    `https://github.com/yellowplushq/pedals/releases/latest/download/${APPCAST_ASSET}`,
  );
  assert.equal(response.headers.get("content-length"), "0");
});

test("the zip download paths redirect to the latest release archive and checksum", () => {
  for (const [path, asset] of [
    ["/download/macos.zip", MACOS_ZIP_ASSET],
    ["/download/macos.zip.sha256", `${MACOS_ZIP_ASSET}.sha256`],
  ]) {
    const req = request(path);
    const response = handleDesktopDownload(
      req,
      { DESKTOP_RELEASE_REPOSITORY: "yellowplushq/pedals" },
      new URL(req.url),
    );

    assert.equal(response.status, 302);
    assert.equal(
      response.headers.get("location"),
      `https://github.com/yellowplushq/pedals/releases/latest/download/${asset}`,
    );
  }
});

test("the short download path redirects to the canonical path", () => {
  const req = request("/download", { method: "HEAD" });
  const response = handleDesktopDownload(req, {}, new URL(req.url));

  assert.equal(response.status, 302);
  assert.equal(response.headers.get("location"), "/download/macos");
  assert.equal(response.headers.get("content-length"), "0");
});

test("an unconfigured release repository fails without a misleading link", async () => {
  const req = request("/download/macos");
  const response = handleDesktopDownload(req, {}, new URL(req.url));

  assert.equal(response.status, 503);
  assert.match(await response.text(), /not configured/i);
  assert.equal(response.headers.get("retry-after"), "300");
});

test("download handling ignores unrelated routes and mutating methods", () => {
  const unrelated = request("/styles.css");
  const post = request("/download/macos", { method: "POST" });

  assert.equal(handleDesktopDownload(unrelated, {}, new URL(unrelated.url)), null);
  assert.equal(handleDesktopDownload(post, {}, new URL(post.url)), null);
});

test("website assets receive defense-in-depth response headers", async () => {
  const req = request("/");
  const response = await handleWebsiteAsset(req, {
    ASSETS: {
      fetch: async () =>
        new Response("<!doctype html><title>Pedals</title>", {
          headers: { "content-type": "text/html; charset=utf-8" },
        }),
    },
  });

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("x-frame-options"), "DENY");
  assert.equal(response.headers.get("x-content-type-options"), "nosniff");
  assert.equal(
    response.headers.get("strict-transport-security"),
    "max-age=31536000; includeSubDomains",
  );
  assert.match(await response.text(), /Pedals/);
});

test("the one-screen homepage exposes the product promise and download CTA", async () => {
  const html = await readFile(new URL("../public/index.html", import.meta.url), "utf8");
  assert.match(html, /Your terminal\./);
  assert.match(html, /href="\/favicon-32\.png"/);
  assert.match(html, /src="\/brand-icon\.png"/);
  assert.match(html, /href="\/download\/macos"/);
  assert.match(html, /8-digit code/);
  assert.match(html, /Terminal bytes and encryption keys never live on the service/);
  assert.match(html, /href="\/privacy\/"/);
  assert.match(html, /href="\/support\/"/);
});

test("the homepage offers the curl installer with a self-hosted copy button", async () => {
  const html = await readFile(new URL("../public/index.html", import.meta.url), "utf8");
  assert.match(html, /curl -fsSL https:\/\/pedals\.air\.build\/install\.sh \| bash/);
  assert.match(html, /data-copy="install-command-text"/);
  assert.match(html, /<script src="\/site\.js" defer><\/script>/);

  const script = await readFile(new URL("../public/site.js", import.meta.url), "utf8");
  assert.match(script, /navigator\.clipboard\.writeText/);

  const headers = await readFile(new URL("../public/_headers", import.meta.url), "utf8");
  assert.match(headers, /script-src 'self'/);
});

test("the curl installer downloads the zip release and verifies its checksum", async () => {
  const script = await readFile(new URL("../public/install.sh", import.meta.url), "utf8");
  assert.match(script, /^#!\/usr\/bin\/env bash/);
  assert.match(script, /\/download\/macos\.zip/);
  assert.match(script, /\/download\/macos\.zip\.sha256/);
  assert.match(script, /shasum -a 256 -c/);
  assert.match(script, /read -r answer .*\/dev\/tty/);
  assert.doesNotMatch(script, /sudo/);
});

test("support and privacy pages expose release-ready public information", async () => {
  const privacy = await readFile(
    new URL("../public/privacy/index.html", import.meta.url),
    "utf8",
  );
  const support = await readFile(
    new URL("../public/support/index.html", import.meta.url),
    "utf8",
  );

  assert.match(privacy, /end-to-end encrypted/i);
  assert.match(privacy, /does not store terminal content/i);
  assert.match(support, /8-digit code/);
  assert.match(support, /mailto:eyhn@yellowplus\.app/);
});
