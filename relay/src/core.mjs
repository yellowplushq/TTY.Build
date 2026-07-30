const TOKEN_PATTERN = /^[A-Za-z0-9_-]{32,128}$/;
const ID_PATTERN = /^[0-9a-f]{32}$/;
const PUSH_SURFACES = new Set([
  "ios-widget",
  "watch-widget",
  "liveactivity-start",
  "liveactivity-update",
]);

export const MAX_JSON_BODY = 16 * 1024;
export const PAIRING_CODE_TTL_SECONDS = 15 * 60;
export const SNAPSHOT_VERSION = 2;
export const MAX_COMPUTERS = 128;
export const MAX_CLIENTS = 512;
export const MAX_BINDINGS_PER_CLIENT = 32;
export const ORPHAN_CLIENT_RETENTION_SECONDS = 24 * 60 * 60;
export const ORPHAN_COMPUTER_RETENTION_SECONDS = 7 * 24 * 60 * 60;

const JSON_HEADERS = {
  "content-type": "application/json; charset=utf-8",
  "cache-control": "no-store",
};

export function json(value, status = 200, extraHeaders = undefined) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { ...JSON_HEADERS, ...extraHeaders },
  });
}

export function apiError(status, code, message, extraHeaders = undefined) {
  return json({ error: { code, message } }, status, extraHeaders);
}

export async function readJson(request, { allowEmpty = false } = {}) {
  const declaredLength = request.headers.get("content-length");
  const length = declaredLength === null ? null : Number(declaredLength);
  if (length !== null && Number.isFinite(length) && length > MAX_JSON_BODY) {
    throw new ApiFailure(413, "body_too_large", "request body exceeds 16 KiB");
  }

  const chunks = [];
  let total = 0;
  if (request.body !== null) {
    const reader = request.body.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = value instanceof Uint8Array ? value : new Uint8Array(value);
      total += chunk.byteLength;
      if (total > MAX_JSON_BODY) {
        await reader.cancel("request body too large");
        throw new ApiFailure(413, "body_too_large", "request body exceeds 16 KiB");
      }
      chunks.push(chunk);
    }
  }
  if (total === 0 && allowEmpty) return {};
  if (total === 0) {
    throw new ApiFailure(400, "invalid_json", "a JSON request body is required");
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  try {
    const value = JSON.parse(new TextDecoder().decode(bytes));
    if (!value || Array.isArray(value) || typeof value !== "object") {
      throw new Error("JSON object required");
    }
    return value;
  } catch {
    throw new ApiFailure(400, "invalid_json", "request body must be a JSON object");
  }
}

export class ApiFailure extends Error {
  constructor(status, code, message, headers = undefined) {
    super(message);
    this.status = status;
    this.code = code;
    this.headers = headers;
  }
}

export function failureResponse(error) {
  if (error instanceof ApiFailure) {
    return apiError(error.status, error.code, error.message, error.headers);
  }
  console.error("unhandled API failure", error instanceof Error ? error.message : error);
  return apiError(500, "internal_error", "internal server error");
}

export function isId(value) {
  return typeof value === "string" && ID_PATTERN.test(value);
}

export function isPushSurface(value) {
  return typeof value === "string" && PUSH_SURFACES.has(value);
}

export function bearerToken(request) {
  const value = request.headers.get("authorization") ?? "";
  const match = /^Bearer ([A-Za-z0-9_-]+)$/.exec(value);
  if (!match || !TOKEN_PATTERN.test(match[1])) return null;
  return match[1];
}

function base64Url(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export function randomToken(byteCount = 32) {
  const bytes = new Uint8Array(byteCount);
  crypto.getRandomValues(bytes);
  return base64Url(bytes);
}

export function randomId() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/// Uniformly generates an 8-digit decimal rendezvous code, including leading
/// zeroes. Rejection sampling avoids modulo bias from the UInt32 source.
export function randomPairingCode() {
  const range = 100_000_000;
  const limit = Math.floor(0x1_0000_0000 / range) * range;
  const value = new Uint32Array(1);
  do {
    crypto.getRandomValues(value);
  } while (value[0] >= limit);
  return String(value[0] % range).padStart(8, "0");
}

export async function tokenHash(token) {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)),
  );
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function clientAddress(request) {
  const value = request.headers.get("cf-connecting-ip")?.trim();
  return value && value.length <= 64 ? value : "unknown";
}

export async function rateLimitKey(...parts) {
  return tokenHash(parts.join("\u001f"));
}

