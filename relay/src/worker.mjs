import { handleApi } from "./api.mjs";
import {
  ORPHAN_CLIENT_RETENTION_SECONDS,
  ORPHAN_COMPUTER_RETENTION_SECONDS,
  apiError,
  authorizeRelay,
  clientAddress,
  deliverClientRelayRevocation,
  deliverComputerRelayRevocation,
  enforceRateLimit,
  failureResponse,
  isId,
  notifyPushCoordinator,
  rateLimitKey,
  touchClient,
} from "./core.mjs";
import { PushCoordinator } from "./push-coordinator.mjs";
import { RelayChannel } from "./relay-channel.mjs";
import {
  handleDesktopDownload,
  handlePairedDownload,
  handleWebsiteAsset,
} from "./site.mjs";

export { PushCoordinator, RelayChannel };

const RELAY_PATH = /^\/v2\/relay\/([0-9a-f]{32})$/;
const RELAY_HTTP_PATH = /^\/v2\/relay\/([0-9a-f]{32})\/http$/;
const HTTP_SESSION_TOKEN = /^[0-9a-f]{32}$/;
const HTTP_POLL_AFTER = /^(0|[1-9]\d{0,15})$/;
const UINT32_MAX = 4_294_967_295;

function workerVersionId(env) {
  const value = env?.WORKER_VERSION?.id;
  return typeof value === "string" && value.trim() !== ""
    ? value.trim()
    : "unknown";
}

function parseRelayChannel(url, extraKeys = []) {
  const allowed = new Set(["channel", "sid", ...extraKeys]);
  for (const key of url.searchParams.keys()) {
    if (!allowed.has(key)) return null;
  }

  const channel = url.searchParams.get("channel");
  const sid = url.searchParams.get("sid");
  if (channel === "control" && sid === null) return "control";
  if (channel !== "session" || sid === null || !/^(0|[1-9]\d{0,9})$/.test(sid)) {
    return null;
  }
  const value = Number(sid);
  if (!Number.isSafeInteger(value) || value > UINT32_MAX) return null;
  return `session:${value}`;
}

function trustedRelayRequest(request, identity, computerId, channel) {
  const headers = new Headers(request.headers);
  headers.set("x-pedals-role", identity.role);
  headers.set("x-pedals-principal-id", identity.principalId);
  headers.set("x-pedals-computer-id", computerId);
  headers.set("x-pedals-channel", channel);
  // Upgrades must never smuggle HTTP-transport routing into the actor.
  headers.delete("x-pedals-http-op");
  headers.delete("x-pedals-poll-session");
  headers.delete("x-pedals-poll-after");
  return new Request(request, { headers });
}

async function handleRelayUpgrade(request, env, url) {
  const match = RELAY_PATH.exec(url.pathname);
  const channel = parseRelayChannel(url);
  if (!match || !channel) return new Response(null, { status: 400 });
  const computerId = match[1];
  const identity = await authorizeRelay(request, env.DB, computerId);
  if (!identity) return apiError(401, "unauthorized", "relay access denied");
  const limiterKey = await rateLimitKey(
    "relay-upgrade",
    identity.role,
    identity.principalId,
    clientAddress(request),
  );
  await enforceRateLimit(env, "RELAY_UPGRADE_LIMITER", limiterKey, {
    code: "relay_upgrade_rate_limited",
    message: "too many relay connection attempts",
  });
  if (identity.role === "client") await touchClient(env.DB, identity.principalId);

  return env.RELAY_CHANNELS.getByName(computerId).fetch(
    trustedRelayRequest(request, identity, computerId, channel),
  );
}

