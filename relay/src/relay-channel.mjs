import { DurableObject } from "cloudflare:workers";
import { isId, notifyAgentActivity, writeDirectoryProjection } from "./core.mjs";

const HOST_TAG = "role:host";
const CLIENT_TAG = "role:client";
const CLOSE_REPLACED = 4000;
const CLOSE_BINDING_REVOKED = 4003;
const CLOSE_COMPUTER_REVOKED = 4004;
const CLOSE_DIRECTORY_LEASE_EXPIRED = 4005;
const OPEN = 1;
const HOST_NAME_MAX_LENGTH = 128;
const MAX_TEXT_BYTES = 16 * 1024;
const MAX_DIRECTORY_SESSIONS = 255;
const UINT32_MAX = 4_294_967_295;
const DIRECTORY_STORAGE_KEY = "terminal-directory";
const PROJECTION_RETRY_MS = 5_000;
export const HOST_DIRECTORY_LEASE_MS = 90_000;
export const HOST_DISCONNECT_GRACE_MS = 20_000;
export const MAX_BINARY_BYTES = 1024 * 1024;
const MAX_BUFFERED_BYTES = 4 * 1024 * 1024;
export const CLIENT_SOURCE_ENVELOPE_VERSION = 0x02;
export const CLIENT_SOURCE_PRINCIPAL_BYTES = 32;
export const CLIENT_SOURCE_ENVELOPE_BYTES = 1 + CLIENT_SOURCE_PRINCIPAL_BYTES;
export const MAX_CLIENT_ACTIVE_CHANNELS = 16;
export const MAX_HOST_ACTIVE_CHANNELS = 256;
// HTTP long-poll transport (watchOS cannot open WebSockets over the Bluetooth
// companion proxy; plain HTTP requests can). One poll session per
// client-principal+channel mirrors the one-socket-per-channel WebSocket rule.
export const HTTP_POLL_WAIT_MS = 20_000;
export const HTTP_SESSION_IDLE_MS = 60_000;
export const MAX_HTTP_QUEUE_BYTES = 2 * 1024 * 1024;
export const MAX_HTTP_QUEUE_MESSAGES = 256;
export const MAX_HTTP_BATCH_BYTES = 1024 * 1024;
export const MAX_HTTP_SEND_WIRES = 64;
const HTTP_SESSION_TOKEN = /^[0-9a-f]{32}$/;
const HTTP_POLL_AFTER = /^(0|[1-9]\d{0,15})$/;

const textEncoder = new TextEncoder();

function validHostName(value) {
  return (
    typeof value === "string" &&
    value === value.trim() &&
    value.length > 0 &&
    value.length <= HOST_NAME_MAX_LENGTH &&
    !/[\u0000-\u001f\u007f]/.test(value)
  );
}

function attachmentOf(ws) {
  try {
    const value = ws.deserializeAttachment();
    if (!value || value.v !== 3 || !isId(value.computerId)) return null;
    if (typeof value.channel !== "string" || !isId(value.principalId)) return null;
    if (value.role === "client") return value;
    if (value.role === "host" && typeof value.active === "boolean") return value;
  } catch {
    // A socket without a valid serialized identity is never trusted.
  }
  return null;
}

function canonicalDirectorySessions(value) {
  if (!Array.isArray(value) || value.length > MAX_DIRECTORY_SESSIONS) return null;
  const result = [];
  let previous = -1;
  for (const entry of value) {
    if (
      !entry ||
      Array.isArray(entry) ||
      Object.keys(entry).length !== 2 ||
      !Number.isSafeInteger(entry.id) ||
      entry.id < 0 ||
      entry.id > UINT32_MAX ||
      typeof entry.alive !== "boolean" ||
      entry.id <= previous
    ) {
      return null;
    }
    result.push({ id: entry.id, alive: entry.alive });
    previous = entry.id;
  }
  return result;
}

function sameSessions(lhs, rhs) {
  return lhs.length === rhs.length && lhs.every(
    (entry, index) => entry.id === rhs[index].id && entry.alive === rhs[index].alive,
  );
}

const MAX_AGENT_COUNT = 255;

function zeroAgentCounts() {
  return { running: 0, waiting: 0, done: 0 };
}

