// Injects an enrollment code into the release zip as an AppleDouble entry.
//
// The zip's Pedals.app is signed and notarized and must stay byte-identical;
// extended attributes live outside the code-signature seal, so the code
// travels as `__MACOSX/._Pedals.app` — the sequestered-xattr sidecar that
// Archive Utility and `ditto -x -k` restore onto the extracted bundle. The
// app consumes the attribute on launch and pairs.
//
// Pure byte surgery: one stored entry is appended before the central
// directory, which is then re-emitted with a patched EOCD. Every original
// byte, including the signed app, passes through untouched.

const ATTRIBUTE_NAME = "build.air.pedals.pairing-code";
const ENTRY_NAME = "__MACOSX/._Pedals.app";

const encoder = new TextEncoder();

let crcTable = null;

function crc32(bytes) {
  if (!crcTable) {
    crcTable = new Uint32Array(256);
    for (let n = 0; n < 256; n += 1) {
      let value = n;
      for (let k = 0; k < 8; k += 1) {
        value = value & 1 ? 0xEDB88320 ^ (value >>> 1) : value >>> 1;
      }
      crcTable[n] = value;
    }
  }
  let crc = 0xFFFFFFFF;
  for (const byte of bytes) {
    crc = crcTable[(crc ^ byte) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

/// AppleDouble container holding exactly one extended attribute. Layout
/// mirrors what `ditto --sequesterRsrc` emits: header, Finder Info entry
/// carrying an ATTR section, and an empty resource-fork entry.
export function appleDoubleWithPairingCode(code) {
  if (!/^\d{8}$/.test(code)) throw new TypeError("code must be 8 digits");
  const name = encoder.encode(`${ATTRIBUTE_NAME}\0`);
  const value = encoder.encode(code);

  const attrEntryLength = 4 + 4 + 2 + 1 + name.length;
  const attrEntryPadded = (attrEntryLength + 3) & ~3;
  const dataStart = 0x78 + attrEntryPadded;
  const total = dataStart + value.length;

  const bytes = new Uint8Array(total);
  const view = new DataView(bytes.buffer);
  view.setUint32(0, 0x00051607); // AppleDouble magic
  view.setUint32(4, 0x00020000); // version
  bytes.set(encoder.encode("Mac OS X"), 8); // filler (rest stays zero)
  bytes.set(encoder.encode("        "), 16);
  view.setUint16(24, 2); // entry count
  view.setUint32(26, 9); // Finder Info entry
  view.setUint32(30, 0x32);
  view.setUint32(34, total - 0x32);
  view.setUint32(38, 2); // empty resource fork entry
  view.setUint32(42, total);
  view.setUint32(46, 0);
  // 32 zero bytes of Finder Info at 0x32, 2 bytes pad, then the ATTR section.
  bytes.set(encoder.encode("ATTR"), 0x54);
  view.setUint32(0x5C, total);
  view.setUint32(0x60, dataStart);
  view.setUint32(0x64, value.length);
  view.setUint16(0x76, 1); // attribute count
  view.setUint32(0x78, dataStart); // attr: value offset
  view.setUint32(0x7C, value.length); // attr: value length
  view.setUint16(0x80, 0); // attr: flags
  view.setUint8(0x82, name.length);
  bytes.set(name, 0x83);
  bytes.set(value, dataStart);
  return bytes;
}

function findEndOfCentralDirectory(view, bytes) {
  // EOCD is the last record; scan backwards over a possible zip comment.
  const floor = Math.max(0, bytes.length - 22 - 65535);
  for (let offset = bytes.length - 22; offset >= floor; offset -= 1) {
    if (view.getUint32(offset, true) === 0x06054B50) return offset;
  }
  return -1;
}

/// Returns a new zip with the AppleDouble entry appended, or null when the
/// archive cannot be safely rewritten (zip64, multi-disk, or no EOCD) — the
/// caller then falls back to the untouched original.
export function injectPairingCode(zipBytes, code) {
  const bytes = zipBytes instanceof Uint8Array ? zipBytes : new Uint8Array(zipBytes);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const eocdOffset = findEndOfCentralDirectory(view, bytes);
  if (eocdOffset < 0) return null;

  const diskNumber = view.getUint16(eocdOffset + 4, true);
  const centralDirectoryDisk = view.getUint16(eocdOffset + 6, true);
  const entriesOnDisk = view.getUint16(eocdOffset + 8, true);
  const totalEntries = view.getUint16(eocdOffset + 10, true);
  const centralDirectorySize = view.getUint32(eocdOffset + 12, true);
  const centralDirectoryOffset = view.getUint32(eocdOffset + 16, true);
  if (
    diskNumber !== 0 || centralDirectoryDisk !== 0 ||
    totalEntries === 0xFFFF ||
    centralDirectorySize === 0xFFFFFFFF ||
    centralDirectoryOffset === 0xFFFFFFFF ||
    centralDirectoryOffset + centralDirectorySize > eocdOffset
  ) {
    return null;
  }

  const name = encoder.encode(ENTRY_NAME);
  const payload = appleDoubleWithPairingCode(code);
  const checksum = crc32(payload);

  const localHeader = new Uint8Array(30 + name.length);
  const localView = new DataView(localHeader.buffer);
  localView.setUint32(0, 0x04034B50, true);
  localView.setUint16(4, 20, true); // version needed
  localView.setUint32(14, checksum, true);
  localView.setUint32(18, payload.length, true); // compressed (stored)
  localView.setUint32(22, payload.length, true); // uncompressed
  localView.setUint16(26, name.length, true);
  localHeader.set(name, 30);

  const centralEntry = new Uint8Array(46 + name.length);
  const centralView = new DataView(centralEntry.buffer);
  centralView.setUint32(0, 0x02014B50, true);
  centralView.setUint16(4, 20, true); // version made by
  centralView.setUint16(6, 20, true); // version needed
  centralView.setUint32(16, checksum, true);
  centralView.setUint32(20, payload.length, true);
  centralView.setUint32(24, payload.length, true);
  centralView.setUint16(28, name.length, true);
  centralView.setUint32(42, centralDirectoryOffset, true); // local offset
  centralEntry.set(name, 46);

  const insertedLocalSize = localHeader.length + payload.length;
  const eocd = new Uint8Array(22);
  const eocdView = new DataView(eocd.buffer);
  eocdView.setUint32(0, 0x06054B50, true);
  eocdView.setUint16(8, entriesOnDisk + 1, true);
  eocdView.setUint16(10, totalEntries + 1, true);
  eocdView.setUint32(12, centralDirectorySize + centralEntry.length, true);
  eocdView.setUint32(16, centralDirectoryOffset + insertedLocalSize, true);

  const out = new Uint8Array(
    centralDirectoryOffset + insertedLocalSize + centralDirectorySize +
      centralEntry.length + eocd.length,
  );
  out.set(bytes.subarray(0, centralDirectoryOffset), 0);
  let cursor = centralDirectoryOffset;
  out.set(localHeader, cursor);
  cursor += localHeader.length;
  out.set(payload, cursor);
  cursor += payload.length;
  out.set(
    bytes.subarray(centralDirectoryOffset, centralDirectoryOffset + centralDirectorySize),
    cursor,
  );
  cursor += centralDirectorySize;
  out.set(centralEntry, cursor);
  cursor += centralEntry.length;
  out.set(eocd, cursor);
  return out;
}
