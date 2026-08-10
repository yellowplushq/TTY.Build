#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "..");
const relayDirectory = join(repositoryRoot, "relay");

function parseArguments(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name?.startsWith("--") || !value) {
      throw new Error(
        "usage: configure-relay-apns.mjs --p8 PATH --key-id ID --team-id ID",
      );
    }
    values.set(name, value);
  }
  return values;
}

function requireIdentifier(value, label) {
  if (!/^[A-Z0-9]{10}$/.test(value ?? "")) {
    throw new Error(`${label} must be a 10-character Apple identifier`);
  }
  return value;
}

function redact(output, secret) {
  const safeOutput = secret ? output.replaceAll(secret, "[REDACTED]") : output;
  return safeOutput.slice(-2_000);
}

function runWrangler(args, input, redactionValue = "") {
  const result = spawnSync("npx", ["wrangler", ...args], {
    cwd: relayDirectory,
    encoding: "utf8",
    env: {
      ...process.env,
      WRANGLER_LOG_PATH: "/tmp/ttybuild-wrangler-apns.log",
    },
    input,
    stdio: ["pipe", "pipe", "pipe"],
  });

  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    const combined = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
    throw new Error(
      `wrangler ${args.join(" ")} failed: ${redact(combined, redactionValue)}`,
    );
  }
  return result.stdout;
}

const argumentsByName = parseArguments(process.argv.slice(2));
const sourcePath = resolve(argumentsByName.get("--p8") ?? "");
const keyId = requireIdentifier(argumentsByName.get("--key-id"), "Key ID");
const teamId = requireIdentifier(argumentsByName.get("--team-id"), "Team ID");

const privateKey = readFileSync(sourcePath, "utf8").trim();
if (
  !privateKey.startsWith("-----BEGIN PRIVATE KEY-----") ||
  !privateKey.endsWith("-----END PRIVATE KEY-----")
) {
  throw new Error("APNs .p8 does not contain a PKCS#8 private key");
}

const preparedBulkPathArgument = argumentsByName.get("--prepare-bulk");
if (preparedBulkPathArgument) {
  const preparedBulkPath = resolve(preparedBulkPathArgument);
  if (
    !preparedBulkPath.startsWith("/private/tmp/") &&
    !preparedBulkPath.startsWith("/tmp/")
  ) {
    throw new Error("--prepare-bulk must point inside /tmp");
  }
  writeFileSync(
    preparedBulkPath,
    `${JSON.stringify({
      APNS_PRIVATE_KEY_P8: privateKey,
      APNS_KEY_ID: keyId,
      APNS_TEAM_ID: teamId,
    })}\n`,
    { flag: "wx", mode: 0o600 },
  );
  chmodSync(preparedBulkPath, 0o600);
  process.stdout.write(`${JSON.stringify({ preparedBulkPath })}\n`);
  process.exit(0);
}

const signingDirectory = join(
  homedir(),
  "Library",
  "Application Support",
  "TTYBuild",
  "Signing",
);
const securePath = join(signingDirectory, `AuthKey_${keyId}.p8`);
mkdirSync(signingDirectory, { mode: 0o700, recursive: true });
chmodSync(sourcePath, 0o600);

if (existsSync(securePath)) {
  const existing = readFileSync(securePath);
  const incoming = readFileSync(sourcePath);
  const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
  if (digest(existing) !== digest(incoming)) {
    throw new Error(`refusing to overwrite a different key at ${securePath}`);
  }
} else {
  copyFileSync(sourcePath, securePath);
}
chmodSync(securePath, 0o600);

for (const [name, value] of [
  ["APNS_PRIVATE_KEY_P8", privateKey],
  ["APNS_KEY_ID", keyId],
  ["APNS_TEAM_ID", teamId],
]) {
  runWrangler(["secret", "put", name], `${value}\n`, value);
}

const listed = JSON.parse(
  runWrangler(["secret", "list", "--format", "json"]),
);
const installedNames = new Set(listed.map((entry) => entry.name));
for (const required of [
  "APNS_PRIVATE_KEY_P8",
  "APNS_KEY_ID",
  "APNS_TEAM_ID",
]) {
  if (!installedNames.has(required)) {
    throw new Error(`Worker secret verification failed: ${required} is absent`);
  }
}

if (sourcePath !== securePath) {
  unlinkSync(sourcePath);
}

process.stdout.write(
  `${JSON.stringify({
    configured: ["APNS_PRIVATE_KEY_P8", "APNS_KEY_ID", "APNS_TEAM_ID"],
    privateKeyPath: securePath,
  })}\n`,
);