// Per-state coding-agent aggregate counts: the only agent-derived data the
// Worker ever sees (bare numbers; the rich list stays E2EE). Running and
// `done` is a short-lived completion projection. Absent on snapshots from
// older daemons (all-zero).
function canonicalAgentCounts(value, { lenient = false } = {}) {
  if (value === undefined) return zeroAgentCounts();
  if (!value || Array.isArray(value) || typeof value !== "object") return null;
  const keys = Object.keys(value);
  if (!lenient && keys.length !== 2 && keys.length !== 3) return null;
  for (const key of ["running", "waiting"]) {
    if (
      !Number.isSafeInteger(value[key]) ||
      value[key] < 0 ||
      value[key] > MAX_AGENT_COUNT
    ) {
      return null;
    }
  }
  const done = value.done ?? 0;
  if (!Number.isSafeInteger(done) || done < 0 || done > MAX_AGENT_COUNT) return null;
  if (!lenient && keys.some((key) => !["running", "waiting", "done"].includes(key))) {
    return null;
  }
  return { running: value.running, waiting: value.waiting, done };
}

function sameAgentCounts(lhs, rhs) {
  return lhs.running === rhs.running && lhs.waiting === rhs.waiting && lhs.done === rhs.done;
}

const ACTIVITY_EVENT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const ACTIVITY_SEALED = /^[A-Za-z0-9+/]+={0,2}$/;
const ACTIVITY_STATES = new Set(["running", "waiting", "error", "done"]);

function canonicalAgentActivity(value) {
  if (!value || Array.isArray(value) || typeof value !== "object") return null;
  if (
    Object.keys(value).length !== 5 ||
    !ACTIVITY_EVENT_ID.test(value.eventID) ||
    !ACTIVITY_STATES.has(value.state) ||
    !Number.isSafeInteger(value.updatedAt) || value.updatedAt < 0 ||
    typeof value.alert !== "boolean" ||
    typeof value.sealed !== "string" || value.sealed.length > 2_700 ||
    !ACTIVITY_SEALED.test(value.sealed) ||
    (value.alert && value.state === "running")
  ) {
    return null;
  }
  return value;
}

function emptyDirectory() {
  return {
    computerId: null,
    revision: 0,
    online: false,
    hostName: null,
    sessions: [],
    agents: zeroAgentCounts(),
    updatedAt: 0,
    deadlineAt: null,
    reason: null,
    projectionPending: false,
  };
}

function normalizedDirectory(value) {
  if (!value || typeof value !== "object") return emptyDirectory();
  const sessions = canonicalDirectorySessions(value.sessions);
  // Lenient: directories stored before the agents field existed normalize
  // to zero counts, and a stored shape from an older schema (extra keys)
  // must not reset the whole directory.
  const agents = canonicalAgentCounts(value.agents, { lenient: true });
  if (
    sessions === null ||
    agents === null ||
    !Number.isSafeInteger(value.revision) ||
    value.revision < 0 ||
    typeof value.online !== "boolean" ||
    (value.hostName !== null && !validHostName(value.hostName)) ||
    !Number.isSafeInteger(value.updatedAt) ||
    value.updatedAt < 0 ||
    (value.deadlineAt !== null && (!Number.isSafeInteger(value.deadlineAt) || value.deadlineAt < 0)) ||
    typeof value.projectionPending !== "boolean" ||
    (value.computerId !== null && !isId(value.computerId))
  ) {
    return emptyDirectory();
  }
  return {
    computerId: value.computerId,
    revision: value.revision,
    online: value.online,
    hostName: value.hostName,
    sessions: value.online ? sessions : [],
    agents: value.online ? agents : zeroAgentCounts(),
    updatedAt: value.updatedAt,
    deadlineAt: value.online ? value.deadlineAt : null,
    reason: typeof value.reason === "string" ? value.reason : null,
    projectionPending: value.projectionPending,
  };
}

function parseTrustedUpgrade(request) {
  if (
    request.method !== "GET" ||
    request.headers.get("upgrade")?.toLowerCase() !== "websocket"
  ) {
    return null;
  }
  const computerId = request.headers.get("x-pedals-computer-id");
  const channel = request.headers.get("x-pedals-channel");
  const role = request.headers.get("x-pedals-role");
  const principalId = request.headers.get("x-pedals-principal-id");
  if (
    !isId(computerId) ||
    !channel ||
    (role !== "host" && role !== "client") ||
    !isId(principalId)
  ) {
    return null;
  }
  return { computerId, channel, role, principalId };
}

