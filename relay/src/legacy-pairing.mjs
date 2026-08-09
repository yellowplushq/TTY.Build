// TEMPORARY legacy shim: the pre-unification `pairing-sessions` endpoints,
// translated onto the unified pairing_codes / pairing_claims tables so apps
// shipped before the unified ceremony keep pairing with each other.
//
// Scope and limits:
// - old desktop + old iOS: fully working (both derive the legacy key from
//   the shared session id — served here as the unified code id — so the
//   ciphertext round-trips untouched).
// - mixed old/new pairs CANNOT work: the E2EE derivation changed (salt and
//   associated data), and the service cannot re-encrypt what it cannot
//   read. A mixed pair rendezvouses but fails decryption client-side.
// - the legacy `complete` reproduces the old semantics of creating the
//   binding edge immediately (old clients never call `accept`); the legacy
//   acknowledgement consumes the claim and retires the single-use code.
//
// Delete this file (and its worker.mjs hook and tests) once every installed
// desktop and TestFlight build speaks the unified ceremony.

import {
  ApiFailure,
  HOST_CODE_TTL_SECONDS,
  MAX_BINDINGS_PER_CLIENT,
  apiError,
  authenticateClient,
  authenticateHost,
  clientAddress,
  enforceRateLimit,
  json,
  notifyPushCoordinator,
  randomId,
  randomPairingCode,
  rateLimitKey,
  readJson,
  touchClient,
  tokenHash,
} from "./core.mjs";

const PAIRING_CODE = /^\d{8}$/;
const CURVE25519_PUBLIC_KEY = /^[A-Za-z0-9_-]{43}$/;
const ENCRYPTED_SECRET = /^[A-Za-z0-9_-]{64,256}$/;

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function requireBodyShape(body, required) {
  const allowed = new Set(required);
  if (
    required.some((key) => !Object.hasOwn(body, key)) ||
    Object.keys(body).some((key) => !allowed.has(key))
  ) {
    throw new ApiFailure(400, "invalid_request", "request body has an invalid shape");
  }
}

async function limitAuthenticated(request, env, bindingName, route, principalId) {
  const key = await rateLimitKey(route, principalId, clientAddress(request));
  await enforceRateLimit(env, bindingName, key);
}

async function requireControlClient(request, env) {
  const client = await authenticateClient(request, env.DB);
  if (!client) throw new ApiFailure(401, "unauthorized", "valid client bearer required");
  await touchClient(env.DB, client.id);
  return client;
}

function background(ctx, promise, label) {
  ctx.waitUntil(
    promise.catch((error) => {
      console.error(label, error instanceof Error ? error.message : error);
    }),
  );
}

/// POST /v2/computers/:id/pairing-sessions — a 15-minute single-use code;
/// the unified code id doubles as the legacy session id.
async function createSession(request, env, computerId) {
  const host = await authenticateHost(request, env.DB, computerId);
  if (!host) return apiError(401, "unauthorized", "valid host bearer required");
  await limitAuthenticated(request, env, "INVITE_LIMITER", "pairing-code", host.id);
  const body = await readJson(request);
  requireBodyShape(body, ["hostPublicKey"]);
  if (!CURVE25519_PUBLIC_KEY.test(body.hostPublicKey)) {
    throw new ApiFailure(400, "invalid_public_key", "host public key is invalid");
  }

  const now = nowSeconds();
  const expiresAt = now + HOST_CODE_TTL_SECONDS;
  await env.DB.prepare(`DELETE FROM pairing_codes WHERE computer_id = ?1`)
    .bind(computerId)
    .run();
  for (let attempt = 0; attempt < 8; attempt += 1) {
    const code = randomPairingCode();
    const codeHash = await tokenHash(code);
    const codeId = randomId();
    const inserted = await env.DB.prepare(
      `INSERT OR IGNORE INTO pairing_codes
         (id, code_hash, issuer, computer_id, client_id, public_key,
          single_use, created_at, expires_at)
       VALUES (?1, ?2, 'host', ?3, NULL, ?4, 1, ?5, ?6)`,
    ).bind(codeId, codeHash, computerId, body.hostPublicKey, now, expiresAt).run();
    if (Number(inserted.meta?.changes ?? 0) === 1) {
      return json({ sessionId: codeId, code, expiresAt }, 201);
    }
  }
  throw new ApiFailure(503, "pairing_code_unavailable", "could not allocate a pairing code");
}

