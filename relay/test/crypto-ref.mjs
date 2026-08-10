// Node reference implementation of the TTYBuild E2EE protocol v2.
//
// Wire message = seq (u64 LE) || nonce(12) || ciphertext || tag(16)
// where nonce||ciphertext||tag is the CryptoKit ChaChaPoly "combined"
// representation and the 8 seq bytes are the AAD.
//
// Pure node:crypto — used by relay tests and the headless e2e client, and as
// the cross-check target for TTYBuildKit's Swift implementation.

import {
  hkdfSync,
  createCipheriv,
  createDecipheriv,
  randomBytes,
} from "node:crypto";

const HKDF_SALT = Buffer.from("ttybuild-v2", "utf8");
const INFO_H2C = Buffer.from("host->client", "utf8");
const INFO_C2H = Buffer.from("client->host", "utf8");
const KEY_LEN = 32;
const NONCE_LEN = 12;
const TAG_LEN = 16;
const SEQ_LEN = 8;

/** Derive one 32-byte direction key from the 32-byte pairing secret. */
export function deriveKey(secret, info) {
  return Buffer.from(hkdfSync("sha256", secret, HKDF_SALT, info, KEY_LEN));
}

/**
 * Derive both direction keys: { h2c, c2h }, bound to a channel (§3). Pass a
 * numeric sid for a session channel; omit (or null) for the control channel.
 */
export function deriveKeys(secret, sid = null) {
  const suffix = Buffer.from(sid == null ? "" : `:session:${sid}`, "utf8");
  return {
    h2c: deriveKey(secret, Buffer.concat([INFO_H2C, suffix])),
    c2h: deriveKey(secret, Buffer.concat([INFO_C2H, suffix])),
  };
}

/** 8-byte little-endian encoding of seq (the AAD). */
export function seqBytes(seq) {
  const b = Buffer.alloc(SEQ_LEN);
  b.writeBigUInt64LE(BigInt(seq), 0);
  return b;
}

/**
 * Seal a plaintext frame. Returns the full wire message.
 * `nonce` is only injectable for test vectors; production callers omit it.
 */
export function seal(key, seq, plaintext, nonce = randomBytes(NONCE_LEN)) {
  if (nonce.length !== NONCE_LEN) throw new Error("nonce must be 12 bytes");
  const aad = seqBytes(seq);
  const cipher = createCipheriv("chacha20-poly1305", key, nonce, {
    authTagLength: TAG_LEN,
  });
  cipher.setAAD(aad, { plaintextLength: plaintext.length });
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([aad, nonce, ciphertext, cipher.getAuthTag()]);
}

/** Open a wire message. Returns { seq: bigint, plaintext: Buffer }. Throws on auth failure. */
export function open(key, message) {
  if (message.length < SEQ_LEN + NONCE_LEN + TAG_LEN) {
    throw new Error("message too short");
  }
  const aad = message.subarray(0, SEQ_LEN);
  const nonce = message.subarray(SEQ_LEN, SEQ_LEN + NONCE_LEN);
  const ciphertext = message.subarray(SEQ_LEN + NONCE_LEN, message.length - TAG_LEN);
  const tag = message.subarray(message.length - TAG_LEN);
  const decipher = createDecipheriv("chacha20-poly1305", key, nonce, {
    authTagLength: TAG_LEN,
  });
  decipher.setAAD(aad, { plaintextLength: ciphertext.length });
  decipher.setAuthTag(tag);
  const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  return { seq: aad.readBigUInt64LE(0), plaintext };
}

// ---- Plaintext frame codec --------------------------------------------------

export const FrameType = Object.freeze({
  ctl: 0x00,
  stdin: 0x01,
  stdout: 0x02,
  resize: 0x03,
  replay: 0x04,
});

/** frame = type (u8) || sessionId (u32 LE) || payload */
export function encodeFrame(type, sessionId, payload = Buffer.alloc(0)) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  const head = Buffer.alloc(5);
  head.writeUInt8(type, 0);
  head.writeUInt32LE(sessionId, 1);
  return Buffer.concat([head, body]);
}

export function decodeFrame(buf) {
  if (buf.length < 5) throw new Error("frame too short");
  return {
    type: buf.readUInt8(0),
    sessionId: buf.readUInt32LE(1),
    payload: buf.subarray(5),
  };
}

/** Encode a ctl frame (type 0x00, sessionId 0) from a JSON-able object. */
export function encodeCtl(obj) {
  return encodeFrame(FrameType.ctl, 0, Buffer.from(JSON.stringify(obj), "utf8"));
}