/**
 * Consume one native Workers Rate Limiting token.
 *
 * Production fails closed if a configured binding is unavailable. Worker tests
 * explicitly inject TEST_BYPASS_RATE_LIMITS so a missing local implementation
 * can never silently weaken the deployed service.
 */
export async function enforceRateLimit(
  env,
  bindingName,
  key,
  { code = "rate_limited", message = "request rate limit exceeded" } = {},
) {
  if (env.TEST_BYPASS_RATE_LIMITS === "true") return;
  const limiter = env[bindingName];
  if (!limiter || typeof limiter.limit !== "function") {
    throw new ApiFailure(
      503,
      "rate_limiter_unavailable",
      "request protection is temporarily unavailable",
      { "retry-after": "60" },
    );
  }

  let result;
  try {
    result = await limiter.limit({ key });
  } catch {
    throw new ApiFailure(
      503,
      "rate_limiter_unavailable",
      "request protection is temporarily unavailable",
      { "retry-after": "60" },
    );
  }
  if (result?.success !== true) {
    throw new ApiFailure(429, code, message, { "retry-after": "60" });
  }
}

export async function authenticateClient(request, db) {
  const token = bearerToken(request);
  if (!token) return null;
  const hash = await tokenHash(token);
  return db
    .prepare(
      `SELECT id
         FROM clients
        WHERE auth_token_hash = ?1 AND revoked_at IS NULL`,
    )
    .bind(hash)
    .first();
}

export async function touchClient(db, clientId, nowSeconds = Math.floor(Date.now() / 1000)) {
  await db
    .prepare(
      `UPDATE clients
          SET last_seen_at = ?2
        WHERE id = ?1 AND last_seen_at < ?3`,
    )
    .bind(clientId, nowSeconds, nowSeconds - 60 * 60)
    .run();
}

export async function authenticateStatusClient(request, db) {
  const token = bearerToken(request);
  if (!token) return null;
  const hash = await tokenHash(token);
  return db
    .prepare(
      `SELECT id
         FROM clients
        WHERE status_token_hash = ?1 AND revoked_at IS NULL`,
    )
    .bind(hash)
    .first();
}

export async function authenticateHost(request, db, computerId) {
  const token = bearerToken(request);
  if (!token) return null;
  const hash = await tokenHash(token);
  return db
    .prepare(
      `SELECT id
         FROM computers
        WHERE id = ?1 AND host_token_hash = ?2 AND revoked_at IS NULL`,
    )
    .bind(computerId, hash)
    .first();
}

export async function authenticateComputerReset(request, db, computerId) {
  const token = bearerToken(request);
  if (!token) return null;
  const hash = await tokenHash(token);
  return db
    .prepare(
      `SELECT deleted
         FROM (
           SELECT 0 AS deleted
             FROM computers
            WHERE id = ?1 AND host_token_hash = ?2 AND revoked_at IS NULL
           UNION ALL
           SELECT 1 AS deleted
             FROM computer_reset_tombstones
            WHERE computer_id = ?1 AND host_token_hash = ?2
         )
        ORDER BY deleted
        LIMIT 1`,
    )
    .bind(computerId, hash)
    .first();
}

export async function authorizeRelay(request, db, computerId) {
  const token = bearerToken(request);
  if (!token) return null;
  const hash = await tokenHash(token);
  return db
    .prepare(
      `SELECT role, principal_id AS principalId
         FROM (
           SELECT 'host' AS role, id AS principal_id, 0 AS rank
             FROM computers
            WHERE id = ?1 AND host_token_hash = ?2 AND revoked_at IS NULL
           UNION ALL
           SELECT 'client' AS role, c.id AS principal_id, 1 AS rank
             FROM clients c
             JOIN client_computers b ON b.client_id = c.id
             JOIN computers h ON h.id = b.computer_id
            WHERE b.computer_id = ?1
              AND c.auth_token_hash = ?2
              AND c.revoked_at IS NULL
              AND h.revoked_at IS NULL
         )
        ORDER BY rank
        LIMIT 1`,
    )
    .bind(computerId, hash)
    .first();
}

export async function clientIdsForComputer(db, computerId) {
  const result = await db
    .prepare(
      `SELECT client_id AS clientId
         FROM client_computers
        WHERE computer_id = ?1`,
    )
    .bind(computerId)
    .all();
  return result.results.map((row) => row.clientId);
}