function parseTrustedHttpOp(request) {
  const op = request.headers.get("x-pedals-http-op");
  if (op !== "poll" && op !== "send") return null;
  if (op === "poll" && request.method !== "GET") return null;
  if (op === "send" && request.method !== "POST") return null;
  const computerId = request.headers.get("x-pedals-computer-id");
  const channel = request.headers.get("x-pedals-channel");
  const role = request.headers.get("x-pedals-role");
  const principalId = request.headers.get("x-pedals-principal-id");
  // The HTTP transport exists for clients that cannot hold a WebSocket; hosts
  // always use sockets, so a host bearer on this surface is a protocol error.
  if (!isId(computerId) || !channel || role !== "client" || !isId(principalId)) {
    return null;
  }
  if (op === "send") {
    return { op, computerId, channel, role, principalId };
  }
  const token = request.headers.get("x-pedals-poll-session");
  if (typeof token !== "string" || !HTTP_SESSION_TOKEN.test(token)) return null;
  const afterHeader = request.headers.get("x-pedals-poll-after");
  let after = null;
  if (afterHeader !== null && afterHeader !== "") {
    if (!HTTP_POLL_AFTER.test(afterHeader)) return null;
    after = Number(afterHeader);
  }
  return { op, computerId, channel, role, principalId, token, after };
}

function base64FromBytes(bytes) {
  let binary = "";
  const chunk = 0x8000;
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk));
  }
  return btoa(binary);
}

function parseInternalAction(request) {
  if (request.method !== "POST") return null;
  const path = new URL(request.url).pathname;
  const computerId = request.headers.get("x-pedals-computer-id");
  if (!isId(computerId)) return null;
  if (path === "/internal/revoke-computer") {
    return { type: "computer", computerId };
  }
  const principalId = request.headers.get("x-pedals-principal-id");
  if (path === "/internal/revoke-client" && isId(principalId)) {
    return { type: "client", computerId, principalId };
  }
  return null;
}

function binaryView(message) {
  if (message instanceof ArrayBuffer) return new Uint8Array(message);
  if (ArrayBuffer.isView(message)) {
    return new Uint8Array(message.buffer, message.byteOffset, message.byteLength);
  }
  return null;
}

function authenticatedClientEnvelope(principalId, payload) {
  // principalId comes only from the serialized socket attachment populated
  // after the outer bearer has been authorized. Never parse a caller-supplied
  // prefix: a bound client must not be able to claim another client identity
  // inside the shared-secret E2EE hello.
  const principal = textEncoder.encode(principalId);
  if (principal.byteLength !== CLIENT_SOURCE_PRINCIPAL_BYTES) return null;
  const envelope = new Uint8Array(CLIENT_SOURCE_ENVELOPE_BYTES + payload.byteLength);
  envelope[0] = CLIENT_SOURCE_ENVELOPE_VERSION;
  envelope.set(principal, 1);
  envelope.set(payload, CLIENT_SOURCE_ENVELOPE_BYTES);
  return envelope;
}

export class RelayChannel extends DurableObject {
  retiredSockets = new WeakSet();
  directoryTaskTail = Promise.resolve();
  // key `${principalId}:${channel}` -> in-memory long-poll session. Lives and
  // dies with the isolate: an evicted queue surfaces as `reset` on the next
  // poll and the client redoes its E2EE handshake, exactly like a WebSocket
  // reconnect.
  httpSessions = new Map();

  constructor(ctx, env) {
    super(ctx, env);
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    const action = parseInternalAction(request);
    if (action) {
      return this.ctx.blockConcurrencyWhile(async () => this.applyRevocation(action));
    }

    const httpOp = parseTrustedHttpOp(request);
    if (httpOp) {
      // Same revocation-race recheck as the upgrade path, but only the auth
      // lookup may block the actor: a parked long-poll must keep receiving
      // host events, so it waits outside blockConcurrencyWhile.
      const authorized = await this.ctx.blockConcurrencyWhile(async () =>
        this.identityStillAuthorized(httpOp),
      );
      if (!authorized) return new Response("unauthorized", { status: 401 });
      this.sweepHttpSessions();
      return httpOp.op === "send"
        ? await this.handleHttpSend(httpOp, request)
        : await this.handleHttpPoll(httpOp);
    }

    const identity = parseTrustedUpgrade(request);
    if (!identity) return new Response("bad request", { status: 400 });

    // Recheck inside the same per-computer actor that processes revocations.
    // This closes the race where outer Worker auth succeeds just before a D1
    // binding/computer deletion, but the upgrade reaches the actor afterward.
    return this.ctx.blockConcurrencyWhile(async () => {
      if (!(await this.identityStillAuthorized(identity))) {
        return new Response("unauthorized", { status: 401 });
      }
      return await this.acceptConnection(identity);
    });
  }

  async identityStillAuthorized(identity) {
    if (identity.role === "host") {
      const row = await this.env.DB
        .prepare(`SELECT 1 FROM computers WHERE id = ?1 AND revoked_at IS NULL`)
        .bind(identity.computerId)
        .first();
      return Boolean(row);
    }
    const row = await this.env.DB
      .prepare(
        `SELECT 1
           FROM client_computers b
           JOIN clients c ON c.id = b.client_id
           JOIN computers h ON h.id = b.computer_id
          WHERE b.client_id = ?1
            AND b.computer_id = ?2
            AND c.revoked_at IS NULL
            AND h.revoked_at IS NULL`,
      )
      .bind(identity.principalId, identity.computerId)
      .first();
    return Boolean(row);
  }