/// GET /v2/computers/:id/pairing-sessions/:sid — legacy host poll.
async function getHostSession(request, env, computerId, sessionId) {
  const host = await authenticateHost(request, env.DB, computerId);
  if (!host) return apiError(401, "unauthorized", "valid host bearer required");
  const now = nowSeconds();
  const code = await env.DB.prepare(
    `SELECT expires_at AS expiresAt FROM pairing_codes
      WHERE id = ?1 AND computer_id = ?2 AND expires_at > ?3`,
  ).bind(sessionId, computerId, now).first();
  if (!code) {
    throw new ApiFailure(410, "pairing_session_expired", "pairing session is closed or expired");
  }
  const claim = await env.DB.prepare(
    `SELECT client_public_key AS clientPublicKey,
            encrypted_secret AS encryptedSecret
       FROM pairing_claims
      WHERE code_id = ?1 AND expires_at > ?2
      ORDER BY created_at DESC
      LIMIT 1`,
  ).bind(sessionId, now).first();
  const status = claim === null
    ? "waiting"
    : claim.encryptedSecret === null ? "claimed" : "completed";
  return json({
    status,
    expiresAt: Number(code.expiresAt),
    ...(claim === null ? {} : { clientPublicKey: claim.clientPublicKey }),
  });
}

/// DELETE /v2/computers/:id/pairing-sessions/:sid — closing the old page.
async function cancelHostSession(request, env, computerId, sessionId) {
  const host = await authenticateHost(request, env.DB, computerId);
  if (!host) return apiError(401, "unauthorized", "valid host bearer required");
  await env.DB.prepare(
    `DELETE FROM pairing_codes WHERE id = ?1 AND computer_id = ?2`,
  ).bind(sessionId, computerId).run();
  return new Response(null, { status: 204 });
}

/// POST /v2/clients/me/pairing-sessions/claim — legacy client claim. The
/// response's sessionId is the unified code id, which the old client uses
/// for its status polls and acknowledgement.
async function claimSession(request, env) {
  const client = await requireControlClient(request, env);
  await limitAuthenticated(request, env, "MUTATION_LIMITER", "pairing-claim", client.id);
  const body = await readJson(request);
  requireBodyShape(body, ["code", "clientPublicKey"]);
  if (!PAIRING_CODE.test(body.code) || !CURVE25519_PUBLIC_KEY.test(body.clientPublicKey)) {
    throw new ApiFailure(400, "invalid_pairing_code", "pairing code is invalid or expired");
  }

  const now = nowSeconds();
  const hash = await tokenHash(body.code);
  const found = await env.DB.prepare(
    `SELECT id, computer_id AS computerId, public_key AS publicKey,
            expires_at AS expiresAt
       FROM pairing_codes
      WHERE code_hash = ?1 AND issuer = 'host' AND expires_at > ?2`,
  ).bind(hash, now).first();
  if (!found) {
    throw new ApiFailure(400, "invalid_pairing_code", "pairing code is invalid or expired");
  }
  const atCapacity = await env.DB.prepare(
    `SELECT COUNT(*) >= ?2 AS full FROM client_computers WHERE client_id = ?1`,
  ).bind(client.id, MAX_BINDINGS_PER_CLIENT).first("full");
  if (Number(atCapacity) === 1) {
    throw new ApiFailure(
      429,
      "binding_limit",
      `a client may bind at most ${MAX_BINDINGS_PER_CLIENT} computers`,
    );
  }

  const claimId = randomId();
  const inserted = await env.DB.prepare(
    `INSERT INTO pairing_claims
       (id, code_id, client_id, computer_id, claimed_by, computer_name,
        host_public_key, client_public_key, encrypted_secret,
        created_at, expires_at)
     SELECT ?1, ?2, ?3, ?4, 'client', '', ?5, ?6, NULL, ?7, ?8
      WHERE NOT EXISTS (
              SELECT 1 FROM pairing_claims WHERE code_id = ?2
            )
     ON CONFLICT(client_id, computer_id) DO UPDATE SET
       id = excluded.id,
       code_id = excluded.code_id,
       claimed_by = excluded.claimed_by,
       computer_name = excluded.computer_name,
       host_public_key = excluded.host_public_key,
       client_public_key = excluded.client_public_key,
       encrypted_secret = NULL,
       created_at = excluded.created_at,
       expires_at = excluded.expires_at`,
  ).bind(
    claimId,
    found.id,
    client.id,
    found.computerId,
    found.publicKey,
    body.clientPublicKey,
    now,
    Number(found.expiresAt),
  ).run();
  if (Number(inserted.meta?.changes ?? 0) !== 1) {
    throw new ApiFailure(400, "invalid_pairing_code", "pairing code is invalid or expired");
  }
  return json({
    sessionId: found.id,
    computerId: found.computerId,
    hostPublicKey: found.publicKey,
    expiresAt: Number(found.expiresAt),
  });
}