export async function notifyPushCoordinator(env, clientIds, { force = false } = {}) {
  const ids = [...new Set(clientIds)].filter(isId);
  if (ids.length === 0 || !env.PUSH_COORDINATOR) return;
  for (const clientId of ids) {
    const stub = env.PUSH_COORDINATOR.getByName(clientId);
    const response = await stub.fetch("https://push.internal/invalidate", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ clientIds: [clientId], force }),
    });
    if (!response.ok) throw new Error(`push coordinator returned ${response.status}`);
  }
}

/// Best-effort, non-persistent rich Live Activity update. The Worker routes
/// the server-visible state and opaque ciphertext directly to each client's
/// ActivityKit endpoints; D1 remains limited to aggregate counts.
export async function notifyAgentActivity(env, computerId, activity) {
  if (!env.PUSH_COORDINATOR || !isId(computerId)) return;
  const clientIds = await clientIdsForComputer(env.DB, computerId);
  for (const clientId of clientIds) {
    const response = await env.PUSH_COORDINATOR.getByName(clientId).fetch(
      "https://push.internal/activity",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ clientId, computerId, activity }),
      },
    );
    if (!response.ok) throw new Error(`push coordinator returned ${response.status}`);
  }
}

async function relayRevocation(env, computerId, path, principalId = undefined) {
  if (!env.RELAY_CHANNELS || !isId(computerId)) return;
  const headers = new Headers({ "x-pedals-computer-id": computerId });
  if (principalId !== undefined) {
    if (!isId(principalId)) return;
    headers.set("x-pedals-principal-id", principalId);
  }
  const response = await env.RELAY_CHANNELS.getByName(computerId).fetch(
    `https://relay.internal${path}`,
    { method: "POST", headers },
  );
  if (!response.ok) throw new Error(`relay revocation returned ${response.status}`);
}

export function closeRelayClientSockets(env, computerId, clientId) {
  return relayRevocation(env, computerId, "/internal/revoke-client", clientId);
}

export function closeRelayComputerSockets(env, computerId) {
  return relayRevocation(env, computerId, "/internal/revoke-computer");
}

export async function deliverClientRelayRevocation(
  env,
  computerId,
  clientId,
  revocationId,
) {
  await closeRelayClientSockets(env, computerId, clientId);
  await env.DB
    .prepare(
      `DELETE FROM relay_revocation_outbox
        WHERE id = ?3
          AND kind = 'client'
          AND computer_id = ?1
          AND principal_id = ?2`,
    )
    .bind(computerId, clientId, revocationId)
    .run();
}

export async function deliverComputerRelayRevocation(env, computerId) {
  await closeRelayComputerSockets(env, computerId);
  await env.DB
    .prepare(
      `DELETE FROM relay_revocation_outbox
        WHERE kind = 'computer' AND computer_id = ?1 AND principal_id = ''`,
    )
    .bind(computerId)
    .run();
}

export async function aggregateClientState(db, clientId, nowSeconds = Math.floor(Date.now() / 1000)) {
  const [bindings, deliveryResult] = await db.batch([
    db
      .prepare(
        `SELECT b.computer_id AS id,
                COALESCE(NULLIF(s.host_name, ''), 'Mac ' || substr(b.computer_id, 1, 6)) AS name,
                COALESCE(s.running_terminal_count, 0) AS reportedCount,
                COALESCE(s.agents_running, 0) AS agentsRunning,
                COALESCE(s.agents_waiting, 0) AS agentsWaiting,
                COALESCE(s.agents_done, 0) AS agentsDone,
                COALESCE(s.online, 0) AS online,
                COALESCE(s.updated_at, 0) AS updatedAt
           FROM client_computers b
           LEFT JOIN computer_state s ON s.computer_id = b.computer_id
          WHERE b.client_id = ?1
          ORDER BY b.computer_id`,
      )
      .bind(clientId),
    db
      .prepare(`SELECT sequence FROM client_delivery_state WHERE client_id = ?1`)
      .bind(clientId),
  ]);
  const delivery = deliveryResult.results?.[0];

  const computers = bindings.results.map((row) => {
    const online = Number(row.online) === 1;
    return {
      id: row.id,
      name: row.name,
      runningTTYCount: online ? Number(row.reportedCount) : 0,
      agents: {
        running: online ? Number(row.agentsRunning) : 0,
        waiting: online ? Number(row.agentsWaiting) : 0,
        done: online ? Number(row.agentsDone) : 0,
      },
      online,
      updatedAt: isoDate(Number(row.updatedAt)),
    };
  });
  const newestUpdate = bindings.results.reduce(
    (latest, row) => Math.max(latest, Number(row.updatedAt)),
    0,
  );
  return {
    version: SNAPSHOT_VERSION,
    totalRunning: computers.reduce((sum, computer) => sum + computer.runningTTYCount, 0),
    agentsRunning: computers.reduce((sum, computer) => sum + computer.agents.running, 0),
    agentsWaiting: computers.reduce((sum, computer) => sum + computer.agents.waiting, 0),
    agentsDone: computers.reduce((sum, computer) => sum + computer.agents.done, 0),
    computers,
    updatedAt: isoDate(newestUpdate || nowSeconds),
    sequence: Number(delivery?.sequence ?? 0),
    stale: false,
  };
}