// HTTP long-poll relay transport for clients that cannot hold a WebSocket
// (watchOS over the Bluetooth companion proxy). GET = poll, POST = send.
async function handleRelayHttp(request, env, url) {
  const match = RELAY_HTTP_PATH.exec(url.pathname);
  const isPoll = request.method === "GET";
  const channel = parseRelayChannel(url, isPoll ? ["session", "after"] : []);
  if (!match || !channel) return new Response(null, { status: 400 });
  const computerId = match[1];

  let token = null;
  let after = null;
  if (isPoll) {
    token = url.searchParams.get("session");
    after = url.searchParams.get("after");
    if (token === null || !HTTP_SESSION_TOKEN.test(token)) {
      return new Response(null, { status: 400 });
    }
    if (after !== null && !HTTP_POLL_AFTER.test(after)) {
      return new Response(null, { status: 400 });
    }
  }

  const identity = await authorizeRelay(request, env.DB, computerId);
  if (!identity) return apiError(401, "unauthorized", "relay access denied");
  if (identity.role !== "client") {
    return apiError(403, "forbidden", "hosts must use the WebSocket relay");
  }
  // A session-opening poll is the moral equivalent of a socket upgrade;
  // continuation polls and sends ride the global request limiter only.
  if (isPoll && after === null) {
    const limiterKey = await rateLimitKey(
      "relay-upgrade",
      identity.role,
      identity.principalId,
      clientAddress(request),
    );
    await enforceRateLimit(env, "RELAY_UPGRADE_LIMITER", limiterKey, {
      code: "relay_upgrade_rate_limited",
      message: "too many relay connection attempts",
    });
    await touchClient(env.DB, identity.principalId);
  }

  const headers = new Headers(request.headers);
  headers.set("x-pedals-role", identity.role);
  headers.set("x-pedals-principal-id", identity.principalId);
  headers.set("x-pedals-computer-id", computerId);
  headers.set("x-pedals-channel", channel);
  headers.set("x-pedals-http-op", isPoll ? "poll" : "send");
  if (isPoll) {
    headers.set("x-pedals-poll-session", token);
    if (after !== null) headers.set("x-pedals-poll-after", after);
  }
  return env.RELAY_CHANNELS.getByName(computerId).fetch(
    new Request(request, { headers }),
  );
}

async function reconcilePendingPushes(env) {
  const now = Math.floor(Date.now() / 1000);
  const savedCursor = await env.DB
    .prepare(`SELECT value FROM service_runtime_state WHERE key = 'push_reconcile_cursor'`)
    .first("value");
  const cursor = isId(savedCursor) ? savedCursor : "";
  const pending = await env.DB
    .prepare(
      `SELECT p.client_id AS clientId
         FROM push_endpoints p
         JOIN client_delivery_state d ON d.client_id = p.client_id
         JOIN clients c ON c.id = p.client_id
        WHERE p.invalidated_at IS NULL
          AND p.last_sequence < d.sequence
          AND (p.retry_not_before IS NULL OR p.retry_not_before <= ?1)
          AND (d.retry_not_before IS NULL OR d.retry_not_before <= ?1)
          AND c.revoked_at IS NULL
        GROUP BY p.client_id
        ORDER BY CASE WHEN p.client_id > ?2 THEN 0 ELSE 1 END,
                 p.client_id
        LIMIT 25`,
    )
    .bind(now, cursor)
    .all();
  const clientIds = pending.results.map((row) => row.clientId).filter(isId);
  if (clientIds.length > 0) {
    await env.DB
      .prepare(
        `INSERT INTO service_runtime_state (key, value, updated_at)
         VALUES ('push_reconcile_cursor', ?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value,
                                            updated_at = excluded.updated_at`,
      )
      .bind(clientIds.at(-1), now)
      .run();
  }
  await notifyPushCoordinator(
    env,
    clientIds,
  );
}

async function expireResetTombstones(env) {
  const cutoff = Math.floor(Date.now() / 1000) - 7 * 24 * 60 * 60;
  await env.DB
    .prepare(`DELETE FROM computer_reset_tombstones WHERE deleted_at < ?1`)
    .bind(cutoff)
    .run();
}

async function collectOrphans(env) {
  const now = Math.floor(Date.now() / 1000);
  const clientCutoff = now - ORPHAN_CLIENT_RETENTION_SECONDS;
  const computerCutoff = now - ORPHAN_COMPUTER_RETENTION_SECONDS;
  await env.DB.batch([
    env.DB
      .prepare(`DELETE FROM pairing_sessions WHERE expires_at <= ?1`)
      .bind(now),
    env.DB
      .prepare(`DELETE FROM reverse_pairing_claims WHERE expires_at <= ?1`)
      .bind(now),
    env.DB
      .prepare(
        `DELETE FROM clients
          WHERE id IN (
            SELECT c.id
              FROM clients c
             WHERE c.created_at < ?1
               AND NOT EXISTS (
                     SELECT 1 FROM client_computers b WHERE b.client_id = c.id
                   )
             ORDER BY c.created_at, c.id
             LIMIT 100
          )`,
      )
      .bind(clientCutoff),
    env.DB
      .prepare(
        `DELETE FROM computers
          WHERE id IN (
            SELECT c.id
              FROM computers c
              JOIN computer_state s ON s.computer_id = c.id
             WHERE c.created_at < ?1
               AND s.revision = 0
               AND s.online = 0
               AND s.host_name IS NULL
               AND NOT EXISTS (
                     SELECT 1 FROM client_computers b WHERE b.computer_id = c.id
                   )
             ORDER BY c.created_at, c.id
             LIMIT 100
          )`,
      )
      .bind(computerCutoff),
  ]);
}