/// POST /v2/computers/:id/pairing-sessions/:sid/complete — legacy semantics:
/// sealing the envelope atomically creates the binding edge, because legacy
/// clients never call accept. The claim row survives (with its envelope)
/// for the client's poll, and dies at acknowledgement.
async function completeSession(request, env, ctx, computerId, sessionId) {
  const host = await authenticateHost(request, env.DB, computerId);
  if (!host) return apiError(401, "unauthorized", "valid host bearer required");
  const body = await readJson(request);
  requireBodyShape(body, ["encryptedSecret"]);
  if (!ENCRYPTED_SECRET.test(body.encryptedSecret)) {
    throw new ApiFailure(400, "invalid_envelope", "encrypted pairing envelope is invalid");
  }

  const now = nowSeconds();
  const mutationId = randomId();
  const results = await env.DB.batch([
    env.DB.prepare(
      `UPDATE pairing_claims
          SET encrypted_secret = ?3
        WHERE code_id = ?1 AND computer_id = ?2
          AND encrypted_secret IS NULL
          AND expires_at > ?4
          AND (
                EXISTS (
                  SELECT 1 FROM client_computers
                   WHERE client_id = pairing_claims.client_id AND computer_id = ?2
                )
                OR (
                  SELECT COUNT(*) FROM client_computers
                   WHERE client_id = pairing_claims.client_id
                ) < ?5
              )`,
    ).bind(sessionId, computerId, body.encryptedSecret, now, MAX_BINDINGS_PER_CLIENT),
    env.DB.prepare(
      `INSERT OR IGNORE INTO client_computers
         (client_id, computer_id, mutation_id, created_at)
       SELECT client_id, computer_id, ?3, ?4
         FROM pairing_claims
        WHERE code_id = ?1 AND computer_id = ?2 AND encrypted_secret = ?5`,
    ).bind(sessionId, computerId, mutationId, now, body.encryptedSecret),
    env.DB.prepare(
      `UPDATE client_delivery_state
          SET sequence = sequence + 1, last_fingerprint = NULL
        WHERE client_id = (
          SELECT client_id FROM pairing_claims
           WHERE code_id = ?1 AND computer_id = ?2
        )
          AND EXISTS (
            SELECT 1 FROM client_computers
             WHERE client_id = client_delivery_state.client_id
               AND computer_id = ?2 AND mutation_id = ?3
          )`,
    ).bind(sessionId, computerId, mutationId),
    env.DB.prepare(
      `DELETE FROM relay_revocation_outbox
        WHERE kind = 'client' AND computer_id = ?2
          AND principal_id = (
            SELECT client_id FROM pairing_claims
             WHERE code_id = ?1 AND computer_id = ?2
          )`,
    ).bind(sessionId, computerId),
    env.DB.prepare(
      `SELECT client_id AS clientId, encrypted_secret AS encryptedSecret
         FROM pairing_claims
        WHERE code_id = ?1 AND computer_id = ?2 AND expires_at > ?3`,
    ).bind(sessionId, computerId, now),
  ]);
  const proof = results[4].results?.[0];
  if (!proof || proof.encryptedSecret !== body.encryptedSecret) {
    throw new ApiFailure(400, "invalid_pairing_session", "pairing session is closed or expired");
  }
  const inserted = Number(results[1].meta?.changes ?? 0) === 1;
  if (inserted) {
    background(ctx, notifyPushCoordinator(env, [proof.clientId]), "binding push notify failed");
  }
  return json({ computerId, bound: true }, inserted ? 201 : 200);
}

