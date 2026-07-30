import {
  ApiFailure,
  PAIRING_CODE_TTL_SECONDS,
  MAX_BINDINGS_PER_CLIENT,
  MAX_CLIENTS,
  MAX_COMPUTERS,
  aggregateClientState,
  apiError,
  authenticateClient,
  authenticateComputerReset,
  authenticateHost,
  authenticateStatusClient,
  clientAddress,
  clientIdsForComputer,
  deliverClientRelayRevocation,
  deliverComputerRelayRevocation,
  enforceRateLimit,
  isId,
  isPushSurface,
  json,
  notifyPushCoordinator,
  randomId,
  randomPairingCode,
  randomToken,
  rateLimitKey,
  readJson,
  touchClient,
  tokenHash,
} from "./core.mjs";

const APNS_TOKEN = /^[0-9a-fA-F]{16,512}$/;
const PAIRING_CODE = /^\d{8}$/;
const CURVE25519_PUBLIC_KEY = /^[A-Za-z0-9_-]{43}$/;
const ENCRYPTED_SECRET = /^[A-Za-z0-9_-]{64,256}$/;
const CLIENT_TOKEN = /^[A-Za-z0-9_-]{32,128}$/;

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function requireBodyShape(body, required, optional = []) {
  const allowed = new Set([...required, ...optional]);
  if (
    required.some((key) => !Object.hasOwn(body, key)) ||
    Object.keys(body).some((key) => !allowed.has(key))
  ) {
    throw new ApiFailure(400, "invalid_request", "request body has an invalid shape");
  }
}

function requireQueryShape(url, { activityId = false } = {}) {
  const keys = [...url.searchParams.keys()];
  if (
    keys.some((key) => key !== "activityId") ||
    (!activityId && keys.length > 0) ||
    url.searchParams.getAll("activityId").length > 1
  ) {
    throw new ApiFailure(400, "invalid_query", "request query has an invalid shape");
  }
}

function background(ctx, promise, label) {
  ctx.waitUntil(
    promise.catch((error) => {
      console.error(label, error instanceof Error ? error.message : error);
    }),
  );
}

async function limitByAddress(request, env, bindingName, code, message) {
  await enforceRateLimit(env, bindingName, clientAddress(request), { code, message });
}

async function limitAuthenticated(request, env, bindingName, route, principalId) {
  const key = await rateLimitKey(route, principalId, clientAddress(request));
  await enforceRateLimit(env, bindingName, key);
}

function computerRevocationStatement(env, computerId, now, revocationId = randomId()) {
  return env.DB.prepare(
    `INSERT INTO relay_revocation_outbox
       (id, kind, computer_id, principal_id, created_at, attempt_count,
        next_attempt_at, last_error)
     VALUES (?1, 'computer', ?2, '', ?3, 0, 0, NULL)
     ON CONFLICT(kind, computer_id, principal_id) DO UPDATE SET
       attempt_count = 0,
       next_attempt_at = 0,
       last_error = NULL`,
  ).bind(revocationId, computerId, now);
}

function clientRevocationStatement(
  env,
  computerId,
  clientId,
  now,
  revocationId = randomId(),
) {
  return env.DB.prepare(
    `INSERT INTO relay_revocation_outbox
       (id, kind, computer_id, principal_id, created_at, attempt_count,
        next_attempt_at, last_error)
     SELECT ?1, 'client', ?2, ?3, ?4, 0, 0, NULL
      WHERE EXISTS (
        SELECT 1 FROM client_computers
         WHERE client_id = ?3 AND computer_id = ?2
     )
     ON CONFLICT(kind, computer_id, principal_id) DO UPDATE SET
       id = excluded.id,
       created_at = excluded.created_at,
       attempt_count = 0,
       next_attempt_at = 0,
       last_error = NULL`,
  ).bind(revocationId, computerId, clientId, now);
}