async function drainRelayRevocations(env) {
  const now = Math.floor(Date.now() / 1000);
  const due = await env.DB
    .prepare(
      `SELECT id AS revocationId,
              kind,
              computer_id AS computerId,
              principal_id AS principalId,
              attempt_count AS attemptCount
         FROM relay_revocation_outbox
        WHERE next_attempt_at <= ?1
        ORDER BY next_attempt_at, created_at
        LIMIT 25`,
    )
    .bind(now)
    .all();

  for (const row of due.results) {
    const validComputer = isId(row.computerId);
    const validRevocation = isId(row.revocationId);
    const validTarget =
      (row.kind === "computer" && row.principalId === "") ||
      (row.kind === "client" && isId(row.principalId));
    if (!validComputer || !validRevocation || !validTarget) continue;
    try {
      if (row.kind === "computer") {
        await deliverComputerRelayRevocation(env, row.computerId);
      } else {
        await deliverClientRelayRevocation(
          env,
          row.computerId,
          row.principalId,
          row.revocationId,
        );
      }
    } catch (error) {
      const attempts = Math.max(0, Number(row.attemptCount) || 0) + 1;
      const delay = Math.min(60 * 60, 30 * 2 ** Math.min(attempts - 1, 7));
      const reason = String(error instanceof Error ? error.message : error).slice(0, 256);
      await env.DB
        .prepare(
          `UPDATE relay_revocation_outbox
              SET attempt_count = ?5,
                  next_attempt_at = ?6,
                  last_error = ?7
            WHERE id = ?1 AND kind = ?2 AND computer_id = ?3 AND principal_id = ?4`,
        )
        .bind(
          row.revocationId,
          row.kind,
          row.computerId,
          row.principalId,
          attempts,
          now + delay,
          reason,
        )
        .run();
    }
  }
}

const worker = {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      const upgrading =
        request.method === "GET" &&
        request.headers.get("upgrade")?.toLowerCase() === "websocket";

      if (url.pathname.startsWith("/v2/")) {
        await enforceRateLimit(env, "REQUEST_LIMITER", clientAddress(request), {
          code: "request_rate_limited",
          message: "too many service requests from this address",
        });
      }

      if (upgrading) return await handleRelayUpgrade(request, env, url);

      if (
        RELAY_HTTP_PATH.test(url.pathname) &&
        (request.method === "GET" || request.method === "POST")
      ) {
        return await handleRelayHttp(request, env, url);
      }

      if (
        (request.method === "GET" || request.method === "HEAD") &&
        url.pathname === "/healthz"
      ) {
        return new Response(request.method === "HEAD" ? null : "ok", {
          status: 200,
          headers: {
            "cache-control": "no-store",
            "content-type": "text/plain; charset=utf-8",
            "x-pedals-worker-version": workerVersionId(env),
          },
        });
      }

      const paired = /^\/download\/(\d{8})\/macos\.zip$/.exec(url.pathname);
      if (paired) {
        const response = await handlePairedDownload(request, env, paired[1]);
        if (response) return response;
      }
      const download = handleDesktopDownload(request, env, url);
      if (download) return download;

      if (url.pathname.startsWith("/v2/")) {
        const response = await handleApi(request, env, ctx, url);
        if (response) return response;
      }
      if (request.method === "GET" || request.method === "HEAD") {
        const asset = await handleWebsiteAsset(request, env);
        if (asset) return asset;
      }
      return apiError(404, "not_found", "route not found");
    } catch (error) {
      return failureResponse(error);
    }
  },

  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(
      Promise.all([
        reconcilePendingPushes(env).catch((error) => {
          console.error(
            "push reconciliation failed",
            error instanceof Error ? error.message : error,
          );
        }),
        expireResetTombstones(env).catch((error) => {
          console.error(
            "reset tombstone cleanup failed",
            error instanceof Error ? error.message : error,
          );
        }),
        collectOrphans(env).catch((error) => {
          console.error(
            "orphan cleanup failed",
            error instanceof Error ? error.message : error,
          );
        }),
        drainRelayRevocations(env).catch((error) => {
          console.error(
            "relay revocation drain failed",
            error instanceof Error ? error.message : error,
          );
        }),
      ]),
    );
  },
};

export default worker;
export {
  collectOrphans,
  drainRelayRevocations,
  expireResetTombstones,
  reconcilePendingPushes,
};