/// GET /v2/clients/me/pairing-sessions/:sid — legacy client poll.
async function getClientSession(request, env, sessionId) {
  const client = await requireControlClient(request, env);
  const now = nowSeconds();
  const row = await env.DB.prepare(
    `SELECT computer_id AS computerId, encrypted_secret AS encryptedSecret,
            expires_at AS expiresAt
       FROM pairing_claims
      WHERE code_id = ?1 AND client_id = ?2 AND expires_at > ?3`,
  ).bind(sessionId, client.id, now).first();
  if (!row) {
    throw new ApiFailure(410, "pairing_session_expired", "pairing session is closed or expired");
  }
  return json({
    status: row.encryptedSecret === null ? "waiting" : "completed",
    computerId: row.computerId,
    expiresAt: Number(row.expiresAt),
    ...(row.encryptedSecret === null ? {} : { encryptedSecret: row.encryptedSecret }),
  });
}

/// DELETE /v2/clients/me/pairing-sessions/:sid — legacy acknowledgement:
/// consumes the claim and retires the single-use code so it can never be
/// claimed again inside its remaining lifetime.
async function acknowledgeSession(request, env, sessionId) {
  const client = await requireControlClient(request, env);
  await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM pairing_claims
        WHERE code_id = ?1 AND client_id = ?2 AND encrypted_secret IS NOT NULL`,
    ).bind(sessionId, client.id),
    env.DB.prepare(
      `DELETE FROM pairing_codes
        WHERE id = ?1 AND single_use = 1
          AND NOT EXISTS (
            SELECT 1 FROM pairing_claims WHERE code_id = ?1
          )`,
    ).bind(sessionId),
  ]);
  return new Response(null, { status: 204 });
}

/// Routes the six legacy endpoints; returns null for every other path.
export async function handleLegacyPairing(request, env, ctx, url) {
  const pathname = url.pathname;

  let match = /^\/v2\/computers\/([0-9a-f]{32})\/pairing-sessions$/.exec(pathname);
  if (match && request.method === "POST") {
    return createSession(request, env, match[1]);
  }
  match = /^\/v2\/computers\/([0-9a-f]{32})\/pairing-sessions\/([0-9a-f]{32})$/.exec(pathname);
  if (match && request.method === "GET") {
    return getHostSession(request, env, match[1], match[2]);
  }
  if (match && request.method === "DELETE") {
    return cancelHostSession(request, env, match[1], match[2]);
  }
  match = /^\/v2\/computers\/([0-9a-f]{32})\/pairing-sessions\/([0-9a-f]{32})\/complete$/
    .exec(pathname);
  if (match && request.method === "POST") {
    return completeSession(request, env, ctx, match[1], match[2]);
  }
  if (request.method === "POST" && pathname === "/v2/clients/me/pairing-sessions/claim") {
    return claimSession(request, env);
  }
  match = /^\/v2\/clients\/me\/pairing-sessions\/([0-9a-f]{32})$/.exec(pathname);
  if (match && request.method === "GET") {
    return getClientSession(request, env, match[1]);
  }
  if (match && request.method === "DELETE") {
    return acknowledgeSession(request, env, match[1]);
  }
  return null;
}
