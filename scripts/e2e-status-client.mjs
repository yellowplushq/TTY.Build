#!/usr/bin/env node

import assert from "node:assert/strict";
import {
  createDecipheriv,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
} from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";

const timeoutMilliseconds = 15_000;

async function request(serviceURL, path, { method = "GET", token, body } = {}) {
  const headers = new Headers({ accept: "application/json" });
  if (token) headers.set("authorization", `Bearer ${token}`);
  const options = {
    method,
    headers,
    signal: AbortSignal.timeout(timeoutMilliseconds),
  };
  if (body !== undefined) {
    headers.set("content-type", "application/json");
    options.body = JSON.stringify(body);
  }
  const response = await fetch(new URL(path, serviceURL), options);
  const text = await response.text();
  const value = text === "" ? null : JSON.parse(text);
  return { response, value };
}

async function bind(serviceURL, code, outputPath) {
  assert.match(code, /^\d{8}$/);
  const created = await request(serviceURL, "/v2/clients", { method: "POST" });
  assert.equal(created.response.status, 201, JSON.stringify(created.value));
  const { clientId, clientToken, statusToken } = created.value;

  const { privateKey, publicKey } = generateKeyPairSync("x25519");
  const clientPublicKey = publicKey.export({ format: "jwk" }).x;
  const claim = await request(serviceURL, "/v2/clients/me/pairing-codes/claim", {
    method: "POST",
    token: clientToken,
    body: { code, publicKey: clientPublicKey },
  });
  assert.equal(claim.response.status, 200, JSON.stringify(claim.value));
  const { claimId, hostPublicKey } = claim.value;

  const replay = await request(serviceURL, "/v2/clients/me/pairing-codes/claim", {
    method: "POST",
    token: clientToken,
    body: { code, publicKey: "A".repeat(43) },
  });
  assert.equal(replay.response.status, 400, "one-time pairing code was accepted twice");

  const deadline = Date.now() + timeoutMilliseconds;
  let completed;
  while (Date.now() < deadline) {
    const status = await request(
      serviceURL,
      `/v2/clients/me/pairing-claims/${claimId}`,
      { token: clientToken },
    );
    assert.equal(status.response.status, 200, JSON.stringify(status.value));
    if (status.value.status === "sealed") {
      completed = status.value;
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.ok(completed, "desktop did not complete the pairing key exchange");

  const hostKey = createPublicKey({
    format: "jwk",
    key: { kty: "OKP", crv: "X25519", x: hostPublicKey },
  });
  const sharedSecret = diffieHellman({ privateKey, publicKey: hostKey });
  const key = Buffer.from(hkdfSync(
    "sha256",
    sharedSecret,
    Buffer.from("tty.build pairing v3"),
    Buffer.from(claimId),
    32,
  ));
  const envelope = Buffer.from(completed.encryptedSecret, "base64url");
  const nonce = envelope.subarray(0, 12);
  const ciphertext = envelope.subarray(12, -16);
  const tag = envelope.subarray(-16);
  const decipher = createDecipheriv("chacha20-poly1305", key, nonce, {
    authTagLength: 16,
  });
  decipher.setAAD(Buffer.from(claimId));
  decipher.setAuthTag(tag);
  const secret = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  assert.equal(secret.length, 32, "pairing envelope did not contain the E2EE secret");

  // The accept is the edge-creating consent of the unified ceremony.
  const accepted = await request(
    serviceURL,
    `/v2/clients/me/pairing-claims/${claimId}/accept`,
    { method: "POST", token: clientToken },
  );
  assert.equal(accepted.response.status, 201, JSON.stringify(accepted.value));

  await writeFile(
    outputPath,
    `${JSON.stringify({ serviceURL, clientId, statusToken })}\n`,
    { mode: 0o600 },
  );
}

async function waitForCount(inputPath, expected) {
  const credential = JSON.parse(await readFile(inputPath, "utf8"));
  const deadline = Date.now() + timeoutMilliseconds;
  let last;
  while (Date.now() < deadline) {
    const result = await request(credential.serviceURL, "/v2/clients/me/state", {
      token: credential.statusToken,
    });
    assert.equal(result.response.status, 200, JSON.stringify(result.value));
    last = result.value;
    if (last.totalRunning === expected) return;
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  assert.fail(`expected totalRunning=${expected}; last state=${JSON.stringify(last)}`);
}

const [command, first, second, third] = process.argv.slice(2);
if (command === "bind" && first && /^\d{8}$/.test(second ?? "") && third) {
  await bind(first, second, third);
} else if (command === "wait" && first && /^\d+$/.test(second ?? "")) {
  await waitForCount(first, Number(second));
} else {
  throw new Error(
    "usage: e2e-status-client.mjs bind <service-url> <8-digit-code> <credential-file> | "
      + "wait <credential-file> <expected-count>",
  );
}