  async acceptConnection(identity) {
    const channelLimit =
      identity.role === "client" ? MAX_CLIENT_ACTIVE_CHANNELS : MAX_HOST_ACTIVE_CHANNELS;
    const activeChannels = this.activeChannelsForPrincipal(identity);
    if (!activeChannels.has(identity.channel) && activeChannels.size >= channelLimit) {
      return new Response("active relay channel limit exceeded", {
        status: 429,
        headers: { "retry-after": "60" },
      });
    }

    const [client, server] = Object.values(new WebSocketPair());
    const baseAttachment = {
      v: 3,
      role: identity.role,
      computerId: identity.computerId,
      channel: identity.channel,
      principalId: identity.principalId,
    };

    if (identity.role === "host") {
      const previousHosts = this.socketsFor(HOST_TAG, identity.channel);
      const wasOnline = previousHosts.some((ws) => this.isActiveHostSlot(ws));

      this.ctx.acceptWebSocket(server, [HOST_TAG]);
      if (!this.safeSerialize(server, { ...baseAttachment, active: true })) {
        this.safeClose(server, 1011, "relay state unavailable");
        return new Response(null, { status: 101, webSocket: client });
      }

      for (const previous of previousHosts) {
        this.retiredSockets.add(previous);
        const state = attachmentOf(previous);
        if (state?.role === "host") {
          this.safeSerialize(previous, { ...state, active: false });
        }
      }
      for (const previous of previousHosts) {
        this.safeClose(previous, CLOSE_REPLACED, "replaced by new connection");
      }
      if (identity.channel !== "control" && !wasOnline) {
        this.notifyChannelClients(identity.channel, true);
      }
      if (identity.channel === "control") {
        await this.extendDirectoryForHostHandshake();
      }
    } else {
      // One socket per logical client/channel bounds amplification while still
      // allowing the control channel and independent session channels.
      for (const previous of this.socketsFor(CLIENT_TAG, identity.channel)) {
        const state = attachmentOf(previous);
        if (state?.principalId === identity.principalId) {
          this.safeClose(previous, CLOSE_REPLACED, "replaced by new connection");
        }
      }
      this.ctx.acceptWebSocket(server, [CLIENT_TAG]);
      if (!this.safeSerialize(server, baseAttachment)) {
        this.safeClose(server, 1011, "relay state unavailable");
        return new Response(null, { status: 101, webSocket: client });
      }
      if (identity.channel === "control") {
        this.safeSend(server, this.directoryMessage(await this.loadDirectory()));
      } else {
        this.safeSend(server, this.channelState(this.hasActiveHostSlot(identity.channel)));
      }
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws, message) {
    const state = attachmentOf(ws);
    if (!state) {
      this.retireSocket(ws, 1011, "invalid relay state");
      return;
    }

    if (typeof message === "string") {
      if (
        message.length > MAX_TEXT_BYTES ||
        new TextEncoder().encode(message).byteLength > MAX_TEXT_BYTES
      ) {
        this.retireSocket(ws, 1009, "relay metadata too large");
        return;
      }
      if (state.role === "host" && state.active && state.channel === "control") {
        this.handleHostMetadata(ws, state, message);
      }
      return;
    }
    const binary = binaryView(message);
    if (!binary) {
      this.retireSocket(ws, 1003, "unsupported relay frame");
      return;
    }
    if (binary.byteLength > MAX_BINARY_BYTES) {
      this.retireSocket(ws, 1009, "relay frame too large");
      return;
    }

    if (state.role === "host") {
      if (!state.active) return;
      for (const client of this.socketsFor(CLIENT_TAG, state.channel)) {
        this.safeSend(client, message);
      }
      this.enqueueHttpBinary(state.channel, binary);
      return;
    }

    const host = this.activeHostForSend(state.channel);
    if (host) {
      const envelope = authenticatedClientEnvelope(state.principalId, binary);
      if (!envelope) {
        this.retireSocket(ws, 1011, "invalid relay principal");
        return;
      }
      this.safeSend(host, envelope);
    }
  }

  webSocketClose(ws) {
    this.deactivateHost(ws);
  }

  webSocketError(ws) {
    this.deactivateHost(ws);
    this.safeClose(ws, 1011, "websocket error");
  }

  handleHostMetadata(ws, state, message) {
    let value;
    try {
      value = JSON.parse(message);
    } catch {
      this.retireSocket(ws, 1008, "invalid host metadata");
      return;
    }
    if (!value || Array.isArray(value) || typeof value.type !== "string") {
      this.retireSocket(ws, 1008, "invalid host metadata");
      return;
    }
    if (value.type === "host-snapshot") {
      const sessions = canonicalDirectorySessions(value.sessions);
      // `agents` is optional so pre-agent daemons keep working; when present
      // the snapshot has exactly {type, hostName, sessions, agents}.
      const expectedKeys = value.agents === undefined ? 3 : 4;
      const agents = canonicalAgentCounts(value.agents);
      if (
        Object.keys(value).length !== expectedKeys ||
        !validHostName(value.hostName) ||
        sessions === null ||
        agents === null
      ) {
        this.retireSocket(ws, 1008, "invalid host snapshot");
        return;
      }
      this.enqueueDirectoryTask(() =>
        this.applyHostSnapshot(ws, state, value.hostName, sessions, agents));
      return;
    }
    if (value.type === "agent-activity") {
      const activity = canonicalAgentActivity(value.activity);
      if (Object.keys(value).length !== 2 || activity === null) {
        this.retireSocket(ws, 1008, "invalid agent activity");
        return;
      }
      this.enqueueDirectoryTask(async () => {
        if (!this.isActiveHostSlot(ws) || this.activeHostForSend("control") !== ws) return;
        await notifyAgentActivity(this.env, state.computerId, activity);
      });
      return;
    }
    if (value.type === "host-offline" && Object.keys(value).length === 1) {
      this.enqueueDirectoryTask(() => this.markDirectoryOffline(
        ws,
        state,
        "host-requested",
      ));
      return;
    }
    this.retireSocket(ws, 1008, "unsupported host metadata");
  }

  enqueueDirectoryTask(operation) {
    const task = this.directoryTaskTail.then(operation, operation);
    this.directoryTaskTail = task.catch(() => undefined);
    this.ctx.waitUntil(
      task.catch((error) => {
        console.error("terminal directory update failed", error instanceof Error ? error.message : error);
      }),
    );
  }

  async loadDirectory() {
    return normalizedDirectory(await this.ctx.storage.get(DIRECTORY_STORAGE_KEY));
  }

  async storeDirectory(directory) {
    await this.ctx.storage.put(DIRECTORY_STORAGE_KEY, directory);
    if (directory.projectionPending) {
      const retryAt = Date.now() + PROJECTION_RETRY_MS;
      await this.ctx.storage.setAlarm(
        directory.online && directory.deadlineAt !== null
          ? Math.min(retryAt, directory.deadlineAt)
          : retryAt,
      );
    } else if (directory.online && directory.deadlineAt !== null) {
      await this.ctx.storage.setAlarm(directory.deadlineAt);
    } else {
      await this.ctx.storage.deleteAlarm();
    }
  }

  async extendDirectoryForHostHandshake() {
    const current = await this.loadDirectory();
    if (!current.online) return;
    const deadlineAt = Date.now() + HOST_DISCONNECT_GRACE_MS;
    await this.storeDirectory({ ...current, deadlineAt });
  }

  async applyHostSnapshot(ws, state, hostName, sessions, agents) {
    if (!this.isActiveHostSlot(ws) || this.activeHostForSend("control") !== ws) return;
    const current = await this.loadDirectory();
    const changed =
      !current.online ||
      current.hostName !== hostName ||
      !sameSessions(current.sessions, sessions) ||
      !sameAgentCounts(current.agents, agents);
    const next = {
      computerId: state.computerId,
      revision: changed ? current.revision + 1 : current.revision,
      online: true,
      hostName,
      sessions,
      agents,
      updatedAt: changed ? Math.floor(Date.now() / 1000) : current.updatedAt,
      deadlineAt: Date.now() + HOST_DIRECTORY_LEASE_MS,
      reason: null,
      projectionPending: changed || current.projectionPending,
    };
    await this.storeDirectory(next);
    if (changed) this.notifyControlClients(next);
    if (next.projectionPending) await this.reconcileDirectoryProjection(next);
  }

  async markDirectoryOffline(ws, state, reason) {
    if (ws && (!this.isActiveHostSlot(ws) || this.activeHostForSend("control") !== ws)) return;
    const current = await this.loadDirectory();
    if (!current.online && current.sessions.length === 0) {
      if (current.projectionPending) await this.reconcileDirectoryProjection(current);
      return;
    }
    const next = {
      computerId: state.computerId,
      revision: current.revision + 1,
      online: false,
      hostName: current.hostName,
      sessions: [],
      agents: zeroAgentCounts(),
      updatedAt: Math.floor(Date.now() / 1000),
      deadlineAt: null,
      reason,
      projectionPending: true,
    };
    await this.storeDirectory(next);
    this.notifyControlClients(next);
    await this.reconcileDirectoryProjection(next);
  }

  async reconcileDirectoryProjection(directory) {
    if (!isId(directory.computerId)) return;
    await writeDirectoryProjection(this.env, directory.computerId, {
      online: directory.online,
      runningTerminalCount: directory.online
        ? directory.sessions.filter((entry) => entry.alive).length
        : 0,
      agents: directory.online ? directory.agents : zeroAgentCounts(),
      hostName: directory.hostName ?? undefined,
    });
    await this.storeDirectory({ ...directory, projectionPending: false });
  }

  async scheduleDisconnectGrace(state) {
    if (this.hasActiveHostSlot("control")) return;
    const current = await this.loadDirectory();
    if (!current.online) return;
    await this.storeDirectory({
      ...current,
      deadlineAt: Date.now() + HOST_DISCONNECT_GRACE_MS,
      reason: "connection-lost",
    });
  }

  async alarm() {
    await this.directoryTaskTail.catch(() => undefined);
    let current = await this.loadDirectory();
    if (current.projectionPending) {
      try {
        await this.reconcileDirectoryProjection(current);
      } catch (error) {
        await this.ctx.storage.setAlarm(Date.now() + PROJECTION_RETRY_MS);
        throw error;
      }
      current = await this.loadDirectory();
    }
    if (!current.online || current.deadlineAt === null) return;
    if (Date.now() < current.deadlineAt) {
      await this.ctx.storage.setAlarm(current.deadlineAt);
      return;
    }
    const host = this.activeHostForSend("control");
    const state = host ? attachmentOf(host) : { computerId: current.computerId };
    if (!isId(state?.computerId)) return;
    if (host) this.retireSocket(host, CLOSE_DIRECTORY_LEASE_EXPIRED, "directory lease expired");
    await this.markDirectoryOffline(null, state, host ? "lease-expired" : "connection-lost");
  }

  socketsFor(tag, channel) {
    return this.ctx
      .getWebSockets(tag)
      .filter((ws) => attachmentOf(ws)?.channel === channel);
  }

  activeChannelsForPrincipal(identity) {
    const tag = identity.role === "host" ? HOST_TAG : CLIENT_TAG;
    const channels = new Set();
    for (const ws of this.ctx.getWebSockets(tag)) {
      if (ws.readyState !== OPEN) continue;
      const state = attachmentOf(ws);
      if (
        state?.role === identity.role &&
        state.principalId === identity.principalId &&
        (state.role !== "host" || state.active)
      ) {
        channels.add(state.channel);
      }
    }
    return channels;
  }

  isActiveHostSlot(ws) {
    if (this.retiredSockets.has(ws)) return false;
    const state = attachmentOf(ws);
    return state?.role === "host" && state.active;
  }

  hasActiveHostSlot(channel, excluding = null) {
    return this.socketsFor(HOST_TAG, channel).some(
      (ws) => ws !== excluding && this.isActiveHostSlot(ws),
    );
  }

  activeHostForSend(channel) {
    return (
      this.socketsFor(HOST_TAG, channel).find(
        (ws) => ws.readyState === OPEN && this.isActiveHostSlot(ws),
      ) ?? null
    );
  }

  deactivateHost(ws) {
    if (this.retiredSockets.has(ws)) return false;
    const state = attachmentOf(ws);
    if (state?.role !== "host" || !state.active) return false;

    this.retiredSockets.add(ws);
    this.safeSerialize(ws, { ...state, active: false });
    if (!this.hasActiveHostSlot(state.channel, ws)) {
      if (state.channel === "control") {
        this.enqueueDirectoryTask(() => this.scheduleDisconnectGrace(state));
      } else {
        this.notifyChannelClients(state.channel, false);
      }
    }
    return true;
  }

  async applyRevocation(action) {
    let closed = 0;
    for (const ws of [
      ...this.ctx.getWebSockets(HOST_TAG),
      ...this.ctx.getWebSockets(CLIENT_TAG),
    ]) {
      const state = attachmentOf(ws);
      if (!state || state.computerId !== action.computerId) continue;
      if (action.type === "client") {
        if (state.role !== "client" || state.principalId !== action.principalId) continue;
        this.safeClose(ws, CLOSE_BINDING_REVOKED, "binding revoked");
      } else {
        if (state.role === "host") {
          this.retiredSockets.add(ws);
          this.safeSerialize(ws, { ...state, active: false });
        }
        this.safeClose(ws, CLOSE_COMPUTER_REVOKED, "computer revoked");
      }
      closed += 1;
    }
    for (const session of [...this.httpSessions.values()]) {
      if (action.type === "client" && session.principalId !== action.principalId) {
        continue;
      }
      this.destroyHttpSession(session, new Response("unauthorized", { status: 401 }));
      closed += 1;
    }
    if (action.type === "computer") {
      await this.ctx.storage.delete(DIRECTORY_STORAGE_KEY);
      await this.ctx.storage.deleteAlarm();
    }
    return new Response(null, {
      status: 204,
      headers: { "x-pedals-closed-sockets": String(closed) },
    });
  }

  retireSocket(ws, code, reason) {
    this.deactivateHost(ws);
    this.safeClose(ws, code, reason);
  }

  safeSend(ws, message) {
    if (ws.readyState !== OPEN) return false;
    if (Number(ws.bufferedAmount ?? 0) > MAX_BUFFERED_BYTES) {
      this.retireSocket(ws, 1013, "relay backpressure");
      return false;
    }
    try {
      ws.send(message);
      return true;
    } catch {
      this.retireSocket(ws, 1011, "relay send failed");
      return false;
    }
  }

  safeClose(ws, code, reason) {
    try {
      if (ws.readyState === OPEN) ws.close(code, reason);
    } catch {
      // The peer may already have disappeared.
    }
  }

  safeSerialize(ws, value) {
    try {
      ws.serializeAttachment(value);
      return true;
    } catch {
      return false;
    }
  }

  channelState(online) {
    return JSON.stringify({ type: "channel-state", online });
  }

  directoryMessage(directory) {
    return JSON.stringify({
      type: "terminal-directory",
      revision: directory.revision,
      online: directory.online,
      hostName: directory.hostName,
      sessions: directory.online ? directory.sessions : [],
      updatedAt: directory.updatedAt,
      ...(directory.reason === null ? {} : { reason: directory.reason }),
    });
  }

  notifyControlClients(directory) {
    const notice = this.directoryMessage(directory);
    for (const client of this.socketsFor(CLIENT_TAG, "control")) {
      this.safeSend(client, notice);
    }
    this.enqueueHttpText("control", notice);
  }

  notifyChannelClients(channel, online) {
    const notice = this.channelState(online);
    for (const client of this.socketsFor(CLIENT_TAG, channel)) {
      this.safeSend(client, notice);
    }
    this.enqueueHttpText(channel, notice);
  }

  // HTTP long-poll transport

  async handleHttpPoll(op) {
    const key = `${op.principalId}:${op.channel}`;
    const existing = this.httpSessions.get(key);
    if (existing && existing.token === op.token) {
      existing.expiresAt = Date.now() + HTTP_SESSION_IDLE_MS;
      if (op.after !== null) this.ackHttpEntries(existing, op.after);
      if (existing.entries.length > 0) return this.httpBatchResponse(existing);
      return await this.parkHttpWaiter(existing);
    }
    if (op.after !== null) {
      // The queue this cursor belongs to is gone (evicted isolate, idle
      // expiry, or replacement). The client must redo its E2EE handshake.
      return Response.json({ reset: true });
    }
    if (existing) {
      // One poll session per client principal and channel, mirroring the
      // WebSocket replacement rule.
      this.destroyHttpSession(existing, Response.json({ reset: true }));
    } else {
      let held = 0;
      for (const session of this.httpSessions.values()) {
        if (session.principalId === op.principalId) held += 1;
      }
      if (held >= MAX_CLIENT_ACTIVE_CHANNELS) {
        return new Response("active relay channel limit exceeded", {
          status: 429,
          headers: { "retry-after": "60" },
        });
      }
    }
    const session = {
      key,
      token: op.token,
      principalId: op.principalId,
      channel: op.channel,
      computerId: op.computerId,
      entries: [],
      lastSeq: 0,
      queuedBytes: 0,
      waiter: null,
      expiresAt: Date.now() + HTTP_SESSION_IDLE_MS,
    };
    this.httpSessions.set(key, session);
    const initial = op.channel === "control"
      ? this.directoryMessage(await this.loadDirectory())
      : this.channelState(this.hasActiveHostSlot(op.channel));
    this.enqueueHttpEntry(session, "t", initial);
    return this.httpBatchResponse(session);
  }

  async handleHttpSend(op, request) {
    const body = new Uint8Array(await request.arrayBuffer());
    if (body.byteLength > MAX_BINARY_BYTES + 4 * MAX_HTTP_SEND_WIRES) {
      return new Response("payload too large", { status: 413 });
    }
    const view = new DataView(body.buffer, body.byteOffset, body.byteLength);
    const wires = [];
    let offset = 0;
    while (offset < body.byteLength) {
      if (offset + 4 > body.byteLength || wires.length >= MAX_HTTP_SEND_WIRES) {
        return new Response("malformed wire batch", { status: 400 });
      }
      const length = view.getUint32(offset);
      offset += 4;
      if (
        length === 0 ||
        length > MAX_BINARY_BYTES ||
        offset + length > body.byteLength
      ) {
        return new Response("malformed wire batch", { status: 400 });
      }
      wires.push(body.subarray(offset, offset + length));
      offset += length;
    }
    if (wires.length === 0) {
      return new Response("malformed wire batch", { status: 400 });
    }
    const host = this.activeHostForSend(op.channel);
    if (host) {
      for (const wire of wires) {
        const envelope = authenticatedClientEnvelope(op.principalId, wire);
        if (!envelope) return new Response("invalid relay principal", { status: 400 });
        this.safeSend(host, envelope);
      }
    }
    return new Response(null, { status: 204 });
  }

  enqueueHttpText(channel, text) {
    for (const session of this.httpSessionsFor(channel)) {
      this.enqueueHttpEntry(session, "t", text);
    }
  }

  enqueueHttpBinary(channel, bytes) {
    const sessions = this.httpSessionsFor(channel);
    if (sessions.length === 0) return;
    // Detach from the WebSocket message buffer before queueing.
    const copy = new Uint8Array(bytes);
    for (const session of sessions) {
      this.enqueueHttpEntry(session, "b", copy);
    }
  }

  httpSessionsFor(channel) {
    const matched = [];
    for (const session of this.httpSessions.values()) {
      if (session.channel === channel) matched.push(session);
    }
    return matched;
  }

  enqueueHttpEntry(session, kind, data) {
    session.lastSeq += 1;
    session.entries.push({ seq: session.lastSeq, kind, data });
    session.queuedBytes += kind === "b" ? data.byteLength : data.length;
    if (
      session.entries.length > MAX_HTTP_QUEUE_MESSAGES ||
      session.queuedBytes > MAX_HTTP_QUEUE_BYTES
    ) {
      // A reader this far behind cannot be caught up losslessly; force a
      // fresh handshake instead of silently dropping frames.
      this.destroyHttpSession(session, Response.json({ reset: true }));
      return;
    }
    if (session.waiter) {
      session.expiresAt = Date.now() + HTTP_SESSION_IDLE_MS;
      this.resolveHttpWaiter(session, this.httpBatchResponse(session));
    }
  }

  ackHttpEntries(session, after) {
    let removed = 0;
    while (
      removed < session.entries.length &&
      session.entries[removed].seq <= after
    ) {
      const entry = session.entries[removed];
      session.queuedBytes -= entry.kind === "b" ? entry.data.byteLength : entry.data.length;
      removed += 1;
    }
    if (removed > 0) session.entries.splice(0, removed);
  }

  httpBatchResponse(session) {
    const messages = [];
    let batchBytes = 0;
    let next = null;
    for (const entry of session.entries) {
      const size = entry.kind === "b" ? entry.data.byteLength : entry.data.length;
      if (messages.length > 0 && batchBytes + size > MAX_HTTP_BATCH_BYTES) break;
      messages.push(
        entry.kind === "b" ? { b: base64FromBytes(entry.data) } : { t: entry.data },
      );
      batchBytes += size;
      next = entry.seq;
    }
    return Response.json(next === null ? { messages } : { next, messages });
  }

  parkHttpWaiter(session) {
    if (session.waiter) {
      // A concurrent poll for the same session supersedes the parked one.
      this.resolveHttpWaiter(session, Response.json({ messages: [] }));
    }
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        session.waiter = null;
        session.expiresAt = Date.now() + HTTP_SESSION_IDLE_MS;
        resolve(Response.json({ messages: [] }));
      }, HTTP_POLL_WAIT_MS);
      session.waiter = { resolve, timer };
    });
  }

  resolveHttpWaiter(session, response) {
    const waiter = session.waiter;
    if (!waiter) return;
    session.waiter = null;
    clearTimeout(waiter.timer);
    waiter.resolve(response);
  }

  destroyHttpSession(session, response) {
    if (this.httpSessions.get(session.key) === session) {
      this.httpSessions.delete(session.key);
    }
    this.resolveHttpWaiter(session, response);
  }

  sweepHttpSessions() {
    const now = Date.now();
    for (const session of [...this.httpSessions.values()]) {
      if (session.waiter === null && session.expiresAt < now) {
        this.destroyHttpSession(session, Response.json({ reset: true }));
      }
    }
  }
}
