import { env, exports } from "cloudflare:workers";
import {
  abortAllDurableObjects,
  applyD1Migrations,
  evictDurableObject,
  runDurableObjectAlarm,
  runInDurableObject,
} from "cloudflare:test";
import { afterEach, beforeAll, describe, expect, test, vi } from "vitest";
import { handleApi } from "../src/api.mjs";
import {
  collectOrphans,
  drainRelayRevocations,
  reconcilePendingPushes,
} from "../src/worker.mjs";
import {
  MAX_BINDINGS_PER_CLIENT,
  MAX_CLIENTS,
  MAX_COMPUTERS,
  ORPHAN_CLIENT_RETENTION_SECONDS,
  ORPHAN_COMPUTER_RETENTION_SECONDS,
  deliverClientRelayRevocation,
  enforceRateLimit,
} from "../src/core.mjs";
import { retryAtFromHeader } from "../src/push-coordinator.mjs";
import {
  CLIENT_SOURCE_ENVELOPE_BYTES,
  CLIENT_SOURCE_ENVELOPE_VERSION,
  CLIENT_SOURCE_PRINCIPAL_BYTES,
  HOST_DIRECTORY_LEASE_MS,
  MAX_BINARY_BYTES,
  MAX_CLIENT_ACTIVE_CHANNELS,
} from "../src/relay-channel.mjs";

function bytes(length, seed = 0x5a) {
  const value = new Uint8Array(length);
  for (let i = 0; i < value.length; i += 1) value[i] = (seed + i * 31) & 0xff;
  return value;
}

function asBytes(value) {
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  throw new Error(`expected binary WebSocket message, got ${typeof value}`);
}

function decodeClientSourceEnvelope(value) {
  const message = asBytes(value);
  expect(message.byteLength).toBeGreaterThan(CLIENT_SOURCE_ENVELOPE_BYTES);
  expect(message[0]).toBe(CLIENT_SOURCE_ENVELOPE_VERSION);
  const principalBytes = message.subarray(1, 1 + CLIENT_SOURCE_PRINCIPAL_BYTES);
  const principalId = new TextDecoder().decode(principalBytes);
  expect(principalId).toMatch(/^[0-9a-f]{32}$/);
  return {
    principalId,
    wire: message.subarray(CLIENT_SOURCE_ENVELOPE_BYTES),
  };
}

function deferredQueue() {
  const queued = [];
  const waiters = [];
  return {
    push(value) {
      const waiter = waiters.shift();
      if (waiter) waiter.resolve(value);
      else queued.push(value);
    },
    next(timeoutMs = 2_000) {
      if (queued.length) return Promise.resolve(queued.shift());
      return new Promise((resolve, reject) => {
        const waiter = { resolve: null };
        const timer = setTimeout(() => {
          const index = waiters.indexOf(waiter);
          if (index !== -1) waiters.splice(index, 1);
          reject(new Error("timed out waiting for WebSocket event"));
        }, timeoutMs);
        waiter.resolve = (value) => {
          clearTimeout(timer);
          resolve(value);
        };
        waiters.push(waiter);
      });
    },
  };
}

function observe(ws) {
  const binary = deferredQueue();
  const text = deferredQueue();
  const close = deferredQueue();
  ws.binaryType = "arraybuffer";
  ws.addEventListener("message", (event) => {
    if (typeof event.data === "string") text.push(event.data);
    else binary.push(event.data);
  });
  ws.addEventListener("close", (event) => {
    close.push({ code: event.code, reason: event.reason });
  });
  ws.accept();
  return {
    ws,
    nextBinary: (timeout) => binary.next(timeout),
    nextText: (timeout) => text.next(timeout),
    nextClose: (timeout) => close.next(timeout),
    async nextDirectory(timeout) {
      const value = JSON.parse(await text.next(timeout));
      expect(value.type).toBe("terminal-directory");
      return value;
    },
    async nextChannelState(timeout) {
      const value = JSON.parse(await text.next(timeout));
      expect(value.type).toBe("channel-state");
      return value;
    },
  };
}

function hostSnapshot(hostName, sessions) {
  return JSON.stringify({ type: "host-snapshot", hostName, sessions });
}

function runningSessions(count, start = 1) {
  return Array.from({ length: count }, (_, index) => ({
    id: start + index,
    alive: true,
  }));
}

async function api(path, { method = "GET", token, body, rawBody, headers = {} } = {}) {
  const requestHeaders = new Headers(headers);
  if (token) requestHeaders.set("authorization", `Bearer ${token}`);
  let requestBody = rawBody;
  if (body !== undefined) {
    requestHeaders.set("content-type", "application/json");
    requestBody = JSON.stringify(body);
  }
  return exports.default.fetch(
    new Request(`https://relay.test${path}`, {
      method,
      headers: requestHeaders,
      body: requestBody,
    }),
  );
}

async function apiJson(path, options) {
  const response = await api(path, options);
  return { response, value: await response.json() };
}

async function createComputer() {
  const { response, value } = await apiJson("/v2/computers", { method: "POST" });
  expect(response.status).toBe(201);
  return value;
}

async function createClient() {
  const { response, value } = await apiJson("/v2/clients", { method: "POST" });
  expect(response.status).toBe(201);
  return value;
}

async function createInvite(computer) {
  const { response, value } = await apiJson(
    `/v2/computers/${computer.computerId}/pairing-sessions`,
    {
      method: "POST",
      token: computer.hostToken,
      body: { hostPublicKey: "A".repeat(43) },
    },
  );
  expect(response.status).toBe(201);
  return value;
}

async function bind(client, computer, invite = undefined) {
  const grant = invite ?? (await createInvite(computer));
  const claim = await api(`/v2/clients/me/pairing-sessions/claim`, {
    method: "POST",
    token: client.clientToken,
    body: { code: grant.code, clientPublicKey: "B".repeat(43) },
  });
  if (claim.status < 200 || claim.status >= 300) return claim;
  return api(
    `/v2/computers/${computer.computerId}/pairing-sessions/${grant.sessionId}/complete`,
    {
      method: "POST",
      token: computer.hostToken,
      body: { encryptedSecret: "C".repeat(80) },
    },
  );
}

async function connect(computerId, token, channel = "control", sid = undefined) {
  const query = new URLSearchParams({ channel });
  if (sid !== undefined) query.set("sid", String(sid));
  const response = await exports.default.fetch(
    new Request(`https://relay.test/v2/relay/${computerId}?${query}`, {
      headers: {
        upgrade: "websocket",
        authorization: `Bearer ${token}`,
      },
    }),
  );
  if (response.status !== 101) return { response, peer: null };
  return { response, peer: observe(response.webSocket) };
}

async function state(client) {
  const response = await api("/v2/clients/me/state", { token: client.statusToken });
  expect(response.status).toBe(200);
  return response.json();
}

async function waitFor(check, timeoutMs = 2_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = await check();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("timed out waiting for condition");
}

async function expectNoEvent(next, timeoutMs = 150) {
  await expect(next(timeoutMs)).rejects.toThrow("timed out");
}

/// The coordinator's coalescing alarm (now + 150 ms) also fires for real in
/// workerd, so "wait until runDurableObjectAlarm returns true" races the
/// runtime: the real firing consumes the work and deletes the alarm, and the
/// manual runner then never sees one. Drain by processing whatever alarm is
/// scheduled AND waiting for the queue to empty, whichever way the work got
/// done.
async function drainCoordinator(coordinator) {
  await waitFor(async () => {
    try {
      if (await runDurableObjectAlarm(coordinator)) return null; // ran one round; re-check
    } catch {
      return null; // collided with the real alarm invocation; re-check
    }
    const [pending, inflight] = await runInDurableObject(
      coordinator,
      (_instance, durableState) =>
        Promise.all([
          durableState.storage.get("pendingClientIds"),
          durableState.storage.get("inflightClientIds"),
        ]),
    );
    return pending === undefined && inflight === undefined ? true : null;
  });
}

function closeAll(...peers) {
  for (const peer of peers) {
    try {
      if (peer?.ws.readyState === 1) peer.ws.close(1000, "test complete");
    } catch {
      // A replacement may already have closed it.
    }
  }
}

beforeAll(async () => {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});

afterEach(async () => {
  await abortAllDurableObjects();
});