async function createComputer(request, env) {
  await limitByAddress(
    request,
    env,
    "COMPUTER_REGISTRATION_LIMITER",
    "computer_registration_rate_limited",
    "too many computer registrations from this address",
  );
  const body = await readJson(request, { allowEmpty: true });
  requireBodyShape(body, []);
  const computerId = randomId();
  const hostToken = randomToken();
  const hash = await tokenHash(hostToken);
  const now = nowSeconds();
  const results = await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO computers (id, host_token_hash, created_at)
       SELECT ?1, ?2, ?3
        WHERE (SELECT COUNT(*) FROM computers) < ?4`,
    ).bind(computerId, hash, now, MAX_COMPUTERS),
    env.DB.prepare(
      `INSERT INTO computer_state
         (computer_id, revision, host_name, running_terminal_count, online, updated_at)
       SELECT ?1, 0, NULL, 0, 0, ?2
        WHERE EXISTS (SELECT 1 FROM computers WHERE id = ?1)`,
    ).bind(computerId, now),
  ]);
  if (Number(results[0].meta?.changes ?? 0) !== 1) {
    throw new ApiFailure(
      503,
      "computer_capacity_exhausted",
      `service computer capacity (${MAX_COMPUTERS}) is exhausted`,
      { "retry-after": "3600" },
    );
  }
  return json({ computerId, hostToken }, 201);
}

async function createPairingSession(request, env, computerId) {
  const host = await authenticateHost(request, env.DB, computerId);
  if (!host) return apiError(401, "unauthorized", "valid host bearer required");
  await limitAuthenticated(request, env, "INVITE_LIMITER", "pairing-session", host.id);
  const body = await readJson(request);
  requireBodyShape(body, ["hostPublicKey"]);
  if (!CURVE25519_PUBLIC_KEY.test(body.hostPublicKey)) {
    throw new ApiFailure(400, "invalid_public_key", "host public key is invalid");
  }

  const createdAt = nowSeconds();
  const expiresAt = createdAt + PAIRING_CODE_TTL_SECONDS;
  await env.DB.prepare(`DELETE FROM pairing_sessions WHERE computer_id = ?1`)
    .bind(computerId)
    .run();

  for (let attempt = 0; attempt < 8; attempt += 1) {
    const code = randomPairingCode();
    const codeHash = await tokenHash(code);
    const sessionId = randomId();
    const inserted = await env.DB.prepare(
      `INSERT OR IGNORE INTO pairing_sessions
         (id, code_hash, computer_id, host_public_key, client_public_key,
          claimed_by, encrypted_secret, created_at, expires_at, completed_at)
       VALUES (?1, ?2, ?3, ?4, NULL, NULL, NULL, ?5, ?6, NULL)`,
    ).bind(sessionId, codeHash, computerId, body.hostPublicKey, createdAt, expiresAt).run();
    if (Number(inserted.meta?.changes ?? 0) === 1) {
      return json({ sessionId, code, expiresAt }, 201);
    }
  }
  throw new ApiFailure(503, "pairing_code_unavailable", "could not allocate a pairing code");
}

async function getHostPairingSession(request, env, computerId, sessionId) {
  const host = await authenticateHost(request, env.DB, computerId);
  if (!host) return apiError(401, "unauthorized", "valid host bearer required");
  const now = nowSeconds();
  const row = await env.DB.prepare(
    `SELECT client_public_key AS clientPublicKey,
            encrypted_secret AS encryptedSecret,
            expires_at AS expiresAt,
            completed_at AS completedAt
       FROM pairing_sessions
      WHERE id = ?1 AND computer_id = ?2 AND expires_at > ?3`,
  ).bind(sessionId, computerId, now).first();
  if (!row) throw new ApiFailure(410, "pairing_session_expired", "pairing session is closed or expired");
  const status = row.completedAt !== null
    ? "completed"
    : row.clientPublicKey === null ? "waiting" : "claimed";
  return json({
    status,
    expiresAt: Number(row.expiresAt),
    ...(row.clientPublicKey === null ? {} : { clientPublicKey: row.clientPublicKey }),
  });
}

async function cancelHostPairingSession(request, env, computerId, sessionId) {
  const host = await authenticateHost(request, env.DB, computerId);
  if (!host) return apiError(401, "unauthorized", "valid host bearer required");
  await env.DB.prepare(
    `DELETE FROM pairing_sessions WHERE id = ?1 AND computer_id = ?2`,
  ).bind(sessionId, computerId).run();
  return new Response(null, { status: 204 });
}

async function claimPairingSession(request, env) {
  const client = await requireControlClient(request, env);
  await limitAuthenticated(request, env, "MUTATION_LIMITER", "pairing-claim", client.id);
  const body = await readJson(request);
  requireBodyShape(body, ["code", "clientPublicKey"]);
  if (!PAIRING_CODE.test(body.code) || !CURVE25519_PUBLIC_KEY.test(body.clientPublicKey)) {
    throw new ApiFailure(400, "invalid_pairing_code", "pairing code is invalid or expired");
  }

  const hash = await tokenHash(body.code);
  const now = nowSeconds();
  await env.DB.prepare(
    `UPDATE pairing_sessions
        SET claimed_by = ?2, client_public_key = ?3
      WHERE code_hash = ?1
        AND expires_at > ?4
        AND completed_at IS NULL
        AND claimed_by IS NULL
        AND (
              SELECT COUNT(*) FROM client_computers WHERE client_id = ?2
            ) < ?5`,
  ).bind(hash, client.id, body.clientPublicKey, now, MAX_BINDINGS_PER_CLIENT).run();

  const row = await env.DB.prepare(
    `SELECT id AS sessionId, computer_id AS computerId,
            host_public_key AS hostPublicKey, expires_at AS expiresAt
       FROM pairing_sessions
      WHERE code_hash = ?1
        AND claimed_by = ?2
        AND client_public_key = ?3
        AND expires_at > ?4
        AND completed_at IS NULL`,
  ).bind(hash, client.id, body.clientPublicKey, now).first();
  if (!row) {
    const atCapacity = await env.DB.prepare(
      `SELECT COUNT(*) >= ?2 AS full FROM client_computers WHERE client_id = ?1`,
    ).bind(client.id, MAX_BINDINGS_PER_CLIENT).first("full");
    if (Number(atCapacity) === 1) {
      throw new ApiFailure(429, "binding_limit", `a client may bind at most ${MAX_BINDINGS_PER_CLIENT} computers`);
    }
    throw new ApiFailure(400, "invalid_pairing_code", "pairing code is invalid or expired");
  }
  return json({
    sessionId: row.sessionId,
    computerId: row.computerId,
    hostPublicKey: row.hostPublicKey,
    expiresAt: Number(row.expiresAt),
  });
}

async function completePairingSession(request, env, ctx, computerId, sessionId) {
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
      `UPDATE pairing_sessions
          SET encrypted_secret = ?3, completed_at = ?4
        WHERE id = ?1 AND computer_id = ?2
          AND claimed_by IS NOT NULL
          AND encrypted_secret IS NULL
          AND expires_at > ?4
          AND (
                EXISTS (
                  SELECT 1 FROM client_computers
                   WHERE client_id = pairing_sessions.claimed_by AND computer_id = ?2
                )
                OR (
                  SELECT COUNT(*) FROM client_computers
                   WHERE client_id = pairing_sessions.claimed_by
                ) < ?5
              )`,
    ).bind(sessionId, computerId, body.encryptedSecret, now, MAX_BINDINGS_PER_CLIENT),
    env.DB.prepare(
      `INSERT OR IGNORE INTO client_computers
         (client_id, computer_id, mutation_id, created_at)
       SELECT claimed_by, computer_id, ?3, ?4
         FROM pairing_sessions
        WHERE id = ?1 AND computer_id = ?2
          AND encrypted_secret = ?5 AND completed_at = ?4`,
    ).bind(sessionId, computerId, mutationId, now, body.encryptedSecret),
    env.DB.prepare(
      `UPDATE client_delivery_state
          SET sequence = sequence + 1, last_fingerprint = NULL
        WHERE client_id = (
          SELECT claimed_by FROM pairing_sessions WHERE id = ?1 AND computer_id = ?2
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
            SELECT claimed_by FROM pairing_sessions WHERE id = ?1 AND computer_id = ?2
          )`,
    ).bind(sessionId, computerId),
    env.DB.prepare(
      `SELECT claimed_by AS clientId, encrypted_secret AS encryptedSecret
         FROM pairing_sessions
        WHERE id = ?1 AND computer_id = ?2 AND expires_at > ?3`,
    ).bind(sessionId, computerId, now),
  ]);
  const proof = results[4].results?.[0];
  if (!proof || proof.encryptedSecret !== body.encryptedSecret) {
    throw new ApiFailure(400, "invalid_pairing_session", "pairing session is closed or expired");
  }
  const inserted = Number(results[1].meta?.changes ?? 0) === 1;
  if (inserted) background(ctx, notifyPushCoordinator(env, [proof.clientId]), "binding push notify failed");
  return json({ computerId, bound: true }, inserted ? 201 : 200);
}

async function getClientPairingSession(request, env, sessionId) {
  const client = await requireControlClient(request, env);
  const now = nowSeconds();
  const row = await env.DB.prepare(
    `SELECT computer_id AS computerId, encrypted_secret AS encryptedSecret,
            expires_at AS expiresAt, completed_at AS completedAt
       FROM pairing_sessions
      WHERE id = ?1 AND claimed_by = ?2 AND expires_at > ?3`,
  ).bind(sessionId, client.id, now).first();
  if (!row) throw new ApiFailure(410, "pairing_session_expired", "pairing session is closed or expired");
  return json({
    status: row.completedAt === null ? "waiting" : "completed",
    computerId: row.computerId,
    expiresAt: Number(row.expiresAt),
    ...(row.encryptedSecret === null ? {} : { encryptedSecret: row.encryptedSecret }),
  });
}

async function acknowledgeClientPairingSession(request, env, sessionId) {
  const client = await requireControlClient(request, env);
  await env.DB.prepare(
    `DELETE FROM pairing_sessions WHERE id = ?1 AND claimed_by = ?2 AND completed_at IS NOT NULL`,
  ).bind(sessionId, client.id).run();
  return new Response(null, { status: 204 });
}

async function createClient(request, env) {
  await limitByAddress(
    request,
    env,
    "CLIENT_REGISTRATION_LIMITER",
    "client_registration_rate_limited",
    "too many client registrations from this address",
  );
  const body = await readJson(request, { allowEmpty: true });
  requireBodyShape(body, []);
  const clientId = randomId();
  const clientToken = randomToken();
  const statusToken = randomToken();
  const [hash, statusHash] = await Promise.all([
    tokenHash(clientToken),
    tokenHash(statusToken),
  ]);
  const now = nowSeconds();
  const results = await env.DB.batch([
    env.DB.prepare(
       `INSERT INTO clients
         (id, auth_token_hash, status_token_hash, created_at, last_seen_at)
       SELECT ?1, ?2, ?3, ?4, ?4
        WHERE (SELECT COUNT(*) FROM clients) < ?5`,
    ).bind(clientId, hash, statusHash, now, MAX_CLIENTS),
    env.DB.prepare(
       `INSERT INTO client_delivery_state
         (client_id, sequence, last_fingerprint, last_pushed_at)
       SELECT ?1, 0, NULL, NULL
        WHERE EXISTS (SELECT 1 FROM clients WHERE id = ?1)`,
    ).bind(clientId),
  ]);
  if (Number(results[0].meta?.changes ?? 0) !== 1) {
    throw new ApiFailure(
      503,
      "client_capacity_exhausted",
      `service client capacity (${MAX_CLIENTS}) is exhausted`,
      { "retry-after": "3600" },
    );
  }
  return json({ clientId, clientToken, statusToken }, 201);
}

async function requireControlClient(request, env) {
  const client = await authenticateClient(request, env.DB);
  if (!client) throw new ApiFailure(401, "unauthorized", "valid client bearer required");
  await touchClient(env.DB, client.id);
  return client;
}

async function requireStatusClient(request, env) {
  const client = await authenticateStatusClient(request, env.DB);
  if (!client) throw new ApiFailure(401, "unauthorized", "valid status bearer required");
  await touchClient(env.DB, client.id);
  return client;
}

async function reconcileBindings(request, env, ctx) {
  const client = await requireControlClient(request, env);
  await limitAuthenticated(request, env, "MUTATION_LIMITER", "bindings", client.id);
  const body = await readJson(request);
  requireBodyShape(body, ["computerIds"]);
  const declared = body.computerIds;
  if (
    !Array.isArray(declared) ||
    declared.length > MAX_BINDINGS_PER_CLIENT ||
    !declared.every((value) => isId(value)) ||
    new Set(declared).size !== declared.length
  ) {
    throw new ApiFailure(
      400,
      "invalid_bindings",
      `computerIds must be at most ${MAX_BINDINGS_PER_CLIENT} unique computer ids`,
    );
  }
  const declaredSet = new Set(declared);
  const delegates = await env.DB.prepare(
    `SELECT delegate_client_id AS clientId
       FROM client_delegates
      WHERE parent_client_id = ?1
      ORDER BY delegate_client_id`,
  ).bind(client.id).all();
  const principalIds = [client.id, ...delegates.results.map((row) => row.clientId)];
  const principalMarks = principalIds.map(() => "?").join(", ");
  const current = await env.DB.prepare(
    `SELECT DISTINCT computer_id AS computerId
       FROM client_computers
      WHERE client_id IN (${principalMarks})
      ORDER BY computer_id`,
  ).bind(...principalIds).all();
  const currentIds = (current.results ?? []).map((row) => row.computerId);
  // Delete-only convergence: the declared list can never create an edge, so a
  // cloned credential cannot self-authorize a computer. Edges created by a
  // concurrent pairing completion are outside the removal set and survive.
  const removedIds = currentIds.filter((computerId) => !declaredSet.has(computerId));
  const remaining = currentIds.filter((computerId) => declaredSet.has(computerId));
  if (removedIds.length === 0) {
    return json({ computerIds: remaining });
  }
  const now = nowSeconds();
  const removalMarks = removedIds.map(() => "?").join(", ");
  const deliveryStatements = principalIds.map((clientId) => env.DB.prepare(
      `UPDATE client_delivery_state
          SET sequence = sequence + 1,
              last_fingerprint = NULL
        WHERE client_id = ?
          AND EXISTS (
                SELECT 1 FROM client_computers
                 WHERE client_id = ? AND computer_id IN (${removalMarks})
              )`,
    ).bind(clientId, clientId, ...removedIds));
  const revocationStatements = principalIds.flatMap((clientId) =>
    removedIds.map((computerId) =>
      clientRevocationStatement(env, computerId, clientId, now)));
  const deleteStatements = principalIds.map((clientId) => env.DB.prepare(
      `DELETE FROM client_computers
        WHERE client_id = ? AND computer_id IN (${removalMarks})`,
    ).bind(clientId, ...removedIds));
  const results = await env.DB.batch([
    ...deliveryStatements,
    ...revocationStatements,
    ...deleteStatements,
    env.DB.prepare(
      `SELECT id AS revocationId, computer_id AS computerId,
              principal_id AS clientId
         FROM relay_revocation_outbox
        WHERE kind = 'client'
          AND principal_id IN (${principalMarks})
          AND computer_id IN (${removalMarks})
        ORDER BY principal_id, computer_id`,
    ).bind(...principalIds, ...removedIds),
  ]);
  const deleteStart = deliveryStatements.length + revocationStatements.length;
  const removed = results.slice(deleteStart, deleteStart + deleteStatements.length)
    .some((result) => Number(result.meta?.changes ?? 0) > 0);
  const revocations = results[results.length - 1].results ?? [];
  // The D1 transaction is the access-revocation commit boundary. An eager
  // Durable Object call keeps the common path immediate; a failed call leaves
  // the outbox row due for the minute cron instead of restoring the binding.
  for (const revocation of revocations) {
    try {
      await deliverClientRelayRevocation(
        env,
        revocation.computerId,
        revocation.clientId,
        revocation.revocationId,
      );
    } catch (error) {
      console.error(
        "client socket revocation failed",
        error instanceof Error ? error.message : error,
      );
    }
  }
  if (removed) {
    background(ctx, notifyPushCoordinator(env, principalIds), "binding reconcile push notify failed");
  }
  return json({ computerIds: remaining });
}

async function synchronizeDelegatedBindings(request, env, ctx) {
  const client = await requireControlClient(request, env);
  await limitAuthenticated(
    request,
    env,
    "MUTATION_LIMITER",
    "delegated-bindings",
    client.id,
  );
  const body = await readJson(request);
  requireBodyShape(body, ["clientId", "clientToken"]);
  if (!isId(body.clientId) || !CLIENT_TOKEN.test(body.clientToken)) {
    throw new ApiFailure(400, "invalid_delegate", "delegated client credential is invalid");
  }
  if (body.clientId === client.id) {
    throw new ApiFailure(400, "invalid_delegate", "a client cannot delegate to itself");
  }

  const delegateTokenHash = await tokenHash(body.clientToken);
  const delegate = await env.DB.prepare(
    `SELECT id
       FROM clients
      WHERE id = ?1 AND auth_token_hash = ?2 AND revoked_at IS NULL`,
  ).bind(body.clientId, delegateTokenHash).first();
  if (!delegate) {
    throw new ApiFailure(403, "invalid_delegate", "delegated client credential is invalid");
  }

  const relationship = await env.DB.batch([
    env.DB.prepare(
      `SELECT parent_client_id AS parentClientId
         FROM client_delegates
        WHERE delegate_client_id = ?1`,
    ).bind(delegate.id),
    env.DB.prepare(
      `SELECT delegate_client_id AS delegateClientId
         FROM client_delegates
        WHERE parent_client_id = ?1 AND kind = 'watch-terminal'`,
    ).bind(client.id),
    env.DB.prepare(
      `SELECT parent_client_id AS parentClientId
         FROM client_delegates
        WHERE delegate_client_id = ?1`,
    ).bind(client.id),
    env.DB.prepare(
      `SELECT delegated.computer_id AS computerId
         FROM client_computers delegated
        WHERE delegated.client_id = ?1
          AND NOT EXISTS (
                SELECT 1
                  FROM client_computers source
                 WHERE source.client_id = ?2
                   AND source.computer_id = delegated.computer_id
              )
        ORDER BY delegated.computer_id`,
    ).bind(delegate.id, client.id),
  ]);
  const owner = relationship[0].results?.[0]?.parentClientId;
  if (owner !== undefined && owner !== client.id) {
    throw new ApiFailure(403, "invalid_delegate", "delegated client belongs to another client");
  }
  if (relationship[2].results?.length) {
    throw new ApiFailure(403, "invalid_delegate", "a delegated client cannot create delegates");
  }
  const previousDelegateId = relationship[1].results?.[0]?.delegateClientId;
  const replacedDelegateId = previousDelegateId !== undefined && previousDelegateId !== delegate.id
    ? previousDelegateId
    : null;
  const removed = relationship[3].results ?? [];
  const replacedBindings = replacedDelegateId === null
    ? { results: [] }
    : await env.DB.prepare(
      `SELECT computer_id AS computerId
         FROM client_computers
        WHERE client_id = ?1
        ORDER BY computer_id`,
    ).bind(replacedDelegateId).all();

  const now = nowSeconds();
  const removals = [
    ...removed.map((row) => ({ clientId: delegate.id, computerId: row.computerId })),
    ...replacedBindings.results.map((row) => ({
      clientId: replacedDelegateId,
      computerId: row.computerId,
    })),
  ];
  const statements = [
    env.DB.prepare(
      `UPDATE client_delivery_state
          SET sequence = sequence + 1,
              last_fingerprint = NULL
        WHERE client_id = ?1
          AND (
                EXISTS (
                  SELECT 1
                    FROM client_computers source
                   WHERE source.client_id = ?2
                     AND NOT EXISTS (
                           SELECT 1 FROM client_computers delegated
                            WHERE delegated.client_id = ?1
                              AND delegated.computer_id = source.computer_id
                         )
                )
                OR EXISTS (
                  SELECT 1
                    FROM client_computers delegated
                   WHERE delegated.client_id = ?1
                     AND NOT EXISTS (
                           SELECT 1 FROM client_computers source
                            WHERE source.client_id = ?2
                              AND source.computer_id = delegated.computer_id
                         )
                )
              )`,
    ).bind(delegate.id, client.id),
    ...(replacedDelegateId === null ? [] : [env.DB.prepare(
      `UPDATE client_delivery_state
          SET sequence = sequence + 1,
              last_fingerprint = NULL
        WHERE client_id = ?1
          AND EXISTS (SELECT 1 FROM client_computers WHERE client_id = ?1)`,
    ).bind(replacedDelegateId)]),
    ...removals.map((removal) => env.DB.prepare(
      `INSERT INTO relay_revocation_outbox
         (id, kind, computer_id, principal_id, created_at, attempt_count,
          next_attempt_at, last_error)
       SELECT ?1, 'client', ?2, ?3, ?4, 0, 0, NULL
        WHERE EXISTS (
                SELECT 1 FROM client_computers
                 WHERE client_id = ?3 AND computer_id = ?2
              )
       ON CONFLICT(kind, computer_id, principal_id) DO UPDATE SET
         id = excluded.id,
         created_at = excluded.created_at,
         attempt_count = 0,
         next_attempt_at = 0,
         last_error = NULL`,
    ).bind(randomId(), removal.computerId, removal.clientId, now)),
    ...(replacedDelegateId === null ? [] : [
      env.DB.prepare(`DELETE FROM client_computers WHERE client_id = ?1`)
        .bind(replacedDelegateId),
      env.DB.prepare(
        `UPDATE clients SET revoked_at = ?2 WHERE id = ?1 AND revoked_at IS NULL`,
      ).bind(replacedDelegateId, now),
    ]),
    env.DB.prepare(
      `DELETE FROM client_delegates
        WHERE parent_client_id = ?1 AND kind = 'watch-terminal'`,
    ).bind(client.id),
    env.DB.prepare(
      `INSERT INTO client_delegates
         (parent_client_id, delegate_client_id, kind, created_at)
       VALUES (?1, ?2, 'watch-terminal', ?3)`,
    ).bind(client.id, delegate.id, now),
    env.DB.prepare(
      `DELETE FROM client_computers AS delegated
        WHERE delegated.client_id = ?1
          AND NOT EXISTS (
                SELECT 1 FROM client_computers source
                 WHERE source.client_id = ?2
                   AND source.computer_id = delegated.computer_id
              )`,
    ).bind(delegate.id, client.id),
    env.DB.prepare(
      `INSERT OR IGNORE INTO client_computers
         (client_id, computer_id, mutation_id, created_at)
       SELECT ?1, computer_id, ?3, ?4
         FROM client_computers
        WHERE client_id = ?2`,
    ).bind(delegate.id, client.id, randomId(), now),
    env.DB.prepare(
      `DELETE FROM relay_revocation_outbox
        WHERE kind = 'client' AND principal_id = ?1
          AND computer_id IN (
                SELECT computer_id FROM client_computers WHERE client_id = ?2
              )`,
    ).bind(delegate.id, client.id),
    env.DB.prepare(
      `SELECT COUNT(*) AS bindingCount
         FROM client_computers
        WHERE client_id = ?1`,
    ).bind(delegate.id),
    env.DB.prepare(
      `SELECT id AS revocationId, computer_id AS computerId,
              principal_id AS clientId
         FROM relay_revocation_outbox
        WHERE kind = 'client'
          AND (principal_id = ?1 OR principal_id = ?2)
        ORDER BY principal_id, computer_id`,
    ).bind(delegate.id, replacedDelegateId ?? ""),
  ];
  const results = await env.DB.batch(statements);
  const changed = Number(results[0].meta?.changes ?? 0) === 1;
  const countResult = results[results.length - 2].results?.[0];
  const revocations = results[results.length - 1].results ?? [];

  for (const revocation of revocations) {
    try {
      await deliverClientRelayRevocation(
        env,
        revocation.computerId,
        revocation.clientId,
        revocation.revocationId,
      );
    } catch (error) {
      console.error(
        "delegated client socket revocation failed",
        error instanceof Error ? error.message : error,
      );
    }
  }
  if (changed) {
    background(
      ctx,
      notifyPushCoordinator(env, [delegate.id]),
      "delegated binding push notify failed",
    );
  }
  await touchClient(env.DB, delegate.id);
  return json({ bindingCount: Number(countResult?.bindingCount ?? 0) });
}

async function deleteComputer(request, env, ctx, computerId) {
  const resetIdentity = await authenticateComputerReset(request, env.DB, computerId);
  if (!resetIdentity) {
    throw new ApiFailure(401, "unauthorized", "valid host bearer required");
  }
  await limitAuthenticated(request, env, "MUTATION_LIMITER", "reset-computer", computerId);
  if (Number(resetIdentity.deleted) === 1) {
    await computerRevocationStatement(env, computerId, nowSeconds()).run();
    background(
      ctx,
      deliverComputerRelayRevocation(env, computerId),
      "computer socket revocation retry failed",
    );
    return new Response(null, { status: 204 });
  }
  const clientIds = await clientIdsForComputer(env.DB, computerId);
  const now = nowSeconds();
  const revocationId = randomId();
  await env.DB.batch([
    env.DB.prepare(
      `INSERT INTO computer_reset_tombstones
         (computer_id, host_token_hash, deleted_at)
       SELECT id, host_token_hash, ?2 FROM computers WHERE id = ?1`,
    ).bind(computerId, now),
    env.DB.prepare(
      `UPDATE client_delivery_state
          SET sequence = sequence + 1,
              last_fingerprint = NULL
        WHERE client_id IN (
                SELECT client_id FROM client_computers WHERE computer_id = ?1
              )`,
    ).bind(computerId),
    computerRevocationStatement(env, computerId, now, revocationId),
    env.DB.prepare(`DELETE FROM computers WHERE id = ?1`).bind(computerId),
  ]);
  // The D1 transaction is the reset commit boundary. Socket revocation is in a
  // durable outbox committed alongside deletion; this eager attempt reduces
  // latency while cron retains responsibility until the DO acknowledges it.
  background(
    ctx,
    deliverComputerRelayRevocation(env, computerId),
    "computer socket revocation failed",
  );
  background(ctx, notifyPushCoordinator(env, clientIds), "computer reset push notify failed");
  return new Response(null, { status: 204 });
}

async function getClientState(request, env) {
  const client = await requireStatusClient(request, env);
  return json(await aggregateClientState(env.DB, client.id));
}

function pushActivityKey(url, body = undefined) {
  const value = body?.activityId ?? url.searchParams.get("activityId") ?? "";
  if (
    typeof value !== "string" ||
    value.length > 128 ||
    /[\u0000-\u001f\u007f]/.test(value)
  ) {
    throw new ApiFailure(400, "invalid_activity_id", "activityId is invalid");
  }
  return value;
}

async function putPushEndpoint(request, env, surface, url) {
  const client = await requireStatusClient(request, env);
  await limitAuthenticated(
    request,
    env,
    "PUSH_MUTATION_LIMITER",
    `put-push:${surface}`,
    client.id,
  );
  const body = await readJson(request);
  requireBodyShape(body, ["token", "environment"], ["activityId"]);
  if (
    typeof body.token !== "string" ||
    !APNS_TOKEN.test(body.token) ||
    body.token.length % 2 !== 0
  ) {
    throw new ApiFailure(400, "invalid_push_token", "token must be even-length hexadecimal bytes");
  }
  if (body.environment !== "sandbox" && body.environment !== "production") {
    throw new ApiFailure(400, "invalid_environment", "environment must be sandbox or production");
  }
  const activityKey = pushActivityKey(url, body);
  if (surface !== "liveactivity-update" && activityKey !== "") {
    throw new ApiFailure(
      400,
      "invalid_activity_id",
      "activityId is supported only for liveactivity-update",
    );
  }
  const normalizedToken = body.token.toLowerCase();
  const hash = await tokenHash(normalizedToken);
  const endpointId = randomId();
  const now = nowSeconds();
  // A push-to-start token remains untouched by ordinary count sync. Its zero
  // baseline is consumed by a rich working/attention agent event; token
  // rotation preserves a previously consumed baseline until that activity
  // ends.
  const initialSequence = -1;
  const initialTotal = surface === "liveactivity-start" ? 0 : null;

  try {
    await env.DB.batch([
      // Invalid Live Activity update tokens are intentionally short-lived.
      // Clear prior tombstones for this surface before enforcing the active
      // endpoint cap so repeated activities cannot exhaust a client forever.
      env.DB
        .prepare(
          `DELETE FROM push_endpoints
            WHERE client_id = ?1 AND surface = ?2 AND invalidated_at IS NOT NULL`,
        )
        .bind(client.id, surface),
      // APNs can return the same token after an app reinstall. Registration is
      // proof of possession, so atomically transfer that token away from any
      // stale client row instead of permanently rejecting the new install.
      env.DB
        .prepare(
          `DELETE FROM push_endpoints
            WHERE token_hash = ?1
              AND NOT (client_id = ?2 AND surface = ?3 AND activity_key = ?4)`,
        )
        .bind(hash, client.id, surface, activityKey),
      env.DB
        .prepare(
          `INSERT INTO push_endpoints
             (id, client_id, surface, apns_environment, token, token_hash,
              activity_key, created_at, updated_at, invalidated_at,
              last_sequence, last_total_running, retry_not_before,
              failure_count, last_failure_reason)
           VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, NULL, ?9, ?10,
                   NULL, 0, NULL)
           ON CONFLICT(client_id, surface, activity_key) DO UPDATE SET
             apns_environment = excluded.apns_environment,
             token = excluded.token,
             token_hash = excluded.token_hash,
             updated_at = excluded.updated_at,
             invalidated_at = NULL,
             retry_not_before = NULL,
             failure_count = 0,
             last_failure_reason = NULL,
             last_sequence = CASE
               WHEN excluded.surface = 'liveactivity-start' THEN push_endpoints.last_sequence
               ELSE -1
             END,
             last_total_running = CASE
               WHEN excluded.surface = 'liveactivity-start'
                 THEN push_endpoints.last_total_running
               ELSE NULL
             END`,
        )
        .bind(
          endpointId,
          client.id,
          surface,
          body.environment,
          normalizedToken,
          hash,
          activityKey,
          now,
          initialSequence,
          initialTotal,
        ),
    ]);
  } catch (error) {
    if (String(error).includes("push endpoint limit exceeded")) {
      throw new ApiFailure(429, "endpoint_limit", "push endpoint limit exceeded");
    }
    throw error;
  }

  // Registration is the commit boundary for immediate delivery. Do not leave
  // the coordinator wake in waitUntil: callers (and a process shutdown) may
  // observe the successful response before the Durable Object has persisted
  // its pending set and alarm. A failed wake returns an error after the
  // idempotent D1 upsert, so the client can safely retry while cron remains the
  // eventual recovery path.
  await notifyPushCoordinator(env, [client.id], { force: true });
  return json({ surface, activityId: activityKey || null, registered: true });
}

async function deletePushEndpoint(request, env, surface, url) {
  const client = await requireStatusClient(request, env);
  await limitAuthenticated(
    request,
    env,
    "PUSH_MUTATION_LIMITER",
    `delete-push:${surface}`,
    client.id,
  );
  const activityKey = pushActivityKey(url);
  if (surface !== "liveactivity-update" && activityKey !== "") {
    throw new ApiFailure(
      400,
      "invalid_activity_id",
      "activityId is supported only for liveactivity-update",
    );
  }
  const deletion = env.DB
    .prepare(
      `DELETE FROM push_endpoints
        WHERE client_id = ?1 AND surface = ?2 AND activity_key = ?3`,
    )
    .bind(client.id, surface, activityKey);
  if (surface === "liveactivity-update") {
    await env.DB.batch([
      deletion,
      env.DB
        .prepare(
          `UPDATE push_endpoints
              SET last_total_running = 0,
                  updated_at = ?2
            WHERE client_id = ?1
              AND surface = 'liveactivity-start'
              AND invalidated_at IS NULL
              AND NOT EXISTS (
                SELECT 1
                  FROM push_endpoints AS active
                 WHERE active.client_id = ?1
                   AND active.surface = 'liveactivity-update'
                   AND active.invalidated_at IS NULL
              )`,
        )
        .bind(client.id, nowSeconds()),
    ]);
  } else {
    await deletion.run();
  }
  return new Response(null, { status: 204 });
}

export async function handleApi(request, env, ctx, url) {
  const pathname = url.pathname;

  if (request.method === "POST" && pathname === "/v2/computers") {
    requireQueryShape(url);
    return createComputer(request, env);
  }

  let match = /^\/v2\/computers\/([0-9a-f]{32})\/pairing-sessions$/.exec(pathname);
  if (request.method === "POST" && match) {
    requireQueryShape(url);
    return createPairingSession(request, env, match[1]);
  }

  match = /^\/v2\/computers\/([0-9a-f]{32})\/pairing-sessions\/([0-9a-f]{32})$/.exec(pathname);
  if (match && request.method === "GET") {
    requireQueryShape(url);
    return getHostPairingSession(request, env, match[1], match[2]);
  }
  if (match && request.method === "DELETE") {
    requireQueryShape(url);
    return cancelHostPairingSession(request, env, match[1], match[2]);
  }
  match = /^\/v2\/computers\/([0-9a-f]{32})\/pairing-sessions\/([0-9a-f]{32})\/complete$/.exec(pathname);
  if (match && request.method === "POST") {
    requireQueryShape(url);
    return completePairingSession(request, env, ctx, match[1], match[2]);
  }

  match = /^\/v2\/computers\/([0-9a-f]{32})$/.exec(pathname);
  if (request.method === "DELETE" && match) {
    requireQueryShape(url);
    return deleteComputer(request, env, ctx, match[1]);
  }

  if (request.method === "POST" && pathname === "/v2/clients") {
    requireQueryShape(url);
    return createClient(request, env);
  }
  if (request.method === "POST" && pathname === "/v2/clients/me/pairing-sessions/claim") {
    requireQueryShape(url);
    return claimPairingSession(request, env);
  }
  match = /^\/v2\/clients\/me\/pairing-sessions\/([0-9a-f]{32})$/.exec(pathname);
  if (match && request.method === "GET") {
    requireQueryShape(url);
    return getClientPairingSession(request, env, match[1]);
  }
  if (match && request.method === "DELETE") {
    requireQueryShape(url);
    return acknowledgeClientPairingSession(request, env, match[1]);
  }

  if (request.method === "PUT" && pathname === "/v2/clients/me/bindings") {
    requireQueryShape(url);
    return reconcileBindings(request, env, ctx);
  }
  if (request.method === "PUT" && pathname === "/v2/clients/me/delegated-bindings") {
    requireQueryShape(url);
    return synchronizeDelegatedBindings(request, env, ctx);
  }
  if (request.method === "GET" && pathname === "/v2/clients/me/state") {
    requireQueryShape(url);
    return getClientState(request, env);
  }

  match = /^\/v2\/clients\/me\/push-endpoints\/([a-z-]+)$/.exec(pathname);
  if (match && !isPushSurface(match[1])) {
    throw new ApiFailure(400, "invalid_surface", "unsupported push surface");
  }
  if (match && request.method === "PUT") {
    requireQueryShape(url);
    return putPushEndpoint(request, env, match[1], url);
  }
  if (match && request.method === "DELETE") {
    requireQueryShape(url, { activityId: true });
    return deletePushEndpoint(request, env, match[1], url);
  }

  return null;
}