function isoDate(seconds) {
  const safeSeconds = Number.isFinite(seconds) && seconds >= 0 ? Math.floor(seconds) : 0;
  return new Date(safeSeconds * 1000).toISOString().replace(".000Z", "Z");
}

export async function writeDirectoryProjection(
  env,
  computerId,
  {
    online,
    runningTerminalCount,
    agents = { running: 0, waiting: 0, done: 0 },
    hostName = undefined,
  },
) {
  const db = env.DB;
  const now = Math.floor(Date.now() / 1000);
  const validCount = (value) =>
    Number.isSafeInteger(value) && value >= 0 && value <= 255;
  if (
    typeof online !== "boolean" ||
    !validCount(runningTerminalCount) ||
    !agents ||
    typeof agents !== "object" ||
    !validCount(agents.running) ||
    !validCount(agents.waiting) ||
    !validCount(agents.done)
  ) {
    throw new TypeError("invalid terminal directory projection");
  }

  // Multiple socket callbacks can finish D1 work out of order. Revision-based
  // optimistic retries keep the Durable Object's latest projection intact.
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const current = await db
      .prepare(
        `SELECT running_terminal_count AS runningTerminalCount,
                agents_running AS agentsRunning,
                agents_waiting AS agentsWaiting,
                agents_done AS agentsDone,
                host_name AS hostName, online, revision
           FROM computer_state
          WHERE computer_id = ?1`,
      )
      .bind(computerId)
      .first();
    if (!current) return false;
    const nextCount = online ? runningTerminalCount : 0;
    const nextAgents = online ? agents : { running: 0, waiting: 0, done: 0 };
    const nextHostName = hostName ?? current.hostName;
    const nextOnline = online ? 1 : 0;
    const changed =
      nextCount !== Number(current.runningTerminalCount) ||
      nextAgents.running !== Number(current.agentsRunning) ||
      nextAgents.waiting !== Number(current.agentsWaiting) ||
      nextAgents.done !== Number(current.agentsDone) ||
      nextHostName !== current.hostName ||
      nextOnline !== Number(current.online);

    if (changed) {
      const mutationId = randomId();
      const results = await db.batch([
        db.prepare(
          `UPDATE computer_state
              SET running_terminal_count = ?2,
                  agents_running = ?8,
                  agents_waiting = ?9,
                  agents_done = ?10,
                  host_name = ?3,
                  online = ?4,
                  revision = revision + 1,
                  mutation_id = ?7,
                  updated_at = ?5
            WHERE computer_id = ?1
              AND revision = ?6`,
        ).bind(
          computerId,
          nextCount,
          nextHostName,
          nextOnline,
          now,
          Number(current.revision),
          mutationId,
          nextAgents.running,
          nextAgents.waiting,
          nextAgents.done,
        ),
        db.prepare(
          `UPDATE client_delivery_state
              SET sequence = sequence + 1,
                  last_fingerprint = NULL
            WHERE client_id IN (
                    SELECT client_id FROM client_computers WHERE computer_id = ?1
                  )
              AND EXISTS (
                    SELECT 1 FROM computer_state
                     WHERE computer_id = ?1 AND mutation_id = ?2
                  )`,
        ).bind(computerId, mutationId),
        db.prepare(
          `SELECT client_id AS clientId
             FROM client_computers
            WHERE computer_id = ?1
              AND EXISTS (
                    SELECT 1 FROM computer_state
                     WHERE computer_id = ?1 AND mutation_id = ?2
                  )`,
        ).bind(computerId, mutationId),
      ]);
      if (Number(results[0].meta?.changes ?? 0) === 0) continue;
      const clientIds = (results[2].results ?? []).map((row) => row.clientId);
      await notifyPushCoordinator(env, clientIds);
      return true;
    }

    return false;
  }
  throw new Error("computer state update contention");
}