describe("Pedals v2 Worker API", () => {
  test("health works and protocol v1 is absent", async () => {
    const get = await exports.default.fetch("https://relay.test/healthz");
    expect(get.status).toBe(200);
    expect(await get.text()).toBe("ok");
    expect(get.headers.get("cache-control")).toBe("no-store");
    const versionId = get.headers.get("x-pedals-worker-version");
    expect(versionId).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );

    const head = await exports.default.fetch("https://relay.test/healthz", {
      method: "HEAD",
    });
    expect(head.status).toBe(200);
    expect(await head.text()).toBe("");
    expect(head.headers.get("cache-control")).toBe("no-store");
    expect(head.headers.get("x-pedals-worker-version")).toBe(versionId);

    const old = await exports.default.fetch("https://relay.test/v1/room/deadbeef");
    expect(old.status).toBe(404);
  });

  test("native rate limiting fails closed and returns an explicit 429", async () => {
    await expect(
      enforceRateLimit({}, "MISSING", "test-key"),
    ).rejects.toMatchObject({
      status: 503,
      code: "rate_limiter_unavailable",
      headers: { "retry-after": "60" },
    });

    const limited = {
      TEST_LIMITER: { limit: async () => ({ success: false }) },
    };
    await expect(
      enforceRateLimit(limited, "TEST_LIMITER", "test-key", {
        code: "test_rate_limited",
        message: "test limit reached",
      }),
    ).rejects.toMatchObject({
      status: 429,
      code: "test_rate_limited",
      headers: { "retry-after": "60" },
    });
  });

  test("server creates opaque computer and client credentials", async () => {
    const computer = await createComputer();
    expect(computer.computerId).toMatch(/^[0-9a-f]{32}$/);
    expect(computer.hostToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const client = await createClient();
    expect(client.clientId).toMatch(/^[0-9a-f]{32}$/);
    expect(client.clientToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(client.statusToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(client.statusToken).not.toBe(client.clientToken);

    const stored = await env.DB
      .prepare(`SELECT host_token_hash AS hash FROM computers WHERE id = ?1`)
      .bind(computer.computerId)
      .first();
    expect(stored.hash).toMatch(/^[0-9a-f]{64}$/);
    expect(stored.hash).not.toBe(computer.hostToken);
    const storedClient = await env.DB
      .prepare(
        `SELECT auth_token_hash AS authHash, status_token_hash AS statusHash
           FROM clients WHERE id = ?1`,
      )
      .bind(client.clientId)
      .first();
    expect(storedClient.authHash).toMatch(/^[0-9a-f]{64}$/);
    expect(storedClient.statusHash).toMatch(/^[0-9a-f]{64}$/);
    expect(storedClient.authHash).not.toBe(storedClient.statusHash);
  });

  test("global computer capacity is atomic under concurrent registration", async () => {
    const current = Number(
      await env.DB.prepare(`SELECT COUNT(*) AS count FROM computers`).first("count"),
    );
    const fillerCount = MAX_COMPUTERS - current - 1;
    expect(fillerCount).toBeGreaterThan(0);
    try {
      await env.DB
        .prepare(
          `WITH RECURSIVE seq(i) AS (
             SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < ?1
           )
           INSERT INTO computers (id, host_token_hash, created_at)
           SELECT printf('e1%030x', i), printf('a1%062x', i), -100 FROM seq`,
        )
        .bind(fillerCount)
        .run();

      const attempts = await Promise.all([
        api("/v2/computers", { method: "POST" }),
        api("/v2/computers", { method: "POST" }),
      ]);
      expect(attempts.map((response) => response.status).sort()).toEqual([201, 503]);
      const rejected = attempts.find((response) => response.status === 503);
      expect((await rejected.json()).error.code).toBe("computer_capacity_exhausted");
      for (const response of attempts.filter((value) => value.status === 201)) {
        const created = await response.json();
        await env.DB.prepare(`DELETE FROM computers WHERE id = ?1`).bind(created.computerId).run();
      }
    } finally {
      await env.DB.prepare(`DELETE FROM computers WHERE created_at = -100`).run();
    }
  });

  test("global client capacity is atomic under concurrent registration", async () => {
    const current = Number(
      await env.DB.prepare(`SELECT COUNT(*) AS count FROM clients`).first("count"),
    );
    const fillerCount = MAX_CLIENTS - current - 1;
    expect(fillerCount).toBeGreaterThan(0);
    try {
      await env.DB
        .prepare(
          `WITH RECURSIVE seq(i) AS (
             SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < ?1
           )
           INSERT INTO clients
             (id, auth_token_hash, status_token_hash, created_at, last_seen_at)
           SELECT printf('e2%030x', i), printf('b1%062x', i),
                  printf('b2%062x', i), -101, -101
             FROM seq`,
        )
        .bind(fillerCount)
        .run();

      const attempts = await Promise.all([
        api("/v2/clients", { method: "POST" }),
        api("/v2/clients", { method: "POST" }),
      ]);
      expect(attempts.map((response) => response.status).sort()).toEqual([201, 503]);
      const rejected = attempts.find((response) => response.status === 503);
      expect((await rejected.json()).error.code).toBe("client_capacity_exhausted");
      for (const response of attempts.filter((value) => value.status === 201)) {
        const created = await response.json();
        await env.DB.prepare(`DELETE FROM clients WHERE id = ?1`).bind(created.clientId).run();
      }
    } finally {
      await env.DB.prepare(`DELETE FROM clients WHERE created_at = -101`).run();
    }
  });

  test("JSON API enforces authorization, shape, and 16 KiB body cap", async () => {
    const computer = await createComputer();
    const unauthorized = await api(`/v2/computers/${computer.computerId}/pairing-sessions`, {
      method: "POST",
      body: { hostPublicKey: "A".repeat(43) },
    });
    expect(unauthorized.status).toBe(401);

    const malformed = await api("/v2/clients", { method: "POST", rawBody: "[1]" });
    expect(malformed.status).toBe(400);

    const oversized = await api("/v2/clients", {
      method: "POST",
      rawBody: "x".repeat(16 * 1024 + 1),
    });
    expect(oversized.status).toBe(413);

    const unknownField = await api("/v2/computers", {
      method: "POST",
      body: { legacyRoom: "not-supported" },
    });
    expect(unknownField.status).toBe(400);

    const client = await createClient();
    expect(
      (await api("/v2/clients/me/state", { token: client.clientToken })).status,
    ).toBe(401);
    expect(
      (await api("/v2/clients/me/pairing-sessions/claim", {
        method: "POST",
        token: client.statusToken,
        body: { code: "12345678", clientPublicKey: "B".repeat(43) },
      })).status,
    ).toBe(401);
    expect((await connect(computer.computerId, client.statusToken)).response.status).toBe(401);
  });

  test("a pairing code is single-use and binding is server-visible", async () => {
    const computer = await createComputer();
    const first = await createClient();
    const second = await createClient();
    const invite = await createInvite(computer);

    expect((await bind(first, computer, invite)).status).toBe(201);
    expect((await bind(first, computer, invite)).status).toBe(400);
    const replay = await bind(second, computer, invite);
    expect(replay.status).toBe(400);
    expect((await replay.json()).error.code).toBe("invalid_pairing_code");

    const snapshot = await state(first);
    expect(snapshot).toMatchObject({
      version: 2,
      totalRunning: 0,
      stale: false,
    });
    expect(snapshot.sequence).toBeGreaterThan(0);
    expect(snapshot.updatedAt).toMatch(/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
    expect(snapshot.computers).toEqual([
      {
        id: computer.computerId,
        name: `Mac ${computer.computerId.slice(0, 6)}`,
        runningTTYCount: 0,
        agents: { running: 0, waiting: 0, done: 0 },
        online: false,
        updatedAt: snapshot.updatedAt,
      },
    ]);

    const freshInvite = await createInvite(computer);
    expect((await bind(first, computer, freshInvite)).status).toBe(200);
    expect((await bind(second, computer, freshInvite)).status).toBe(400);
    expect(
      (await api("/v2/clients/me/bindings", {
        method: "PUT",
        token: first.clientToken,
        body: { computerIds: [] },
      })).status,
    ).toBe(200);
    expect((await bind(first, computer, freshInvite)).status).toBe(400);
  });

  test("opening and closing the pairing page revokes earlier codes", async () => {
    const computer = await createComputer();
    const client = await createClient();
    const first = await createInvite(computer);
    const second = await createInvite(computer);
    expect((await bind(client, computer, first)).status).toBe(400);
    expect(
      (await api(
        `/v2/computers/${computer.computerId}/pairing-sessions/${second.sessionId}`,
        { method: "DELETE", token: computer.hostToken },
      )).status,
    ).toBe(204);
    expect((await bind(client, computer, second)).status).toBe(400);
    expect(
      Number(
        await env.DB.prepare(
          `SELECT COUNT(*) AS count FROM pairing_sessions WHERE computer_id = ?1`,
        ).bind(computer.computerId).first("count"),
      ),
    ).toBe(0);
  });

  test("pairing sessions expose only public keys and encrypted envelopes", async () => {
    const computer = await createComputer();
    const client = await createClient();
    const pairing = await createInvite(computer);
    expect(pairing.code).toMatch(/^\d{8}$/);
    expect(pairing.expiresAt - Math.floor(Date.now() / 1000)).toBeGreaterThan(890);
    const claim = await apiJson("/v2/clients/me/pairing-sessions/claim", {
      method: "POST",
      token: client.clientToken,
      body: { code: pairing.code, clientPublicKey: "B".repeat(43) },
    });
    expect(claim.response.status).toBe(200);
    expect(claim.value).toMatchObject({
      sessionId: pairing.sessionId,
      computerId: computer.computerId,
      hostPublicKey: "A".repeat(43),
    });
    const status = await apiJson(
      `/v2/computers/${computer.computerId}/pairing-sessions/${pairing.sessionId}`,
      { token: computer.hostToken },
    );
    expect(status.value).toMatchObject({ status: "claimed", clientPublicKey: "B".repeat(43) });

    const completed = await api(
      `/v2/computers/${computer.computerId}/pairing-sessions/${pairing.sessionId}/complete`,
      {
        method: "POST",
        token: computer.hostToken,
        body: { encryptedSecret: "C".repeat(80) },
      },
    );
    expect(completed.status).toBe(201);
    const clientStatus = await apiJson(
      `/v2/clients/me/pairing-sessions/${pairing.sessionId}`,
      { token: client.clientToken },
    );
    expect(clientStatus.value).toMatchObject({
      status: "completed",
      computerId: computer.computerId,
      encryptedSecret: "C".repeat(80),
    });
    expect(
      (await api(`/v2/clients/me/pairing-sessions/${pairing.sessionId}`, {
        method: "DELETE",
        token: client.clientToken,
      })).status,
    ).toBe(204);
    expect(
      Number(
        await env.DB.prepare(
          `SELECT COUNT(*) AS count FROM pairing_sessions WHERE id = ?1`,
        ).bind(pairing.sessionId).first("count"),
      ),
    ).toBe(0);
  });

  test("binding capacity rejects without consuming the pairing session", async () => {
    const client = await createClient();
    const target = await createComputer();
    const invite = await createInvite(target);
    try {
      await env.DB
        .prepare(
          `WITH RECURSIVE seq(i) AS (
             SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < ?1
           )
           INSERT INTO computers (id, host_token_hash, created_at)
           SELECT printf('d1%030x', i), printf('d3%062x', i), -102 FROM seq`,
        )
        .bind(MAX_BINDINGS_PER_CLIENT)
        .run();
      await env.DB
        .prepare(
          `WITH RECURSIVE seq(i) AS (
             SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < ?2
           )
           INSERT INTO client_computers
             (client_id, computer_id, mutation_id, created_at)
           SELECT ?1, printf('d1%030x', i), printf('d2%030x', i), -102 FROM seq`,
        )
        .bind(client.clientId, MAX_BINDINGS_PER_CLIENT)
        .run();

      const limited = await bind(client, target, invite);
      expect(limited.status).toBe(429);
      expect((await limited.json()).error.code).toBe("binding_limit");
      expect(
        await env.DB
          .prepare(
            `SELECT claimed_by AS claimedBy
               FROM pairing_sessions
              WHERE computer_id = ?1`,
          )
          .bind(target.computerId)
          .first("claimedBy"),
      ).toBeNull();
      expect(
        Number(
          await env.DB
            .prepare(
              `SELECT COUNT(*) AS count
                 FROM client_computers
                WHERE client_id = ?1`,
            )
            .bind(client.clientId)
            .first("count"),
        ),
      ).toBe(MAX_BINDINGS_PER_CLIENT);
    } finally {
      await env.DB.prepare(`DELETE FROM computers WHERE created_at = -102`).run();
    }
  });

  test("binding reconcile is idempotent and revokes relay access", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const control = await connect(computer.computerId, client.clientToken);
    const session = await connect(computer.computerId, client.clientToken, "session", 7);
    expect(control.response.status).toBe(101);
    expect(session.response.status).toBe(101);

    const removed = await apiJson("/v2/clients/me/bindings", {
      method: "PUT",
      token: client.clientToken,
      body: { computerIds: [] },
    });
    expect(removed.response.status).toBe(200);
    expect(removed.value).toEqual({ computerIds: [] });
    expect((await control.peer.nextClose()).code).toBe(4003);
    expect((await session.peer.nextClose()).code).toBe(4003);
    expect(
      Number(
        await env.DB
          .prepare(
            `SELECT COUNT(*) AS count
               FROM relay_revocation_outbox
              WHERE kind = 'client' AND computer_id = ?1 AND principal_id = ?2`,
          )
          .bind(computer.computerId, client.clientId)
          .first("count"),
      ),
    ).toBe(0);
    const repeated = await apiJson("/v2/clients/me/bindings", {
      method: "PUT",
      token: client.clientToken,
      body: { computerIds: [] },
    });
    expect(repeated.response.status).toBe(200);
    expect(repeated.value).toEqual({ computerIds: [] });
    expect(
      Number(
        await env.DB
          .prepare(
            `SELECT COUNT(*) AS count
               FROM relay_revocation_outbox
              WHERE kind = 'client' AND computer_id = ?1 AND principal_id = ?2`,
          )
          .bind(computer.computerId, client.clientId)
          .first("count"),
      ),
    ).toBe(0);
    expect((await connect(computer.computerId, client.clientToken)).response.status).toBe(401);
  });

  test("binding reconcile never creates an edge and rejects invalid lists", async () => {
    const computer = await createComputer();
    const other = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);

    const declared = await apiJson("/v2/clients/me/bindings", {
      method: "PUT",
      token: client.clientToken,
      body: { computerIds: [computer.computerId, other.computerId] },
    });
    expect(declared.response.status).toBe(200);
    expect(declared.value).toEqual({ computerIds: [computer.computerId] });
    expect((await connect(other.computerId, client.clientToken)).response.status).toBe(401);
    expect((await connect(computer.computerId, client.clientToken)).response.status).toBe(101);

    for (const computerIds of [
      "not-a-list",
      [computer.computerId, computer.computerId],
      ["not-an-id"],
      Array.from({ length: 33 }, (_, index) =>
        index.toString(16).padStart(32, "0")),
    ]) {
      const rejected = await apiJson("/v2/clients/me/bindings", {
        method: "PUT",
        token: client.clientToken,
        body: { computerIds },
      });
      expect(rejected.response.status).toBe(400);
      expect(rejected.value.error.code).toBe("invalid_bindings");
    }
  });

  test("a delegated client receives exactly the source bindings", async () => {
    const firstComputer = await createComputer();
    const secondComputer = await createComputer();
    const staleComputer = await createComputer();
    const source = await createClient();
    const delegated = await createClient();
    expect((await bind(source, firstComputer)).status).toBe(201);
    expect((await bind(source, secondComputer)).status).toBe(201);
    expect((await bind(delegated, staleComputer)).status).toBe(201);

    const staleControl = await connect(staleComputer.computerId, delegated.clientToken);
    expect(staleControl.response.status).toBe(101);
    const synchronized = await apiJson("/v2/clients/me/delegated-bindings", {
      method: "PUT",
      token: source.clientToken,
      body: {
        clientId: delegated.clientId,
        clientToken: delegated.clientToken,
      },
    });
    expect(synchronized.response.status).toBe(200);
    expect(synchronized.value).toEqual({ bindingCount: 2 });
    expect((await staleControl.peer.nextClose()).code).toBe(4003);
    expect((await connect(staleComputer.computerId, delegated.clientToken)).response.status).toBe(401);
    const firstControl = await connect(firstComputer.computerId, delegated.clientToken);
    expect(firstControl.response.status).toBe(101);
    expect((await connect(secondComputer.computerId, delegated.clientToken)).response.status).toBe(101);

    const delegatedState = await state(delegated);
    expect(delegatedState.computers.map((computer) => computer.id)).toEqual([
      firstComputer.computerId,
      secondComputer.computerId,
    ].sort());
    expect(
      Number(
        await env.DB.prepare(
          `SELECT COUNT(*) AS count
             FROM relay_revocation_outbox
            WHERE kind = 'client' AND principal_id = ?1`,
        ).bind(delegated.clientId).first("count"),
      ),
    ).toBe(0);
    expect(
      await env.DB.prepare(
        `SELECT delegate_client_id AS delegateClientId
           FROM client_delegates
          WHERE parent_client_id = ?1 AND kind = 'watch-terminal'`,
      ).bind(source.clientId).first("delegateClientId"),
    ).toBe(delegated.clientId);

    expect((await api("/v2/clients/me/bindings", {
      method: "PUT",
      token: source.clientToken,
      body: { computerIds: [secondComputer.computerId] },
    })).status).toBe(200);
    expect((await firstControl.peer.nextClose()).code).toBe(4003);
    expect((await connect(firstComputer.computerId, source.clientToken)).response.status).toBe(401);
    expect((await connect(firstComputer.computerId, delegated.clientToken)).response.status).toBe(401);
    expect((await connect(secondComputer.computerId, delegated.clientToken)).response.status).toBe(101);
  });

  test("replacing a Watch delegate revokes the previous identity and sockets", async () => {
    const computer = await createComputer();
    const source = await createClient();
    const previous = await createClient();
    const replacement = await createClient();
    expect((await bind(source, computer)).status).toBe(201);
    expect((await api("/v2/clients/me/delegated-bindings", {
      method: "PUT",
      token: source.clientToken,
      body: { clientId: previous.clientId, clientToken: previous.clientToken },
    })).status).toBe(200);
    const previousControl = await connect(computer.computerId, previous.clientToken);
    expect(previousControl.response.status).toBe(101);

    const synchronized = await apiJson("/v2/clients/me/delegated-bindings", {
      method: "PUT",
      token: source.clientToken,
      body: { clientId: replacement.clientId, clientToken: replacement.clientToken },
    });
    expect(synchronized.response.status).toBe(200);
    expect(synchronized.value).toEqual({ bindingCount: 1 });
    expect((await previousControl.peer.nextClose()).code).toBe(4003);
    expect((await connect(computer.computerId, previous.clientToken)).response.status).toBe(401);
    expect((await connect(computer.computerId, replacement.clientToken)).response.status).toBe(101);
    expect(
      await env.DB.prepare(
        `SELECT revoked_at AS revokedAt FROM clients WHERE id = ?1`,
      ).bind(previous.clientId).first("revokedAt"),
    ).not.toBeNull();
    expect(
      await env.DB.prepare(
        `SELECT delegate_client_id AS delegateClientId
           FROM client_delegates
          WHERE parent_client_id = ?1`,
      ).bind(source.clientId).first("delegateClientId"),
    ).toBe(replacement.clientId);
  });

  test("delegated binding synchronization requires both client credentials", async () => {
    const source = await createClient();
    const delegated = await createClient();
    const unrelated = await createClient();

    expect((await api("/v2/clients/me/delegated-bindings", {
      method: "PUT",
      body: { clientId: delegated.clientId, clientToken: delegated.clientToken },
    })).status).toBe(401);
    const wrongToken = await apiJson("/v2/clients/me/delegated-bindings", {
      method: "PUT",
      token: source.clientToken,
      body: { clientId: delegated.clientId, clientToken: unrelated.clientToken },
    });
    expect(wrongToken.response.status).toBe(403);
    expect(wrongToken.value.error.code).toBe("invalid_delegate");
    expect((await api("/v2/clients/me/delegated-bindings", {
      method: "PUT",
      token: source.clientToken,
      body: { clientId: source.clientId, clientToken: source.clientToken },
    })).status).toBe(400);
    expect((await api("/v2/clients/me/delegated-bindings", {
      method: "PUT",
      token: source.clientToken,
      body: {
        clientId: delegated.clientId,
        clientToken: delegated.clientToken,
        computerSecret: "must-never-be-accepted",
      },
    })).status).toBe(400);

    expect((await api("/v2/clients/me/delegated-bindings", {
      method: "PUT",
      token: source.clientToken,
      body: { clientId: delegated.clientId, clientToken: delegated.clientToken },
    })).status).toBe(200);
    const otherSource = await createClient();
    expect((await api("/v2/clients/me/delegated-bindings", {
      method: "PUT",
      token: otherSource.clientToken,
      body: { clientId: delegated.clientId, clientToken: delegated.clientToken },
    })).status).toBe(403);
    expect((await api("/v2/clients/me/delegated-bindings", {
      method: "PUT",
      token: delegated.clientToken,
      body: { clientId: unrelated.clientId, clientToken: unrelated.clientToken },
    })).status).toBe(403);
  });

  test("client socket revocation survives a transient Durable Object failure", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const control = await connect(computer.computerId, client.clientToken);
    expect(control.response.status).toBe(101);

    const failingEnv = {
      DB: env.DB,
      PUSH_COORDINATOR: env.PUSH_COORDINATOR,
      TEST_BYPASS_RATE_LIMITS: "true",
      RELAY_CHANNELS: {
        getByName() {
          return {
            fetch: async () => new Response(null, { status: 503 }),
          };
        },
      },
    };
    const pending = [];
    const request = new Request(
      "https://relay.test/v2/clients/me/bindings",
      {
        method: "PUT",
        headers: {
          authorization: `Bearer ${client.clientToken}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({ computerIds: [] }),
      },
    );
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const removed = await handleApi(request, failingEnv, {
        waitUntil(promise) {
          pending.push(promise);
        },
      }, new URL(request.url));
      expect(removed.status).toBe(200);
      await Promise.all(pending);
      expect(errorSpy).toHaveBeenCalledWith(
        "client socket revocation failed",
        expect.stringContaining("503"),
      );
    } finally {
      errorSpy.mockRestore();
    }

    expect(
      Number(
        await env.DB
          .prepare(
            `SELECT COUNT(*) AS count
               FROM client_computers
              WHERE client_id = ?1 AND computer_id = ?2`,
          )
          .bind(client.clientId, computer.computerId)
          .first("count"),
      ),
    ).toBe(0);
    await expectNoEvent(control.peer.nextClose);

    await drainRelayRevocations(failingEnv);
    const deferred = await env.DB
      .prepare(
        `SELECT attempt_count AS attemptCount,
                next_attempt_at AS nextAttemptAt,
                last_error AS lastError
           FROM relay_revocation_outbox
          WHERE kind = 'client' AND computer_id = ?1 AND principal_id = ?2`,
      )
      .bind(computer.computerId, client.clientId)
      .first();
    expect(Number(deferred.attemptCount)).toBe(1);
    expect(Number(deferred.nextAttemptAt)).toBeGreaterThan(
      Math.floor(Date.now() / 1000),
    );
    expect(deferred.lastError).toContain("503");

    await env.DB
      .prepare(
        `UPDATE relay_revocation_outbox
            SET next_attempt_at = 0
          WHERE kind = 'client' AND computer_id = ?1 AND principal_id = ?2`,
      )
      .bind(computer.computerId, client.clientId)
      .run();
    await drainRelayRevocations(env);
    expect((await control.peer.nextClose()).code).toBe(4003);
    expect(
      Number(
        await env.DB
          .prepare(
            `SELECT COUNT(*) AS count
               FROM relay_revocation_outbox
              WHERE kind = 'client' AND computer_id = ?1 AND principal_id = ?2`,
          )
          .bind(computer.computerId, client.clientId)
          .first("count"),
      ),
    ).toBe(0);
    expect((await connect(computer.computerId, client.clientToken)).response.status).toBe(401);
  });

  test("binding creation clears a stale client revocation", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    await env.DB
      .prepare(
        `INSERT INTO relay_revocation_outbox
           (id, kind, computer_id, principal_id, created_at,
            attempt_count, next_attempt_at, last_error)
         VALUES (?1, 'client', ?2, ?3, 1, 1, 9999999999, 'stale')`,
      )
      .bind("f3".padEnd(32, "0"), computer.computerId, client.clientId)
      .run();

    const invite = await createInvite(computer);
    expect((await bind(client, computer, invite)).status).toBe(200);
    expect(
      Number(
        await env.DB
          .prepare(
            `SELECT COUNT(*) AS count
               FROM relay_revocation_outbox
              WHERE kind = 'client' AND computer_id = ?1 AND principal_id = ?2`,
          )
          .bind(computer.computerId, client.clientId)
          .first("count"),
      ),
    ).toBe(0);
  });

  test("client revocation acknowledgement preserves a newer generation", async () => {
    const revocationId = "f4".padEnd(32, "0");
    const replacementId = "f5".padEnd(32, "0");
    const computerId = "f6".padEnd(32, "0");
    const clientId = "f7".padEnd(32, "0");
    await env.DB
      .prepare(
        `INSERT INTO relay_revocation_outbox
           (id, kind, computer_id, principal_id, created_at,
            attempt_count, next_attempt_at, last_error)
         VALUES (?1, 'client', ?2, ?3, 1, 0, 0, NULL)`,
      )
      .bind(revocationId, computerId, clientId)
      .run();

    let acknowledge;
    let requestStarted;
    const started = new Promise((resolve) => {
      requestStarted = resolve;
    });
    const acknowledged = new Promise((resolve) => {
      acknowledge = resolve;
    });
    const delivery = deliverClientRelayRevocation(
      {
        DB: env.DB,
        RELAY_CHANNELS: {
          getByName() {
            return {
              async fetch() {
                requestStarted();
                await acknowledged;
                return new Response(null, { status: 204 });
              },
            };
          },
        },
      },
      computerId,
      clientId,
      revocationId,
    );
    await started;
    await env.DB
      .prepare(
        `UPDATE relay_revocation_outbox
            SET id = ?2, created_at = 2
          WHERE id = ?1`,
      )
      .bind(revocationId, replacementId)
      .run();
    acknowledge();
    await delivery;

    expect(
      await env.DB
        .prepare(
          `SELECT id FROM relay_revocation_outbox
            WHERE kind = 'client' AND computer_id = ?1 AND principal_id = ?2`,
        )
        .bind(computerId, clientId)
        .first("id"),
    ).toBe(replacementId);
    await env.DB
      .prepare(`DELETE FROM relay_revocation_outbox WHERE id = ?1`)
      .bind(replacementId)
      .run();
  });

  test("host reset deletes the computer and revokes every live socket", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const control = (await connect(computer.computerId, client.clientToken)).peer;
    const session = (await connect(computer.computerId, client.clientToken, "session", 9)).peer;
    try {
      expect(
        (await api(`/v2/computers/${computer.computerId}`, {
          method: "DELETE",
          token: client.clientToken,
        })).status,
      ).toBe(401);
      expect(
        (await api(`/v2/computers/${computer.computerId}`, {
          method: "DELETE",
          token: computer.hostToken,
        })).status,
      ).toBe(204);
      expect((await host.nextClose()).code).toBe(4004);
      expect((await control.nextClose()).code).toBe(4004);
      expect((await session.nextClose()).code).toBe(4004);
      expect(
        (await api(`/v2/computers/${computer.computerId}`, {
          method: "DELETE",
          token: computer.hostToken,
        })).status,
      ).toBe(204);
      expect(
        await env.DB
          .prepare(`SELECT COUNT(*) AS count FROM computers WHERE id = ?1`)
          .bind(computer.computerId)
          .first("count"),
      ).toBe(0);
      const snapshot = await state(client);
      expect(snapshot.computers).toEqual([]);
      expect(snapshot.sequence).toBeGreaterThan(1);
      expect((await connect(computer.computerId, computer.hostToken)).response.status).toBe(401);
    } finally {
      closeAll(host, control, session);
    }
  });

  test("computer socket revocation survives a transient Durable Object failure", async () => {
    const revocationId = "f1".padEnd(32, "0");
    const computerId = "f2".padEnd(32, "0");
    await env.DB
      .prepare(
        `INSERT INTO relay_revocation_outbox
           (id, kind, computer_id, principal_id, created_at,
            attempt_count, next_attempt_at, last_error)
         VALUES (?1, 'computer', ?2, '', 1, 0, 0, NULL)`,
      )
      .bind(revocationId, computerId)
      .run();

    const failingEnv = {
      DB: env.DB,
      RELAY_CHANNELS: {
        getByName() {
          return {
            fetch: async () => new Response(null, { status: 503 }),
          };
        },
      },
    };
    await drainRelayRevocations(failingEnv);
    const deferred = await env.DB
      .prepare(
        `SELECT attempt_count AS attemptCount,
                next_attempt_at AS nextAttemptAt,
                last_error AS lastError
           FROM relay_revocation_outbox
          WHERE id = ?1`,
      )
      .bind(revocationId)
      .first();
    expect(Number(deferred.attemptCount)).toBe(1);
    expect(Number(deferred.nextAttemptAt)).toBeGreaterThan(
      Math.floor(Date.now() / 1000),
    );
    expect(deferred.lastError).toContain("503");

    await env.DB
      .prepare(`UPDATE relay_revocation_outbox SET next_attempt_at = 0 WHERE id = ?1`)
      .bind(revocationId)
      .run();
    await drainRelayRevocations(env);
    expect(
      Number(
        await env.DB
          .prepare(`SELECT COUNT(*) AS count FROM relay_revocation_outbox WHERE id = ?1`)
          .bind(revocationId)
          .first("count"),
      ),
    ).toBe(0);
  });

  test("push endpoint surfaces are allow-listed and support lifecycle", async () => {
    const client = await createClient();
    const invalid = await api("/v2/clients/me/push-endpoints/arbitrary", {
      method: "PUT",
      token: client.statusToken,
      body: { token: "aa".repeat(32), environment: "sandbox" },
    });
    expect(invalid.status).toBe(400);
    expect(
      (await api("/v2/clients/me/push-endpoints/ios-widget", {
        method: "PUT",
        token: client.statusToken,
        body: {
          token: "ac".repeat(32),
          environment: "sandbox",
          activityId: "not-a-live-activity",
        },
      })).status,
    ).toBe(400);

    const registered = await api("/v2/clients/me/push-endpoints/ios-widget", {
      method: "PUT",
      token: client.statusToken,
      body: { token: "ab".repeat(32), environment: "sandbox" },
    });
    expect(registered.status).toBe(200);
    expect(await registered.json()).toEqual({
      surface: "ios-widget",
      activityId: null,
      registered: true,
    });

    const row = await env.DB
      .prepare(
        `SELECT surface, apns_environment AS environment
           FROM push_endpoints WHERE client_id = ?1`,
      )
      .bind(client.clientId)
      .first();
    expect(row).toEqual({ surface: "ios-widget", environment: "sandbox" });

    const replacement = await createClient();
    expect(
      (await api("/v2/clients/me/push-endpoints/ios-widget", {
        method: "PUT",
        token: replacement.statusToken,
        body: { token: "ab".repeat(32), environment: "production" },
      })).status,
    ).toBe(200);
    const transferred = await env.DB
      .prepare(`SELECT client_id AS clientId FROM push_endpoints WHERE token = ?1`)
      .bind("ab".repeat(32))
      .first();
    expect(transferred.clientId).toBe(replacement.clientId);

    expect(
      (await api("/v2/clients/me/push-endpoints/ios-widget", {
        method: "DELETE",
        token: client.statusToken,
      })).status,
    ).toBe(204);
    expect(
      await env.DB
        .prepare(`SELECT COUNT(*) AS count FROM push_endpoints WHERE client_id = ?1`)
        .bind(client.clientId)
        .first("count"),
    ).toBe(0);
    expect(
      (await api("/v2/clients/me/push-endpoints/ios-widget", {
        method: "DELETE",
        token: replacement.statusToken,
      })).status,
    ).toBe(204);

    expect(
      (await api("/v2/clients/me/push-endpoints/liveactivity-start", {
        method: "PUT",
        token: replacement.statusToken,
        body: { token: "12".repeat(32), environment: "sandbox" },
      })).status,
    ).toBe(200);
    await env.DB
      .prepare(
        `UPDATE push_endpoints SET last_total_running = 1
          WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
      )
      .bind(replacement.clientId)
      .run();

    for (const [token, activityId] of [
      ["cd".repeat(32), "activity-one"],
      ["ef".repeat(32), "activity-two"],
    ]) {
      expect(
        (await api("/v2/clients/me/push-endpoints/liveactivity-update", {
          method: "PUT",
          token: replacement.statusToken,
          body: { token, environment: "sandbox", activityId },
        })).status,
      ).toBe(200);
    }
    expect(
      (await api(
        "/v2/clients/me/push-endpoints/liveactivity-update?activityId=activity-one",
        { method: "DELETE", token: replacement.statusToken },
      )).status,
    ).toBe(204);
    const remainingActivity = await env.DB
      .prepare(
        `SELECT activity_key AS activityId
           FROM push_endpoints
          WHERE client_id = ?1 AND surface = 'liveactivity-update'`,
      )
      .bind(replacement.clientId)
      .first();
    expect(remainingActivity.activityId).toBe("activity-two");
    let startBaseline = await env.DB
      .prepare(
        `SELECT last_total_running AS lastTotal
           FROM push_endpoints
          WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
      )
      .bind(replacement.clientId)
      .first();
    expect(Number(startBaseline.lastTotal)).toBe(1);

    expect(
      (await api(
        "/v2/clients/me/push-endpoints/liveactivity-update?activityId=activity-two",
        { method: "DELETE", token: replacement.statusToken },
      )).status,
    ).toBe(204);
    startBaseline = await env.DB
      .prepare(
        `SELECT last_total_running AS lastTotal
           FROM push_endpoints
          WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
      )
      .bind(replacement.clientId)
      .first();
    expect(Number(startBaseline.lastTotal)).toBe(0);
  });

  test("push endpoint count is bounded in D1", async () => {
    const client = await createClient();
    // "fb…" tokens draw a 429 from the APNs mock, so the coordinator defers
    // the endpoints instead of ending zero-state activities and deleting
    // them — without this, a slow runner lets the 150 ms alarm free slots
    // between the eighth and ninth registration.
    for (let index = 0; index < 8; index += 1) {
      expect(
        (await api("/v2/clients/me/push-endpoints/liveactivity-update", {
          method: "PUT",
          token: client.statusToken,
          body: {
            token: ("fb0" + index.toString(16)).repeat(16),
            environment: "sandbox",
            activityId: `activity-${index}`,
          },
        })).status,
      ).toBe(200);
    }
    const limited = await api("/v2/clients/me/push-endpoints/liveactivity-update", {
      method: "PUT",
      token: client.statusToken,
      body: {
        token: "ff".repeat(32),
        environment: "sandbox",
        activityId: "activity-over-limit",
      },
    });
    expect(limited.status).toBe(429);
    expect((await limited.json()).error.code).toBe("endpoint_limit");

    await env.DB
      .prepare(
        `UPDATE push_endpoints
            SET invalidated_at = 1
          WHERE client_id = ?1 AND activity_key = 'activity-0'`,
      )
      .bind(client.clientId)
      .run();
    const replacement = await api(
      "/v2/clients/me/push-endpoints/liveactivity-update",
      {
        method: "PUT",
        token: client.statusToken,
        body: {
          token: "fe".repeat(32),
          environment: "sandbox",
          activityId: "activity-replacement",
        },
      },
    );
    expect(replacement.status).toBe(200);
    const retained = await env.DB
      .prepare(
        `SELECT COUNT(*) AS total,
                SUM(CASE WHEN invalidated_at IS NULL THEN 1 ELSE 0 END) AS active
           FROM push_endpoints
          WHERE client_id = ?1`,
      )
      .bind(client.clientId)
      .first();
    expect(Number(retained.total)).toBe(8);
    expect(Number(retained.active)).toBe(8);
  });

  test("ordinary positive state never consumes a push-to-start token", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const coordinator = env.PUSH_COORDINATOR.getByName(client.clientId);
    try {
      host.ws.send(
        hostSnapshot("Busy Mac", runningSessions(3)),
      );
      const positive = await waitFor(async () => {
        const snapshot = await state(client);
        return snapshot.totalRunning === 3 ? snapshot : null;
      });
      while (await runDurableObjectAlarm(coordinator)) {
        // Drain the directory invalidation that ran before an endpoint existed.
      }

      expect(
        (await api("/v2/clients/me/push-endpoints/liveactivity-start", {
          method: "PUT",
          token: client.statusToken,
          body: { token: "6a".repeat(32), environment: "sandbox" },
        })).status,
      ).toBe(200);
      const pending = await env.DB
        .prepare(
          `SELECT last_sequence AS lastSequence, last_total_running AS lastTotal
             FROM push_endpoints
            WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
        )
        .bind(client.clientId)
        .first();
      expect(Number(pending.lastSequence)).toBe(-1);
      expect(Number(pending.lastTotal)).toBe(0);

      expect(await runDurableObjectAlarm(coordinator)).toBe(true);
      const delivered = await env.DB
        .prepare(
          `SELECT last_sequence AS lastSequence, last_total_running AS lastTotal
             FROM push_endpoints
            WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
        )
        .bind(client.clientId)
        .first();
      expect(Number(delivered.lastSequence)).toBe(-1);
      expect(Number(delivered.lastTotal)).toBe(0);

      expect(
        (await api("/v2/clients/me/push-endpoints/liveactivity-start", {
          method: "PUT",
          token: client.statusToken,
          body: { token: "6b".repeat(32), environment: "sandbox" },
        })).status,
      ).toBe(200);
      const rotated = await env.DB
        .prepare(
          `SELECT token, last_sequence AS lastSequence,
                  last_total_running AS lastTotal
             FROM push_endpoints
            WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
        )
        .bind(client.clientId)
        .first();
      expect(rotated.token).toBe("6b".repeat(32));
      expect(Number(rotated.lastSequence)).toBe(-1);
      expect(Number(rotated.lastTotal)).toBe(0);
      await waitFor(async () => (await runDurableObjectAlarm(coordinator)) || null);
    } finally {
      closeAll(host);
    }
  });

  test("push coordinator delivers every surface and ends an offline activity", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const coordinator = env.PUSH_COORDINATOR.getByName(client.clientId);
    try {
      host.ws.send(
        hostSnapshot("Push Mac", runningSessions(2)),
      );
      const online = await waitFor(async () => {
        const snapshot = await state(client);
        return snapshot.totalRunning === 2 ? snapshot : null;
      });

      const surfaces = [
        "ios-widget",
        "watch-widget",
        "liveactivity-start",
        "liveactivity-update",
      ];
      for (const [index, surface] of surfaces.entries()) {
        const response = await api(`/v2/clients/me/push-endpoints/${surface}`, {
          method: "PUT",
          token: client.statusToken,
          body: {
            token: (index + 1).toString(16).padStart(2, "0").repeat(32),
            environment: "sandbox",
            activityId: surface === "liveactivity-update" ? "activity-1" : undefined,
          },
        });
        expect(response.status).toBe(200);
      }

      const pendingStart = await env.DB
        .prepare(
          `SELECT last_sequence AS lastSequence, last_total_running AS lastTotal
             FROM push_endpoints
            WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
        )
        .bind(client.clientId)
        .first();
      expect([-1, online.sequence]).toContain(Number(pendingStart.lastSequence));
      expect([0, 2]).toContain(Number(pendingStart.lastTotal));

      // Wait on the delivered effect, not the alarm: the coalescing alarm
      // also fires for real and may already have processed the queue.
      const delivered = await waitFor(async () => {
        try {
          await runDurableObjectAlarm(coordinator);
        } catch {
          return null; // collided with the real alarm invocation; re-check
        }
        const rows = await env.DB
          .prepare(
            `SELECT surface, last_sequence AS lastSequence, last_total_running AS lastTotal,
                    invalidated_at AS invalidatedAt
               FROM push_endpoints
              WHERE client_id = ?1
              ORDER BY surface`,
          )
          .bind(client.clientId)
          .all();
        const updated = (rows.results ?? []).filter(
          (row) => row.surface !== "liveactivity-start",
        );
        return rows.results?.length === 4
          && updated.every((row) => Number(row.lastSequence) === online.sequence)
          ? rows
          : null;
      });
      expect(delivered.results.filter((row) => row.surface !== "liveactivity-start")
        .every((row) => Number(row.lastTotal) === 2)).toBe(true);
      const untouchedStart = delivered.results.find(
        (row) => row.surface === "liveactivity-start",
      );
      expect(Number(untouchedStart.lastSequence)).toBe(-1);
      expect(Number(untouchedStart.lastTotal)).toBe(0);
      expect(delivered.results.every((row) => row.invalidatedAt === null)).toBe(true);
      await drainCoordinator(coordinator);

      const rotatedStart = await api(
        "/v2/clients/me/push-endpoints/liveactivity-start",
        {
          method: "PUT",
          token: client.statusToken,
          body: {
            token: "05".repeat(32),
            environment: "sandbox",
          },
        },
      );
      expect(rotatedStart.status).toBe(200);
      const startBaseline = await env.DB
        .prepare(
          `SELECT last_sequence AS lastSequence, last_total_running AS lastTotal
             FROM push_endpoints
            WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
        )
        .bind(client.clientId)
        .first();
      expect(Number(startBaseline.lastSequence)).toBe(-1);
      expect(Number(startBaseline.lastTotal)).toBe(0);
      await drainCoordinator(coordinator);

      host.ws.send(JSON.stringify({ type: "host-offline" }));
      await waitFor(async () => ((await state(client)).totalRunning === 0 ? true : null));
      // Wait for the end-event effect (endpoint deleted) however the alarm
      // got to run.
      await waitFor(async () => {
        try {
          await runDurableObjectAlarm(coordinator);
        } catch {
          return null; // collided with the real alarm invocation; re-check
        }
        const ended = await env.DB
          .prepare(
            `SELECT id
               FROM push_endpoints
              WHERE client_id = ?1 AND surface = 'liveactivity-update'`,
          )
          .bind(client.clientId)
          .first();
        return ended === null ? true : null;
      });
      expect(
        await env.DB
          .prepare(
            `SELECT COUNT(*) AS count
               FROM push_endpoints
              WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
          )
          .bind(client.clientId)
          .first("count"),
      ).toBe(1);
    } finally {
      closeAll(host);
    }
  });

  test("APNs 410 deletes a Live Activity update endpoint", async () => {
    const client = await createClient();
    const coordinator = env.PUSH_COORDINATOR.getByName(client.clientId);
    expect(
      (await api("/v2/clients/me/push-endpoints/liveactivity-update", {
        method: "PUT",
        token: client.statusToken,
        body: {
          token: "de".repeat(32),
          environment: "sandbox",
          activityId: "unregistered-activity",
        },
      })).status,
    ).toBe(200);

    await waitFor(async () => (await runDurableObjectAlarm(coordinator)) || null);
    expect(
      await env.DB
        .prepare(
          `SELECT COUNT(*) AS count
             FROM push_endpoints
            WHERE client_id = ?1 AND surface = 'liveactivity-update'`,
        )
        .bind(client.clientId)
        .first("count"),
    ).toBe(0);
  });

  test("more than eight Live Activity start/update/end cycles recycle update tokens", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const coordinator = env.PUSH_COORDINATOR.getByName(client.clientId);
    try {
      expect(
        (await api("/v2/clients/me/push-endpoints/liveactivity-start", {
          method: "PUT",
          token: client.statusToken,
          body: { token: "70".repeat(32), environment: "sandbox" },
        })).status,
      ).toBe(200);

      let previousSequence = (await state(client)).sequence;
      for (let cycle = 0; cycle < 10; cycle += 1) {
        host.ws.send(
          hostSnapshot("Cycling Mac", runningSessions(1, cycle + 1)),
        );
        const online = await waitFor(async () => {
          const snapshot = await state(client);
          return snapshot.totalRunning === 1 && snapshot.sequence > previousSequence
            ? snapshot
            : null;
        });
        await waitFor(async () => (await runDurableObjectAlarm(coordinator)) || null);

        const registered = await api(
          "/v2/clients/me/push-endpoints/liveactivity-update",
          {
            method: "PUT",
            token: client.statusToken,
            body: {
              token: (0x80 + cycle).toString(16).repeat(32),
              environment: "sandbox",
              activityId: `cycle-${cycle}`,
            },
          },
        );
        expect(registered.status).toBe(200);
        await waitFor(async () => (await runDurableObjectAlarm(coordinator)) || null);
        expect(
          await env.DB
            .prepare(
              `SELECT COUNT(*) AS count
                 FROM push_endpoints
                WHERE client_id = ?1 AND surface = 'liveactivity-update'
                  AND invalidated_at IS NULL`,
            )
            .bind(client.clientId)
            .first("count"),
        ).toBe(1);

        host.ws.send(
          hostSnapshot("Cycling Mac", []),
        );
        const offline = await waitFor(async () => {
          const snapshot = await state(client);
          return snapshot.totalRunning === 0 && snapshot.sequence > online.sequence
            ? snapshot
            : null;
        });
        await waitFor(async () => (await runDurableObjectAlarm(coordinator)) || null);
        expect(
          await env.DB
            .prepare(
              `SELECT COUNT(*) AS count
                 FROM push_endpoints
                WHERE client_id = ?1 AND surface = 'liveactivity-update'`,
            )
            .bind(client.clientId)
            .first("count"),
        ).toBe(0);
        const start = await env.DB
          .prepare(
            `SELECT invalidated_at AS invalidatedAt,
                    last_total_running AS lastTotalRunning
               FROM push_endpoints
              WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
          )
          .bind(client.clientId)
          .first();
        expect(start).not.toBeNull();
        expect(start.invalidatedAt).toBeNull();
        expect(Number(start.lastTotalRunning)).toBe(0);
        previousSequence = offline.sequence;
      }

      expect(
        await env.DB
          .prepare(`SELECT COUNT(*) AS count FROM push_endpoints WHERE client_id = ?1`)
          .bind(client.clientId)
          .first("count"),
      ).toBe(1);
    } finally {
      closeAll(host);
    }
  });

  test("APNs Retry-After parsing is bounded and uses a safe fallback", () => {
    const now = 2_000_000_000_000;
    expect(retryAtFromHeader("10", now)).toBe(now + 60_000);
    expect(retryAtFromHeader("3600", now)).toBe(now + 3_600_000);
    expect(retryAtFromHeader("999999", now)).toBe(now + 24 * 60 * 60_000);
    expect(retryAtFromHeader("not-a-date", now)).toBe(now + 15 * 60_000);
    expect(
      retryAtFromHeader(new Date(now + 2 * 60 * 60_000).toUTCString(), now),
    ).toBe(now + 2 * 60 * 60_000);
  });

  test("APNs 429 defers the endpoint and Durable Object alarm for Retry-After", async () => {
    const client = await createClient();
    const coordinator = env.PUSH_COORDINATOR.getByName(client.clientId);
    expect(
      (await api("/v2/clients/me/push-endpoints/ios-widget", {
        method: "PUT",
        token: client.statusToken,
        body: { token: "fb".repeat(32), environment: "sandbox" },
      })).status,
    ).toBe(200);

    const before = Date.now();
    await waitFor(async () => (await runDurableObjectAlarm(coordinator)) || null);
    const endpoint = await env.DB
      .prepare(
        `SELECT retry_not_before AS retryNotBefore,
                failure_count AS failureCount,
                last_failure_reason AS lastFailureReason
           FROM push_endpoints
          WHERE client_id = ?1 AND surface = 'ios-widget'`,
      )
      .bind(client.clientId)
      .first();
    expect(Number(endpoint.failureCount)).toBe(1);
    expect(endpoint.lastFailureReason).toBe("TooManyRequests");
    expect(Number(endpoint.retryNotBefore) * 1000).toBeGreaterThanOrEqual(
      before + 3_599_000,
    );

    await runInDurableObject(coordinator, async (_instance, state) => {
      const alarm = await state.storage.getAlarm();
      expect(alarm).toBeGreaterThanOrEqual(before + 3_599_000);
      expect(await state.storage.get("pendingClientIds")).toEqual([client.clientId]);
    });
  });

  test("fatal APNs configuration failures are quarantined until registration refresh", async () => {
    const client = await createClient();
    const coordinator = env.PUSH_COORDINATOR.getByName(client.clientId);
    expect(
      (await api("/v2/clients/me/push-endpoints/watch-widget", {
        method: "PUT",
        token: client.statusToken,
        body: { token: "fa".repeat(32), environment: "sandbox" },
      })).status,
    ).toBe(200);

    const before = Date.now();
    await waitFor(async () => (await runDurableObjectAlarm(coordinator)) || null);
    const endpoint = await env.DB
      .prepare(
        `SELECT retry_not_before AS retryNotBefore,
                failure_count AS failureCount,
                last_failure_reason AS lastFailureReason
           FROM push_endpoints
          WHERE client_id = ?1 AND surface = 'watch-widget'`,
      )
      .bind(client.clientId)
      .first();
    expect(Number(endpoint.failureCount)).toBe(1);
    expect(endpoint.lastFailureReason).toBe("BadTopic");
    expect(Number(endpoint.retryNotBefore) * 1000).toBeGreaterThanOrEqual(
      before + 24 * 60 * 60_000 - 1_000,
    );

    const notified = [];
    await reconcilePendingPushes({
      DB: env.DB,
      PUSH_COORDINATOR: {
        getByName(clientId) {
          return {
            fetch: async () => {
              notified.push(clientId);
              return new Response(null, { status: 202 });
            },
          };
        },
      },
    });
    expect(notified).not.toContain(client.clientId);

    expect(
      (await api("/v2/clients/me/push-endpoints/watch-widget", {
        method: "PUT",
        token: client.statusToken,
        body: { token: "fc".repeat(32), environment: "sandbox" },
      })).status,
    ).toBe(200);
    const refreshed = await env.DB
      .prepare(
        `SELECT retry_not_before AS retryNotBefore,
                failure_count AS failureCount,
                last_failure_reason AS lastFailureReason
           FROM push_endpoints
          WHERE client_id = ?1 AND surface = 'watch-widget'`,
      )
      .bind(client.clientId)
      .first();
    expect(refreshed).toEqual({
      retryNotBefore: null,
      failureCount: 0,
      lastFailureReason: null,
    });
  });

  test("push retry preserves a forced sequence-zero delivery", async () => {
    const client = await createClient();
    const coordinator = env.PUSH_COORDINATOR.getByName(client.clientId);
    expect(
      (await coordinator.fetch("https://push.internal/invalidate", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ clientIds: [client.clientId], force: true }),
      })).status,
    ).toBe(202);

    await runInDurableObject(coordinator, async (instance, state) => {
      const retryAt = Date.now() + 15 * 60_000;
      instance.deliverClient = async (clientId, force) => {
        expect(clientId).toBe(client.clientId);
        expect(force).toBe(true);
        return retryAt;
      };
      await instance.alarm();
      expect(await state.storage.get("pendingClientIds")).toEqual([client.clientId]);
      expect(await state.storage.get("forceClientIds")).toEqual([client.clientId]);
      expect(await state.storage.getAlarm()).toBe(retryAt);
      await state.storage.delete(["pendingClientIds", "forceClientIds"]);
      await state.storage.deleteAlarm();
    });
  });
});

describe("Pedals authenticated v2 relay", () => {
  test("rejects missing credentials, unrelated clients, and legacy role query", async () => {
    const computer = await createComputer();
    const client = await createClient();
    const unrelated = await createClient();
    expect((await bind(client, computer)).status).toBe(201);

    const noAuth = await exports.default.fetch(
      new Request(
        `https://relay.test/v2/relay/${computer.computerId}?channel=control`,
        { headers: { upgrade: "websocket" } },
      ),
    );
    expect(noAuth.status).toBe(401);
    expect((await connect(computer.computerId, unrelated.clientToken)).response.status).toBe(401);

    const roleQuery = await exports.default.fetch(
      new Request(
        `https://relay.test/v2/relay/${computer.computerId}?channel=control&role=host`,
        {
          headers: {
            upgrade: "websocket",
            authorization: `Bearer ${computer.hostToken}`,
          },
        },
      ),
    );
    expect(roleQuery.status).toBe(400);
  });

  test("keeps host frames verbatim and authenticates each client frame source", async () => {
    const computer = await createComputer();
    const firstIdentity = await createClient();
    const secondIdentity = await createClient();
    expect((await bind(firstIdentity, computer)).status).toBe(201);
    expect((await bind(secondIdentity, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const first = (await connect(computer.computerId, firstIdentity.clientToken)).peer;
    const second = (await connect(computer.computerId, secondIdentity.clientToken)).peer;
    try {
      expect(await first.nextDirectory()).toMatchObject({
        type: "terminal-directory", online: false, sessions: [],
      });
      expect(await second.nextDirectory()).toMatchObject({
        type: "terminal-directory", online: false, sessions: [],
      });
      const down = bytes(64 * 1024, 7);
      host.ws.send(down);
      expect(asBytes(await first.nextBinary())).toEqual(down);
      expect(asBytes(await second.nextBinary())).toEqual(down);

      const firstUp = bytes(31, 17);
      first.ws.send(firstUp);
      expect(decodeClientSourceEnvelope(await host.nextBinary())).toEqual({
        principalId: firstIdentity.clientId,
        wire: firstUp,
      });

      // A payload may itself begin with a plausible source header. The DO
      // still prepends the principal from the authenticated socket attachment
      // and never trusts or recursively parses caller bytes.
      const fakeClaim = new Uint8Array(
        CLIENT_SOURCE_ENVELOPE_BYTES + 19,
      );
      fakeClaim[0] = CLIENT_SOURCE_ENVELOPE_VERSION;
      fakeClaim.set(new TextEncoder().encode(firstIdentity.clientId), 1);
      fakeClaim.set(bytes(19, 29), CLIENT_SOURCE_ENVELOPE_BYTES);
      second.ws.send(fakeClaim);
      expect(decodeClientSourceEnvelope(await host.nextBinary())).toEqual({
        principalId: secondIdentity.clientId,
        wire: fakeClaim,
      });
    } finally {
      closeAll(host, first, second);
    }
  });

  test("applies the 1 MiB peer limit before adding the source envelope", async () => {
    const computer = await createComputer();
    const identity = await createClient();
    expect((await bind(identity, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const client = (await connect(computer.computerId, identity.clientToken)).peer;
    try {
      await client.nextDirectory();
      const maximum = bytes(MAX_BINARY_BYTES, 67);
      client.ws.send(maximum);
      const forwarded = decodeClientSourceEnvelope(await host.nextBinary());
      expect(forwarded.principalId).toBe(identity.clientId);
      expect(forwarded.wire).toEqual(maximum);

      client.ws.send(bytes(MAX_BINARY_BYTES + 1, 71));
      expect((await client.nextClose()).code).toBe(1009);
      await expectNoEvent(host.nextBinary);
    } finally {
      closeAll(host, client);
    }
  });

  test("isolates session channels and rejects non-canonical sid", async () => {
    const computer = await createComputer();
    const identity = await createClient();
    expect((await bind(identity, computer)).status).toBe(201);

    const bad = await connect(computer.computerId, computer.hostToken, "session", "01");
    expect(bad.response.status).toBe(400);
    const host1 = (await connect(computer.computerId, computer.hostToken, "session", 1)).peer;
    const client1 = (await connect(computer.computerId, identity.clientToken, "session", 1)).peer;
    const client2 = (await connect(computer.computerId, identity.clientToken, "session", 2)).peer;
    try {
      const [firstState, secondState] = await Promise.all([
        client1.nextChannelState(), client2.nextChannelState(),
      ]);
      expect(firstState.online).toBe(true);
      expect(secondState.online).toBe(false);
      const message = bytes(64, 29);
      host1.ws.send(message);
      expect(asBytes(await client1.nextBinary())).toEqual(message);
      await expectNoEvent(client2.nextBinary);
    } finally {
      closeAll(host1, client1, client2);
    }
  });

  test("bounds active channels per client while allowing same-channel replacement", async () => {
    const computer = await createComputer();
    const identity = await createClient();
    expect((await bind(identity, computer)).status).toBe(201);
    const peers = [];
    try {
      const control = await connect(computer.computerId, identity.clientToken);
      expect(control.response.status).toBe(101);
      peers.push(control.peer);
      for (let sid = 1; sid < MAX_CLIENT_ACTIVE_CHANNELS; sid += 1) {
        const connection = await connect(
          computer.computerId,
          identity.clientToken,
          "session",
          sid,
        );
        expect(connection.response.status).toBe(101);
        peers.push(connection.peer);
      }

      const limited = await connect(
        computer.computerId,
        identity.clientToken,
        "session",
        MAX_CLIENT_ACTIVE_CHANNELS,
      );
      expect(limited.response.status).toBe(429);
      expect(limited.response.headers.get("retry-after")).toBe("60");

      const replacement = await connect(
        computer.computerId,
        identity.clientToken,
        "session",
        1,
      );
      expect(replacement.response.status).toBe(101);
      peers.push(replacement.peer);
      expect((await peers[1].nextClose()).code).toBe(4000);
    } finally {
      closeAll(...peers);
    }
  });

  test("new host replaces old host without a directory flap", async () => {
    const computer = await createComputer();
    const identity = await createClient();
    expect((await bind(identity, computer)).status).toBe(201);
    const host1 = (await connect(computer.computerId, computer.hostToken)).peer;
    const client = (await connect(computer.computerId, identity.clientToken)).peer;
    try {
      await client.nextDirectory();
      const host2 = (await connect(computer.computerId, computer.hostToken)).peer;
      try {
        expect((await host1.nextClose()).code).toBe(4000);
        await expectNoEvent(client.nextText, 250);
        const message = bytes(12, 41);
        client.ws.send(message);
        expect(decodeClientSourceEnvelope(await host2.nextBinary())).toEqual({
          principalId: identity.clientId,
          wire: message,
        });
      } finally {
        closeAll(host2);
      }
    } finally {
      closeAll(host1, client);
    }
  });

  test("hibernation retains authenticated routing and role ownership", async () => {
    const computer = await createComputer();
    const identity = await createClient();
    expect((await bind(identity, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const client = (await connect(computer.computerId, identity.clientToken)).peer;
    try {
      await client.nextDirectory();
      await evictDurableObject(
        env.RELAY_CHANNELS.getByName(computer.computerId),
      );
      const up = bytes(20, 47);
      client.ws.send(up);
      expect(decodeClientSourceEnvelope(await host.nextBinary())).toEqual({
        principalId: identity.clientId,
        wire: up,
      });
      const down = bytes(256 * 1024, 53);
      host.ws.send(down);
      expect(asBytes(await client.nextBinary())).toEqual(down);
    } finally {
      closeAll(host, client);
    }
  });

  test("DO terminal directory drives aggregate count and explicit offline clearing", async () => {
    const computer = await createComputer();
    const identity = await createClient();
    expect((await bind(identity, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const client = (await connect(computer.computerId, identity.clientToken)).peer;
    try {
      await client.nextDirectory();
      host.ws.send(
        hostSnapshot("Studio Mac", [
          { id: 1, alive: true },
          { id: 2, alive: false },
          { id: 3, alive: true },
          { id: 4, alive: true },
        ]),
      );
      expect(await client.nextDirectory()).toMatchObject({
        online: true,
        hostName: "Studio Mac",
        sessions: [
          { id: 1, alive: true },
          { id: 2, alive: false },
          { id: 3, alive: true },
          { id: 4, alive: true },
        ],
      });
      const online = await waitFor(async () => {
        const snapshot = await state(identity);
        return snapshot.totalRunning === 3 && snapshot.computers[0]?.online
          ? snapshot
          : null;
      });
      expect(online.computers[0]).toMatchObject({
        name: "Studio Mac",
        runningTTYCount: 3,
        online: true,
      });

      host.ws.send(JSON.stringify({ type: "host-offline" }));
      expect(await client.nextDirectory()).toMatchObject({
        type: "terminal-directory", online: false, sessions: [],
        reason: "host-requested",
      });
      const offline = await waitFor(async () => {
        const snapshot = await state(identity);
        return snapshot.computers[0]?.online === false ? snapshot : null;
      });
      expect(offline.totalRunning).toBe(0);
      expect(offline.computers[0].runningTTYCount).toBe(0);
      expect(offline.computers[0].name).toBe("Studio Mac");
    } finally {
      closeAll(host, client);
    }
  });

  test("invalid host snapshot closes only the authenticated host", async () => {
    const computer = await createComputer();
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    try {
      host.ws.send(
        JSON.stringify({
          type: "host-snapshot",
          hostName: "Bad Mac",
          sessions: [{ id: 2, alive: true }, { id: 1, alive: true }],
        }),
      );
      expect((await host.nextClose()).code).toBe(1008);
    } finally {
      closeAll(host);
    }
  });

  test("explicit offline queued behind a snapshot cannot leave a ghost directory", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    host.ws.send(
      hostSnapshot("Race Mac", runningSessions(9)),
    );
    host.ws.send(JSON.stringify({ type: "host-offline" }));
    const offline = await waitFor(async () => {
      const snapshot = await state(client);
      return snapshot.computers[0]?.online === false && snapshot.sequence >= 3
        ? snapshot
        : null;
    });
    expect(offline.totalRunning).toBe(0);
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect((await state(client)).computers[0].online).toBe(false);
  });
});

describe("terminal directory aggregation and expiry", () => {
  test("host reconnect inside the weak-network grace preserves the directory", async () => {
    const client = await createClient();
    const computer = await createComputer();
    expect((await bind(client, computer)).status).toBe(201);
    const stub = env.RELAY_CHANNELS.getByName(computer.computerId);
    const host1 = (await connect(computer.computerId, computer.hostToken)).peer;
    const controlClient = (await connect(computer.computerId, client.clientToken)).peer;
    let host2;
    try {
      await controlClient.nextDirectory();
      const snapshot = hostSnapshot("Roaming Mac", runningSessions(2));
      host1.ws.send(snapshot);
      const initial = await controlClient.nextDirectory();
      const initialState = await waitFor(async () => {
        const value = await state(client);
        return value.totalRunning === 2 ? value : null;
      });

      host1.ws.close(1000, "network handoff");
      await waitFor(async () => runInDurableObject(stub, async (_instance, durableState) => {
        const value = await durableState.storage.get("terminal-directory");
        return value?.reason === "connection-lost" ? true : null;
      }));
      await expectNoEvent(controlClient.nextText, 100);

      host2 = (await connect(computer.computerId, computer.hostToken)).peer;
      host2.ws.send(snapshot);
      await waitFor(async () => runInDurableObject(stub, async (_instance, durableState) => {
        const value = await durableState.storage.get("terminal-directory");
        return value?.online && value.reason === null &&
          value.deadlineAt >= Date.now() + HOST_DIRECTORY_LEASE_MS - 2_000
          ? value
          : null;
      }));
      await expectNoEvent(controlClient.nextText, 150);
      const recovered = await state(client);
      expect(recovered.totalRunning).toBe(2);
      expect(recovered.sequence).toBe(initialState.sequence);
      const persisted = await runInDurableObject(stub, async (_instance, durableState) => (
        durableState.storage.get("terminal-directory")
      ));
      expect(persisted.revision).toBe(initial.revision);
    } finally {
      closeAll(host1, host2, controlClient);
    }
  });

  test("aggregates only online computers across a client's binding set", async () => {
    const client = await createClient();
    const first = await createComputer();
    const second = await createComputer();
    expect((await bind(client, first)).status).toBe(201);
    expect((await bind(client, second)).status).toBe(201);

    const host1 = (await connect(first.computerId, first.hostToken)).peer;
    const host2 = (await connect(second.computerId, second.hostToken)).peer;
    try {
      host1.ws.send(
        hostSnapshot("First", runningSessions(2)),
      );
      host2.ws.send(
        hostSnapshot("Second", runningSessions(5)),
      );
      const combined = await waitFor(async () => {
        const snapshot = await state(client);
        return snapshot.totalRunning === 7 ? snapshot : null;
      });
      expect(combined.computers.filter((computer) => computer.online)).toHaveLength(2);

      host2.ws.send(JSON.stringify({ type: "host-offline" }));
      const oneOnline = await waitFor(async () => {
        const snapshot = await state(client);
        return snapshot.totalRunning === 2 &&
          snapshot.computers.filter((computer) => computer.online).length === 1
          ? snapshot
          : null;
      });
      expect(oneOnline.computers.find((computer) => computer.name === "Second")).toMatchObject({
        online: false,
        runningTTYCount: 0,
      });
    } finally {
      closeAll(host1, host2);
    }
  });

  test("DO alarm clears a disconnected host after the weak-network grace", async () => {
    const client = await createClient();
    const computer = await createComputer();
    expect((await bind(client, computer)).status).toBe(201);
    const stub = env.RELAY_CHANNELS.getByName(computer.computerId);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const controlClient = (await connect(computer.computerId, client.clientToken)).peer;
    try {
      await controlClient.nextDirectory();
      host.ws.send(hostSnapshot("Grace Mac", runningSessions(4)));
      expect((await controlClient.nextDirectory()).online).toBe(true);
      await waitFor(async () => ((await state(client)).totalRunning === 4 ? true : null));

      host.ws.close(1000, "network lost");
      await expectNoEvent(controlClient.nextText, 150);
      expect((await state(client)).totalRunning).toBe(4);

      await runInDurableObject(stub, async (_instance, durableState) => {
        const directory = await durableState.storage.get("terminal-directory");
        await durableState.storage.put("terminal-directory", {
          ...directory,
          deadlineAt: Date.now() - 1,
          reason: "connection-lost",
        });
        await durableState.storage.setAlarm(Date.now() - 1);
      });
      await runDurableObjectAlarm(stub);
      expect(await controlClient.nextDirectory()).toMatchObject({
        online: false, sessions: [], reason: "connection-lost",
      });
      await waitFor(async () => ((await state(client)).totalRunning === 0 ? true : null));
    } finally {
      closeAll(host, controlClient);
    }
  });
});

describe("scheduled abuse cleanup and push reconciliation", () => {
  test("removes expired pairing sessions and truly orphaned identities at bounded ages", async () => {
    const orphanClient = await createClient();
    const retainedClient = await createClient();
    const orphanComputer = await createComputer();
    const retainedComputer = await createComputer();
    const expiredInvite = await createInvite(retainedComputer);
    expect((await bind(retainedClient, retainedComputer)).status).toBe(201);
    expect(
      (await api("/v2/clients/me/push-endpoints/ios-widget", {
        method: "PUT",
        token: orphanClient.statusToken,
        body: { token: "f9".repeat(32), environment: "sandbox" },
      })).status,
    ).toBe(200);

    const now = Math.floor(Date.now() / 1000);
    await env.DB.batch([
      env.DB
        .prepare(`UPDATE clients SET created_at = ?2 WHERE id = ?1`)
        .bind(orphanClient.clientId, now - ORPHAN_CLIENT_RETENTION_SECONDS - 1),
      env.DB
        .prepare(`UPDATE clients SET created_at = ?2 WHERE id = ?1`)
        .bind(retainedClient.clientId, now - ORPHAN_CLIENT_RETENTION_SECONDS - 1),
      env.DB
        .prepare(`UPDATE computers SET created_at = ?2 WHERE id = ?1`)
        .bind(orphanComputer.computerId, now - ORPHAN_COMPUTER_RETENTION_SECONDS - 1),
      env.DB
        .prepare(`UPDATE computers SET created_at = ?2 WHERE id = ?1`)
        .bind(retainedComputer.computerId, now - ORPHAN_COMPUTER_RETENTION_SECONDS - 1),
      env.DB
        .prepare(`UPDATE pairing_sessions SET expires_at = 0 WHERE id = ?1`)
        .bind(await (async () => {
          const result = await env.DB
            .prepare(
              `SELECT id
                 FROM pairing_sessions
                WHERE computer_id = ?1`,
            )
            .bind(retainedComputer.computerId)
            .first();
          return result.id;
        })()),
    ]);

    await collectOrphans(env);
    expect(
      Number(
        await env.DB
          .prepare(`SELECT COUNT(*) AS count FROM clients WHERE id = ?1`)
          .bind(orphanClient.clientId)
          .first("count"),
      ),
    ).toBe(0);
    expect(
      Number(
        await env.DB
          .prepare(`SELECT COUNT(*) AS count FROM push_endpoints WHERE client_id = ?1`)
          .bind(orphanClient.clientId)
          .first("count"),
      ),
    ).toBe(0);
    expect(
      Number(
        await env.DB
          .prepare(`SELECT COUNT(*) AS count FROM computers WHERE id = ?1`)
          .bind(orphanComputer.computerId)
          .first("count"),
      ),
    ).toBe(0);
    expect(
      Number(
        await env.DB
          .prepare(`SELECT COUNT(*) AS count FROM clients WHERE id = ?1`)
          .bind(retainedClient.clientId)
          .first("count"),
      ),
    ).toBe(1);
    expect(
      Number(
        await env.DB
          .prepare(`SELECT COUNT(*) AS count FROM computers WHERE id = ?1`)
          .bind(retainedComputer.computerId)
          .first("count"),
      ),
    ).toBe(1);
    expect(
      Number(
        await env.DB
          .prepare(
            `SELECT COUNT(*) AS count
               FROM pairing_sessions
              WHERE computer_id = ?1 AND expires_at = 0`,
          )
          .bind(retainedComputer.computerId)
          .first("count"),
      ),
    ).toBe(0);
    expect(expiredInvite.code).toMatch(/^\d{8}$/);
  });

  test("reconciliation cursor eventually reaches clients beyond the first page", async () => {
    const marker = -103;
    const now = Math.floor(Date.now() / 1000);
    const existingEndpoints = await env.DB
      .prepare(`SELECT id, retry_not_before AS retryNotBefore FROM push_endpoints`)
      .all();
    const existingCursor = await env.DB
      .prepare(`SELECT value, updated_at AS updatedAt FROM service_runtime_state WHERE key = ?1`)
      .bind("push_reconcile_cursor")
      .first();
    await env.DB
      .prepare(`UPDATE push_endpoints SET retry_not_before = ?1`)
      .bind(now + 24 * 60 * 60)
      .run();
    await env.DB
      .prepare(`DELETE FROM service_runtime_state WHERE key = 'push_reconcile_cursor'`)
      .run();

    try {
      await env.DB.batch([
        env.DB
          .prepare(
            `WITH RECURSIVE seq(i) AS (
               SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < 30
             )
             INSERT INTO clients
               (id, auth_token_hash, status_token_hash, created_at, last_seen_at)
             SELECT printf('c3%030x', i), printf('c4%062x', i),
                    printf('c5%062x', i), ?1, ?2
               FROM seq`,
          )
          .bind(marker, now),
        env.DB.prepare(
          `INSERT INTO client_delivery_state
             (client_id, sequence, last_fingerprint, last_pushed_at)
           SELECT id, 1, NULL, NULL FROM clients WHERE created_at = ?1`,
        ).bind(marker),
        env.DB
          .prepare(
            `WITH RECURSIVE seq(i) AS (
               SELECT 1 UNION ALL SELECT i + 1 FROM seq WHERE i < 30
             )
             INSERT INTO push_endpoints
               (id, client_id, surface, apns_environment, token, token_hash,
                activity_key, created_at, updated_at, invalidated_at,
                last_sequence, last_total_running)
             SELECT printf('c6%030x', i), printf('c3%030x', i),
                    'ios-widget', 'sandbox', printf('%064x', i),
                    printf('c7%062x', i), '', ?1, ?1, NULL, 0, 0
               FROM seq`,
          )
          .bind(now),
      ]);

      const expected = (
        await env.DB
          .prepare(`SELECT id FROM clients WHERE created_at = ?1 ORDER BY id`)
          .bind(marker)
          .all()
      ).results.map((row) => row.id);
      const notified = [];
      const reconcileEnv = {
        DB: env.DB,
        PUSH_COORDINATOR: {
          getByName(clientId) {
            return {
              fetch: async () => {
                notified.push(clientId);
                return new Response(null, { status: 202 });
              },
            };
          },
        },
      };

      await reconcilePendingPushes(reconcileEnv);
      const firstPage = notified.slice();
      expect(firstPage).toHaveLength(25);
      await reconcilePendingPushes(reconcileEnv);
      const secondPage = notified.slice(25);
      expect(secondPage).toHaveLength(25);
      const missedInitially = expected.filter((clientId) => !firstPage.includes(clientId));
      expect(missedInitially).toHaveLength(5);
      expect(missedInitially.every((clientId) => secondPage.includes(clientId))).toBe(true);
    } finally {
      await env.DB.prepare(`DELETE FROM clients WHERE created_at = ?1`).bind(marker).run();
      await env.DB
        .prepare(`DELETE FROM service_runtime_state WHERE key = 'push_reconcile_cursor'`)
        .run();
      if (existingCursor) {
        await env.DB
          .prepare(
            `INSERT INTO service_runtime_state (key, value, updated_at)
             VALUES ('push_reconcile_cursor', ?1, ?2)`,
          )
          .bind(existingCursor.value, existingCursor.updatedAt)
          .run();
      }
      for (const endpoint of existingEndpoints.results) {
        await env.DB
          .prepare(`UPDATE push_endpoints SET retry_not_before = ?2 WHERE id = ?1`)
          .bind(endpoint.id, endpoint.retryNotBefore)
          .run();
      }
    }
  });
});

describe("relay HTTP long-poll transport", () => {
  function pollUrl(computerId, { channel = "control", sid, session, after } = {}) {
    const query = new URLSearchParams({ channel });
    if (sid !== undefined) query.set("sid", String(sid));
    if (session !== undefined) query.set("session", session);
    if (after !== undefined) query.set("after", String(after));
    return `/v2/relay/${computerId}/http?${query}`;
  }

  async function poll(computerId, token, options = {}) {
    const response = await api(pollUrl(computerId, options), { token });
    return { response, value: response.status === 200 ? await response.json() : null };
  }

  function wireBatch(...wires) {
    const total = wires.reduce((sum, wire) => sum + 4 + wire.byteLength, 0);
    const body = new Uint8Array(total);
    const view = new DataView(body.buffer);
    let offset = 0;
    for (const wire of wires) {
      view.setUint32(offset, wire.byteLength);
      body.set(wire, offset + 4);
      offset += 4 + wire.byteLength;
    }
    return body;
  }

  async function send(computerId, token, body, { channel = "control", sid } = {}) {
    const query = new URLSearchParams({ channel });
    if (sid !== undefined) query.set("sid", String(sid));
    return api(`/v2/relay/${computerId}/http?${query}`, {
      method: "POST",
      token,
      rawBody: body,
    });
  }

  function bytesFromBase64(encoded) {
    const binary = atob(encoded);
    const value = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) {
      value[index] = binary.charCodeAt(index);
    }
    return value;
  }

  const sessionA = "a1".repeat(16);
  const sessionB = "b2".repeat(16);

  test("poll delivers directory, host frames, acks, and redelivery", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = await connect(computer.computerId, computer.hostToken);
    expect(host.response.status).toBe(101);

    const opened = await poll(computer.computerId, client.clientToken, {
      session: sessionA,
    });
    expect(opened.response.status).toBe(200);
    expect(opened.value.messages).toHaveLength(1);
    const initialDirectory = JSON.parse(opened.value.messages[0].t);
    expect(initialDirectory.type).toBe("terminal-directory");
    let cursor = opened.value.next;

    host.peer.ws.send(hostSnapshot("Mac", runningSessions(2)));
    const updated = await waitFor(async () => {
      const result = await poll(computer.computerId, client.clientToken, {
        session: sessionA,
        after: cursor,
      });
      expect(result.response.status).toBe(200);
      if (result.value.messages.length === 0) return null;
      return result.value;
    });
    const directory = JSON.parse(updated.messages[0].t);
    expect(directory.type).toBe("terminal-directory");
    expect(directory.online).toBe(true);
    expect(directory.hostName).toBe("Mac");

    // Redelivery: the same cursor returns the same batch until acknowledged.
    const redelivered = await poll(computer.computerId, client.clientToken, {
      session: sessionA,
      after: cursor,
    });
    expect(redelivered.value.next).toBe(updated.next);
    expect(redelivered.value.messages).toEqual(updated.messages);
    cursor = updated.next;

    const frame = bytes(64, 7);
    host.peer.ws.send(frame);
    const binaryBatch = await waitFor(async () => {
      const result = await poll(computer.computerId, client.clientToken, {
        session: sessionA,
        after: cursor,
      });
      if (result.value.messages.length === 0) return null;
      return result.value;
    });
    expect(binaryBatch.messages).toHaveLength(1);
    expect(bytesFromBase64(binaryBatch.messages[0].b)).toEqual(frame);

    const wireOne = bytes(48, 1);
    const wireTwo = bytes(32, 2);
    const sent = await send(
      computer.computerId,
      client.clientToken,
      wireBatch(wireOne, wireTwo),
    );
    expect(sent.status).toBe(204);
    const first = decodeClientSourceEnvelope(await host.peer.nextBinary());
    expect(first.principalId).toBe(client.clientId);
    expect(new Uint8Array(first.wire)).toEqual(wireOne);
    const second = decodeClientSourceEnvelope(await host.peer.nextBinary());
    expect(new Uint8Array(second.wire)).toEqual(wireTwo);
    closeAll(host.peer);
  });

  test("session channels receive channel-state and stay isolated", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = await connect(computer.computerId, computer.hostToken, "session", 7);
    expect(host.response.status).toBe(101);

    const online = await poll(computer.computerId, client.clientToken, {
      channel: "session",
      sid: 7,
      session: sessionA,
    });
    expect(online.response.status).toBe(200);
    expect(JSON.parse(online.value.messages[0].t)).toEqual({
      type: "channel-state",
      online: true,
    });

    const offline = await poll(computer.computerId, client.clientToken, {
      channel: "session",
      sid: 9,
      session: sessionB,
    });
    expect(JSON.parse(offline.value.messages[0].t)).toEqual({
      type: "channel-state",
      online: false,
    });
    closeAll(host.peer);
  });

  test("rejects bad bearers, host bearers, and malformed requests", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);

    const hostBearer = await poll(computer.computerId, computer.hostToken, {
      session: sessionA,
    });
    expect(hostBearer.response.status).toBe(403);

    const badBearer = await poll(computer.computerId, "0".repeat(64), {
      session: sessionA,
    });
    expect(badBearer.response.status).toBe(401);

    const missingSession = await api(
      `/v2/relay/${computer.computerId}/http?channel=control`,
      { token: client.clientToken },
    );
    expect(missingSession.status).toBe(400);

    const badAfter = await poll(computer.computerId, client.clientToken, {
      session: sessionA,
      after: "07",
    });
    expect(badAfter.response.status).toBe(400);

    const truncated = wireBatch(bytes(16)).slice(0, 12);
    expect(
      (await send(computer.computerId, client.clientToken, truncated)).status,
    ).toBe(400);
    expect(
      (await send(computer.computerId, client.clientToken, new Uint8Array(0))).status,
    ).toBe(400);

    const unknownCursor = await poll(computer.computerId, client.clientToken, {
      session: sessionB,
      after: 3,
    });
    expect(unknownCursor.response.status).toBe(200);
    expect(unknownCursor.value).toEqual({ reset: true });
  });

  test("a new session token replaces the previous session", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);

    const first = await poll(computer.computerId, client.clientToken, {
      session: sessionA,
    });
    expect(first.response.status).toBe(200);
    const replacement = await poll(computer.computerId, client.clientToken, {
      session: sessionB,
    });
    expect(replacement.response.status).toBe(200);
    expect(replacement.value.messages).toHaveLength(1);

    const stale = await poll(computer.computerId, client.clientToken, {
      session: sessionA,
      after: first.value.next,
    });
    expect(stale.value).toEqual({ reset: true });
  });

  test("binding deletion resolves a parked poll with 401", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);

    const opened = await poll(computer.computerId, client.clientToken, {
      session: sessionA,
    });
    expect(opened.response.status).toBe(200);

    const parked = api(
      pollUrl(computer.computerId, { session: sessionA, after: opened.value.next }),
      { token: client.clientToken },
    );
    await new Promise((resolve) => setTimeout(resolve, 100));

    const removed = await api("/v2/clients/me/bindings", {
      method: "PUT",
      token: client.clientToken,
      body: { computerIds: [] },
    });
    expect(removed.status).toBe(200);
    expect((await parked).status).toBe(401);

    const rebound = await poll(computer.computerId, client.clientToken, {
      session: sessionB,
    });
    expect(rebound.response.status).toBe(401);
  });
});

describe("agent counts and alerts", () => {
  function snapshotWithAgents(hostName, sessions, agents) {
    return JSON.stringify({ type: "host-snapshot", hostName, sessions, agents });
  }

  test("agent counts flow from host snapshot to the aggregate state", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    try {
      host.ws.send(
        snapshotWithAgents("Agent Mac", runningSessions(1), {
          running: 2,
          waiting: 1,
        }),
      );
      const online = await waitFor(async () => {
        const snapshot = await state(client);
        return snapshot.agentsRunning === 2 ? snapshot : null;
      });
      expect(online).toMatchObject({
        totalRunning: 1,
        agentsRunning: 2,
        agentsWaiting: 1,
      });
      expect(online.computers[0].agents).toEqual({ running: 2, waiting: 1, done: 0 });

      // An agents-only change (same sessions) must bump the projection.
      host.ws.send(
        snapshotWithAgents("Agent Mac", runningSessions(1), {
          running: 0,
          waiting: 0,
        }),
      );
      const drained = await waitFor(async () => {
        const snapshot = await state(client);
        return snapshot.agentsRunning === 0 && snapshot.sequence > online.sequence
          ? snapshot
          : null;
      });
      expect(drained.agentsWaiting).toBe(0);

      // Offline zeroes agent counts like it zeroes the TTY count.
      host.ws.send(JSON.stringify({ type: "host-offline" }));
      const offline = await waitFor(async () => {
        const snapshot = await state(client);
        return snapshot.computers[0]?.online === false ? snapshot : null;
      });
      expect(offline.computers[0].agents).toEqual({ running: 0, waiting: 0, done: 0 });
      expect(offline.agentsWaiting).toBe(0);
    } finally {
      closeAll(host);
    }
  });

  test("legacy three-key snapshots still work; malformed agent counts close the host", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    try {
      host.ws.send(hostSnapshot("Legacy Mac", runningSessions(2)));
      const online = await waitFor(async () => {
        const snapshot = await state(client);
        return snapshot.totalRunning === 2 ? snapshot : null;
      });
      expect(online.agentsRunning).toBe(0);

      host.ws.send(
        snapshotWithAgents("Legacy Mac", runningSessions(2), {
          running: 256,
          waiting: 0,
        }),
      );
      expect((await host.nextClose()).code).toBe(1008);
    } finally {
      closeAll(host);
    }
  });

  test("working stays silent and only attention starts the island", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const coordinator = env.PUSH_COORDINATOR.getByName(client.clientId);
    try {
      expect(
        (await api("/v2/clients/me/push-endpoints/liveactivity-start", {
          method: "PUT",
          token: client.statusToken,
          body: { token: "ab".repeat(32), environment: "sandbox" },
        })).status,
      ).toBe(200);

      host.ws.send(
        snapshotWithAgents("Island Mac", [], { running: 1, waiting: 0, done: 0 }),
      );
      await waitFor(async () => ((await state(client)).agentsRunning === 1 ? true : null));
      host.ws.send(JSON.stringify({
        type: "agent-activity",
        activity: {
          eventID: "11111111-1111-4111-8111-111111111111",
          state: "running",
          updatedAt: Date.now(),
          alert: false,
          sealed: btoa("silent-ciphertext"),
        },
      }));
      await new Promise((resolve) => setTimeout(resolve, 200));
      let endpoint = await env.DB
        .prepare(
          `SELECT last_sequence AS lastSequence, last_total_running AS lastTotal
             FROM push_endpoints
            WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
        )
        .bind(client.clientId)
        .first();
      expect(Number(endpoint.lastSequence)).toBe(-1);
      expect(Number(endpoint.lastTotal)).toBe(0);

      host.ws.send(
        snapshotWithAgents("Island Mac", [], { running: 0, waiting: 1, done: 0 }),
      );
      await waitFor(async () => ((await state(client)).agentsWaiting === 1 ? true : null));
      host.ws.send(JSON.stringify({
        type: "agent-activity",
        activity: {
          eventID: "22222222-2222-4222-8222-222222222222",
          state: "waiting",
          updatedAt: Date.now(),
          alert: true,
          sealed: btoa("attention-ciphertext"),
        },
      }));
      endpoint = await waitFor(async () => {
        const row = await env.DB
          .prepare(
            `SELECT last_sequence AS lastSequence, last_total_running AS lastTotal
               FROM push_endpoints
              WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
          )
          .bind(client.clientId)
          .first();
        return Number(row?.lastTotal) === 1 ? row : null;
      });
      expect(Number(endpoint.lastSequence)).toBeGreaterThanOrEqual(0);
      expect(Number(endpoint.lastTotal)).toBe(1);

      expect(
        (await api("/v2/clients/me/push-endpoints/liveactivity-update", {
          method: "PUT",
          token: client.statusToken,
          body: {
            token: "ac".repeat(32),
            environment: "sandbox",
            activityId: "working-agent",
          },
        })).status,
      ).toBe(200);
      host.ws.send(
        snapshotWithAgents("Island Mac", [], { running: 0, waiting: 0, done: 0 }),
      );
      await waitFor(async () => {
        const snapshot = await state(client);
        return snapshot.agentsRunning === 0 && snapshot.agentsWaiting === 0
          ? true
          : null;
      });
      await waitFor(async () => (await runDurableObjectAlarm(coordinator)) || null);
      const endedUpdate = await env.DB
        .prepare(
          `SELECT id FROM push_endpoints
            WHERE client_id = ?1 AND surface = 'liveactivity-update'`,
        )
        .bind(client.clientId)
        .first();
      expect(endedUpdate).toBeNull();
      const resetStart = await env.DB
        .prepare(
          `SELECT last_total_running AS lastTotal
             FROM push_endpoints
            WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
        )
        .bind(client.clientId)
        .first();
      expect(Number(resetStart.lastTotal)).toBe(0);
    } finally {
      closeAll(host);
    }
  });

  test("attention activity updates an existing island without starting a duplicate", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const coordinator = env.PUSH_COORDINATOR.getByName(client.clientId);
    try {
      expect(
        (await api("/v2/clients/me/push-endpoints/liveactivity-start", {
          method: "PUT",
          token: client.statusToken,
          body: { token: "ba".repeat(32), environment: "sandbox" },
        })).status,
      ).toBe(200);

      host.ws.send(
        snapshotWithAgents("Island Mac", [], { running: 0, waiting: 1, done: 0 }),
      );
      await waitFor(async () => ((await state(client)).agentsWaiting === 1 ? true : null));

      expect(
        (await api("/v2/clients/me/push-endpoints/liveactivity-update", {
          method: "PUT",
          token: client.statusToken,
          body: {
            token: "bb".repeat(32),
            environment: "sandbox",
            activityId: "already-live",
          },
        })).status,
      ).toBe(200);
      const delivered = await coordinator.fetch("https://push.internal/activity", {
        method: "POST",
        body: JSON.stringify({
          clientId: client.clientId,
          computerId: computer.computerId,
          activity: {
          eventID: "33333333-3333-4333-8333-333333333333",
          state: "waiting",
          updatedAt: Date.now(),
          alert: true,
          sealed: btoa("existing-island-ciphertext"),
          },
        }),
      });
      expect(delivered.status).toBe(202);

      const update = await env.DB
        .prepare(
          `SELECT last_total_running AS lastTotal
             FROM push_endpoints
            WHERE client_id = ?1 AND surface = 'liveactivity-update'`,
        )
        .bind(client.clientId)
        .first();
      expect(Number(update.lastTotal)).toBe(1);
      const start = await env.DB
        .prepare(
          `SELECT last_sequence AS lastSequence, last_total_running AS lastTotal
             FROM push_endpoints
            WHERE client_id = ?1 AND surface = 'liveactivity-start'`,
        )
        .bind(client.clientId)
        .first();
      expect(Number(start.lastSequence)).toBe(-1);
      expect(Number(start.lastTotal)).toBe(0);
      await runInDurableObject(coordinator, async (_instance, durableState) => {
        const cached = await durableState.storage.get("recentAgentActivities");
        expect(cached[computer.computerId].activity.alert).toBe(false);
        expect(cached[computer.computerId].highPriority).toBe(false);
      });
    } finally {
      closeAll(host);
    }
  });

  test("aggregate state carries the retained agent envelopes for widgets", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const coordinator = env.PUSH_COORDINATOR.getByName(client.clientId);
    try {
      // No envelope before any agent activity.
      const plain = await state(client);
      expect(plain.recentAgent).toBeUndefined();
      expect(plain.moreAgents).toBeUndefined();

      expect(
        (await api("/v2/clients/me/push-endpoints/liveactivity-update", {
          method: "PUT",
          token: client.statusToken,
          body: {
            token: "bc".repeat(32),
            environment: "sandbox",
            activityId: "widget-test",
          },
        })).status,
      ).toBe(200);

      host.ws.send(
        snapshotWithAgents("Widget Mac", [], { running: 1, waiting: 0, done: 0 }),
      );
      await waitFor(async () => ((await state(client)).agentsRunning === 1 ? true : null));

      const updatedAt = Date.now();
      const delivered = await coordinator.fetch("https://push.internal/activity", {
        method: "POST",
        body: JSON.stringify({
          clientId: client.clientId,
          computerId: computer.computerId,
          activity: {
            eventID: "44444444-4444-4444-8444-444444444444",
            state: "running",
            updatedAt,
            alert: false,
            sealed: btoa("widget-ciphertext"),
          },
        }),
      });
      expect(delivered.status).toBe(202);

      const rich = await state(client);
      expect(rich.recentAgent).toEqual({
        computerID: computer.computerId,
        state: "running",
        updatedAt: new Date(Math.floor(updatedAt / 1000) * 1000)
          .toISOString()
          .replace(".000Z", "Z"),
        sealed: btoa("widget-ciphertext"),
      });
      expect(rich.moreAgents).toBeUndefined();

      // Once the counts return to zero the envelope is no longer attached.
      host.ws.send(
        snapshotWithAgents("Widget Mac", [], { running: 0, waiting: 0, done: 0 }),
      );
      await waitFor(async () => ((await state(client)).agentsRunning === 0 ? true : null));
      const drained = await state(client);
      expect(drained.recentAgent).toBeUndefined();
    } finally {
      closeAll(host);
    }
  });

  test("resuming a finished agent makes the silent working update high priority", async () => {
    const client = await createClient();
    const computer = await createComputer();
    const coordinator = env.PUSH_COORDINATOR.getByName(client.clientId);

    await runInDurableObject(coordinator, async (instance, durableState) => {
      const finished = {
        eventID: "66666666-6666-4666-8666-666666666666",
        state: "done",
        updatedAt: 1,
        alert: false,
        sealed: btoa("finished-ciphertext"),
      };
      expect(
        await instance.cacheAgentActivity(computer.computerId, finished, false),
      ).toBe(false);

      const resumed = {
        ...finished,
        eventID: "77777777-7777-4777-8777-777777777777",
        state: "running",
        updatedAt: 2,
        sealed: btoa("resumed-ciphertext"),
      };
      expect(
        await instance.cacheAgentActivity(computer.computerId, resumed, false),
      ).toBe(true);
      let cached = await durableState.storage.get("recentAgentActivities");
      expect(cached[computer.computerId].highPriority).toBe(true);

      await instance.markAgentActivityDelivered(
        computer.computerId,
        resumed.eventID,
      );
      const progress = {
        ...resumed,
        eventID: "88888888-8888-4888-8888-888888888888",
        updatedAt: 3,
      };
      expect(
        await instance.cacheAgentActivity(computer.computerId, progress, false),
      ).toBe(false);
      cached = await durableState.storage.get("recentAgentActivities");
      expect(cached[computer.computerId].highPriority).toBe(false);
    });
  });

  test("rich activity failure retains the encrypted card for a forced retry", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const coordinator = env.PUSH_COORDINATOR.getByName(client.clientId);
    try {
      host.ws.send(
        snapshotWithAgents("Retry Mac", [], { running: 1, waiting: 0, done: 0 }),
      );
      await waitFor(async () => ((await state(client)).agentsRunning === 1 ? true : null));
      expect(
        (await api("/v2/clients/me/push-endpoints/liveactivity-update", {
          method: "PUT",
          token: client.statusToken,
          body: {
            token: "fb".repeat(32),
            environment: "sandbox",
            activityId: "retry-rich-card",
          },
        })).status,
      ).toBe(200);

      const before = Date.now();
      const delivered = await coordinator.fetch("https://push.internal/activity", {
        method: "POST",
        body: JSON.stringify({
          clientId: client.clientId,
          computerId: computer.computerId,
          activity: {
            eventID: "55555555-5555-4555-8555-555555555555",
            state: "running",
            updatedAt: Date.now(),
            alert: false,
            sealed: btoa("retryable-agent-ciphertext"),
          },
        }),
      });
      expect(delivered.status).toBe(202);

      const endpoint = await env.DB
        .prepare(
          `SELECT retry_not_before AS retryNotBefore,
                  failure_count AS failureCount,
                  last_failure_reason AS lastFailureReason
             FROM push_endpoints
            WHERE client_id = ?1 AND surface = 'liveactivity-update'`,
        )
        .bind(client.clientId)
        .first();
      expect(Number(endpoint.failureCount)).toBe(1);
      expect(endpoint.lastFailureReason).toBe("TooManyRequests");
      expect(Number(endpoint.retryNotBefore) * 1000).toBeGreaterThanOrEqual(
        before + 3_599_000,
      );

      await runInDurableObject(coordinator, async (_instance, durableState) => {
        const cached = await durableState.storage.get("recentAgentActivities");
        expect(cached[computer.computerId].activity.eventID)
          .toBe("55555555-5555-4555-8555-555555555555");
        expect(cached[computer.computerId].highPriority).toBe(true);
      });
      // While an alarm invocation is in flight, pending/force sit in the
      // inflight keys and the alarm slot reads null, so wait for the settled
      // durable state (a backed-off delivery always restores both keys)
      // instead of asserting a mid-run snapshot.
      await waitFor(async () =>
        runInDurableObject(coordinator, async (_instance, durableState) => {
          const [pending, force] = await Promise.all([
            durableState.storage.get("pendingClientIds"),
            durableState.storage.get("forceClientIds"),
          ]);
          return JSON.stringify(pending) === JSON.stringify([client.clientId])
            && JSON.stringify(force) === JSON.stringify([client.clientId])
            ? true
            : null;
        }));
      // Run (or let the real firing run) the coalesced alarm; the delivery
      // finds the endpoint backed off and settles into the Retry-After
      // schedule with the forced client retained.
      await waitFor(async () => {
        try {
          await runDurableObjectAlarm(coordinator);
        } catch {
          return null; // collided with the real alarm invocation; re-check
        }
        return runInDurableObject(coordinator, async (_instance, durableState) => {
          const alarm = await durableState.storage.getAlarm();
          return alarm !== null && alarm >= before + 3_599_000 ? true : null;
        });
      });
      await runInDurableObject(coordinator, async (_instance, durableState) => {
        expect(await durableState.storage.getAlarm()).toBeGreaterThanOrEqual(
          before + 3_599_000,
        );
        expect(await durableState.storage.get("pendingClientIds"))
          .toEqual([client.clientId]);
      });
    } finally {
      closeAll(host);
    }
  });

  test("aggregate refresh preserves a recent agent card, then ends it", async () => {
    const computer = await createComputer();
    const client = await createClient();
    expect((await bind(client, computer)).status).toBe(201);
    const host = (await connect(computer.computerId, computer.hostToken)).peer;
    const coordinator = env.PUSH_COORDINATOR.getByName(client.clientId);
    try {
      host.ws.send(
        snapshotWithAgents("Island Mac", [], { running: 0, waiting: 0, done: 1 }),
      );
      const completed = await waitFor(async () => {
        const snapshot = await state(client);
        return snapshot.agentsDone === 1 ? snapshot : null;
      });
      expect(
        (await api("/v2/clients/me/push-endpoints/liveactivity-update", {
          method: "PUT",
          token: client.statusToken,
          body: {
            token: "1a".repeat(32),
            environment: "sandbox",
            activityId: "agent-only",
          },
        })).status,
      ).toBe(200);
      const delivered = await coordinator.fetch("https://push.internal/activity", {
        method: "POST",
        body: JSON.stringify({
          clientId: client.clientId,
          computerId: computer.computerId,
          activity: {
            eventID: "44444444-4444-4444-8444-444444444444",
            state: "done",
            updatedAt: Date.now(),
            alert: false,
            sealed: btoa("completed-agent-ciphertext"),
          },
        }),
      });
      expect(delivered.status).toBe(202);
      await drainCoordinator(coordinator);

      // A later TTY-only projection reuses the retained opaque envelope, so
      // the terminal count advances without replacing the rich agent card.
      host.ws.send(
        snapshotWithAgents(
          "Island Mac",
          runningSessions(1),
          { running: 0, waiting: 0, done: 1 },
        ),
      );
      const terminalChanged = await waitFor(async () => {
        const snapshot = await state(client);
        return snapshot.totalRunning === 1 && snapshot.sequence > completed.sequence
          ? snapshot
          : null;
      });
      // Wait on the delivered effect, not the alarm: the real coalescing
      // alarm may already have processed the invalidation.
      const active = await waitFor(async () => {
        try {
          await runDurableObjectAlarm(coordinator);
        } catch {
          return null; // collided with the real alarm invocation; re-check
        }
        const row = await env.DB
          .prepare(
            `SELECT last_sequence AS lastSequence, last_total_running AS lastTotal
               FROM push_endpoints
              WHERE client_id = ?1 AND surface = 'liveactivity-update'`,
          )
          .bind(client.clientId)
          .first();
        return row && Number(row.lastSequence) === terminalChanged.sequence ? row : null;
      });
      expect(Number(active.lastSequence)).toBe(terminalChanged.sequence);
      expect(Number(active.lastTotal)).toBe(2);
      expect(terminalChanged.sequence).toBeGreaterThan(completed.sequence);

      host.ws.send(
        snapshotWithAgents("Island Mac", [], { running: 0, waiting: 0, done: 0 }),
      );
      await waitFor(async () => ((await state(client)).agentsDone === 0 ? true : null));
      // Same race: wait for the end-event effect (endpoint deleted) however
      // the alarm got to run.
      await waitFor(async () => {
        try {
          await runDurableObjectAlarm(coordinator);
        } catch {
          return null; // collided with the real alarm invocation; re-check
        }
        const ended = await env.DB
          .prepare(
            `SELECT id FROM push_endpoints
              WHERE client_id = ?1 AND surface = 'liveactivity-update'`,
          )
          .bind(client.clientId)
          .first();
        return ended === null ? true : null;
      });
      await runInDurableObject(coordinator, async (_instance, durableState) => {
        expect(await durableState.storage.get("recentAgentActivities")).toBeUndefined();
      });
    } finally {
      closeAll(host);
    }
  });
});
