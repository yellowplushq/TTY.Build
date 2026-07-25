// APNs provider for the Cloudflare Workers runtime.
//
// This module intentionally exposes a very small, allow-listed surface. A
// caller chooses a Pedals surface, not arbitrary APNs headers or payloads, so
// a compromised database row cannot turn the relay into a general push proxy.

const TOKEN_MAX_AGE_SECONDS = 50 * 60;
const TOKEN_CLOCK_SKEW_SECONDS = 60;
const LIVE_ACTIVITY_STALE_SECONDS = 5 * 60;
const LIVE_ACTIVITY_EXPIRATION_SECONDS = 15 * 60;
const LIVE_ACTIVITY_END_EXPIRATION_SECONDS = 4 * 60 * 60;

export const LIVE_ACTIVITY_ATTRIBUTES_TYPE = "TTYActivityAttributes";

// Foundation's default Codable representation for Date is seconds since
// 2001-01-01. ActivityKit explicitly decodes content-state with the default
// strategies, so the ISO-8601 form used by the HTTP API must be converted.
const APPLE_REFERENCE_DATE_UNIX_SECONDS = 978_307_200;

export const APNS_SURFACES = Object.freeze({
  "ios-widget": Object.freeze({
    pushType: "widgets",
    topic: "air.build.pedals.push-type.widgets",
    priority: "10",
  }),
  "watch-widget": Object.freeze({
    pushType: "widgets",
    topic: "air.build.pedals.watchapp.push-type.widgets",
    priority: "10",
  }),
  "liveactivity-start": Object.freeze({
    pushType: "liveactivity",
    topic: "air.build.pedals.push-type.liveactivity",
    priority: "10",
  }),
  "liveactivity-update": Object.freeze({
    pushType: "liveactivity",
    topic: "air.build.pedals.push-type.liveactivity",
    priority: "5",
  }),
});

const AGENT_ACTIVITY_ALERTS = Object.freeze({
  running: "An agent started working",
  waiting: "An agent needs your input",
  error: "An agent hit an error",
  done: "An agent finished its task",
});

const INVALID_DEVICE_REASONS = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "Unregistered",
]);

const utf8 = new TextEncoder();

function requiredString(value, name) {
  if (typeof value !== "string" || value.trim() === "") {
    throw new TypeError(`${name} must be a non-empty string`);
  }
  return value.trim();
}

function base64Url(bytes) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

function decodePem(pem) {
  const normalized = requiredString(pem, "APNS_PRIVATE_KEY_P8").replaceAll(
    "\\n",
    "\n",
  );
  const match = normalized.match(
    /-----BEGIN PRIVATE KEY-----([\s\S]+?)-----END PRIVATE KEY-----/,
  );
  if (!match) {
    throw new TypeError("APNS_PRIVATE_KEY_P8 must be a PKCS#8 PEM private key");
  }

  const encoded = match[1].replace(/\s/g, "");
  try {
    return Uint8Array.from(atob(encoded), (character) =>
      character.charCodeAt(0),
    );
  } catch {
    throw new TypeError("APNS_PRIVATE_KEY_P8 contains invalid base64");
  }
}

function readDerLength(bytes, offset) {
  const first = bytes[offset];
  if (first === undefined) throw new TypeError("invalid ECDSA signature");
  if ((first & 0x80) === 0) return { length: first, next: offset + 1 };

  const count = first & 0x7f;
  if (count === 0 || count > 2 || offset + count >= bytes.length) {
    throw new TypeError("invalid ECDSA signature");
  }
  let length = 0;
  for (let index = 0; index < count; index += 1) {
    length = (length << 8) | bytes[offset + 1 + index];
  }
  return { length, next: offset + 1 + count };
}

function copyDerInteger(bytes, offset, output, outputOffset) {
  if (bytes[offset] !== 0x02) throw new TypeError("invalid ECDSA signature");
  const field = readDerLength(bytes, offset + 1);
  const end = field.next + field.length;
  if (end > bytes.length) throw new TypeError("invalid ECDSA signature");

  let start = field.next;
  while (start < end - 1 && bytes[start] === 0) start += 1;
  const length = end - start;
  if (length > 32) throw new TypeError("invalid ECDSA signature");
  output.set(bytes.subarray(start, end), outputOffset + 32 - length);
  return end;
}

// WebCrypto specifies the 64-byte IEEE-P1363 representation for ECDSA. The
// DER branch keeps the provider portable to compatible runtimes that still
// return an ASN.1 sequence.
function joseSignature(signature) {
  if (signature.length === 64) return signature;
  if (signature[0] !== 0x30) throw new TypeError("invalid ES256 signature");

  const sequence = readDerLength(signature, 1);
  if (sequence.next + sequence.length !== signature.length) {
    throw new TypeError("invalid ES256 signature");
  }
  const output = new Uint8Array(64);
  const second = copyDerInteger(signature, sequence.next, output, 0);
  const end = copyDerInteger(signature, second, output, 32);
  if (end !== signature.length) throw new TypeError("invalid ES256 signature");
  return output;
}

function cloneTokenCache(cache) {
  if (!cache) return null;
  return {
    token: cache.token,
    issuedAt: cache.issuedAt,
    keyId: cache.keyId,
    teamId: cache.teamId,
  };
}

function reusableToken(cache, keyId, teamId, nowSeconds) {
  return (
    cache &&
    typeof cache.token === "string" &&
    Number.isInteger(cache.issuedAt) &&
    cache.keyId === keyId &&
    cache.teamId === teamId &&
    nowSeconds >= cache.issuedAt - TOKEN_CLOCK_SKEW_SECONDS &&
    nowSeconds - cache.issuedAt < TOKEN_MAX_AGE_SECONDS
  );
}

/**
 * Return a cached APNs provider JWT or mint a new ES256 token.
 *
 * The returned cache contains no private-key material and may be retained by a
 * Durable Object between sends. `now` is milliseconds since the Unix epoch.
 */
export async function createProviderToken(
  env,
  { tokenCache = null, now = Date.now(), cryptoImpl = globalThis.crypto } = {},
) {
  if (!env || typeof env !== "object") throw new TypeError("env is required");
  const keyId = requiredString(env.APNS_KEY_ID, "APNS_KEY_ID");
  const teamId = requiredString(env.APNS_TEAM_ID, "APNS_TEAM_ID");
  if (!Number.isFinite(now)) throw new TypeError("now must be milliseconds");
  if (!cryptoImpl?.subtle) throw new TypeError("WebCrypto is unavailable");

  const issuedAt = Math.floor(now / 1000);
  if (reusableToken(tokenCache, keyId, teamId, issuedAt)) {
    const cache = cloneTokenCache(tokenCache);
    return { token: cache.token, tokenCache: cache };
  }

  const header = base64Url(utf8.encode(JSON.stringify({ alg: "ES256", kid: keyId })));
  const claims = base64Url(utf8.encode(JSON.stringify({ iss: teamId, iat: issuedAt })));
  const signingInput = `${header}.${claims}`;
  const privateKey = await cryptoImpl.subtle.importKey(
    "pkcs8",
    decodePem(env.APNS_PRIVATE_KEY_P8),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signed = new Uint8Array(
    await cryptoImpl.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      privateKey,
      utf8.encode(signingInput),
    ),
  );
  const token = `${signingInput}.${base64Url(joseSignature(signed))}`;
  return {
    token,
    tokenCache: { token, issuedAt, keyId, teamId },
  };
}

function plainObject(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`${name} must be an object`);
  }
  return value;
}

function rejectUnknownKeys(value, allowed, name) {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) throw new TypeError(`${name}.${key} is not allowed`);
  }
}

function liveActivityPayload(surface, value, now) {
  const payload = plainObject(value, "payload");
  rejectUnknownKeys(payload, new Set(["state", "event", "activity"]), "payload");
  const state = plainObject(payload.state, "payload.state");
  if (!Number.isSafeInteger(state.totalRunning) || state.totalRunning < 0) {
    throw new TypeError("payload.state.totalRunning must be a non-negative safe integer");
  }
  if (!Number.isSafeInteger(state.sequence) || state.sequence < 0) {
    throw new TypeError("payload.state.sequence must be a non-negative safe integer");
  }
  if (!Array.isArray(state.computers)) {
    throw new TypeError("payload.state.computers must be an array");
  }
  let onlineComputerCount = 0;
  for (const computer of state.computers) {
    if (!computer || typeof computer !== "object" || typeof computer.online !== "boolean") {
      throw new TypeError("payload.state.computers entries must contain online");
    }
    if (computer.online) onlineComputerCount += 1;
  }
  const updatedAtMilliseconds = Date.parse(state.updatedAt);
  if (!Number.isFinite(updatedAtMilliseconds)) {
    throw new TypeError("payload.state.updatedAt must be an ISO-8601 date");
  }

  const allowedEvents =
    surface === "liveactivity-start" ? new Set(["start"]) : new Set(["update", "end"]);
  if (!allowedEvents.has(payload.event)) {
    throw new TypeError(`payload.event is not valid for ${surface}`);
  }

  const agentCount = (value, name) => {
    if (value === undefined) return 0;
    if (!Number.isSafeInteger(value) || value < 0) {
      throw new TypeError(`${name} must be a non-negative safe integer`);
    }
    return value;
  };

  const aps = {
    timestamp: Math.floor(now / 1000),
    event: payload.event,
    "stale-date": Math.floor(updatedAtMilliseconds / 1000) + LIVE_ACTIVITY_STALE_SECONDS,
    "content-state": {
      totalRunning: state.totalRunning,
      agentsRunning: agentCount(state.agentsRunning, "payload.state.agentsRunning"),
      agentsWaiting: agentCount(state.agentsWaiting, "payload.state.agentsWaiting"),
      agentsDone: agentCount(state.agentsDone, "payload.state.agentsDone"),
      onlineComputerCount,
      offlineComputerCount: state.computers.length - onlineComputerCount,
      updatedAt: updatedAtMilliseconds / 1000 - APPLE_REFERENCE_DATE_UNIX_SECONDS,
      sequence: state.sequence,
    },
  };

  if (payload.activity !== undefined) {
    const activity = plainObject(payload.activity, "payload.activity");
    rejectUnknownKeys(
      activity,
      new Set(["eventID", "state", "updatedAt", "alert", "sealed", "computerId"]),
      "payload.activity",
    );
    if (!Object.hasOwn(AGENT_ACTIVITY_ALERTS, activity.state)) {
      if (activity.state !== "running") {
        throw new TypeError("payload.activity.state is invalid");
      }
    }
    if (!Number.isSafeInteger(activity.updatedAt) || activity.updatedAt < 0) {
      throw new TypeError("payload.activity.updatedAt must be a non-negative safe integer");
    }
    if (typeof activity.alert !== "boolean") {
      throw new TypeError("payload.activity.alert must be boolean");
    }
    const computerId = requiredString(activity.computerId, "payload.activity.computerId");
    const sealed = requiredString(activity.sealed, "payload.activity.sealed");
    if (sealed.length > 2700 || !/^[A-Za-z0-9+/]+={0,2}$/.test(sealed)) {
      throw new TypeError("payload.activity.sealed must be base64");
    }
    Object.assign(aps["content-state"], {
      recentAgentComputerID: computerId,
      recentAgentState: activity.state,
      recentAgentUpdatedAt:
        activity.updatedAt / 1000 - APPLE_REFERENCE_DATE_UNIX_SECONDS,
      recentAgentSealed: sealed,
    });
    // Apple requires every remote Live Activity start to include an alert.
    // A running agent uses that alert only for its first push-to-start; later
    // running updates remain silent because `activity.alert` stays false.
    if (activity.alert || surface === "liveactivity-start") {
      const body = AGENT_ACTIVITY_ALERTS[activity.state];
      if (!body) throw new TypeError("agent activity state cannot alert");
      aps.alert = { title: "Pedals", body };
    }
  }

  if (surface === "liveactivity-start") {
    aps["input-push-token"] = 1;
    aps["attributes-type"] = LIVE_ACTIVITY_ATTRIBUTES_TYPE;
    aps.attributes = { scope: "all" };
    if (!aps.alert) {
      throw new TypeError("liveactivity-start requires an alert");
    }
  }
  if (payload.event === "end") {
    aps["dismissal-date"] = Math.floor(now / 1000);
  }
  return { aps };
}

/** Build the only APNs payload accepted for a Pedals push surface. */
export function buildApnsPayload(surface, payload, now = Date.now()) {
  if (!Object.hasOwn(APNS_SURFACES, surface)) {
    throw new TypeError("endpoint.surface is not supported");
  }
  if (!Number.isFinite(now)) throw new TypeError("now must be milliseconds");

  if (surface === "ios-widget" || surface === "watch-widget") {
    if (payload !== undefined && payload !== null) {
      const value = plainObject(payload, "payload");
      rejectUnknownKeys(value, new Set(), "payload");
    }
    return { aps: { "content-changed": true } };
  }
  return liveActivityPayload(surface, payload, now);
}

export function classifyApnsResponse(status, reason = null) {
  if (status === 200) return "success";
  if (status === 410) return "invalidate";
  if (status === 400 && INVALID_DEVICE_REASONS.has(reason)) return "invalidate";
  if (status === 429 || (status >= 500 && status <= 599)) return "retry";
  return "fatal";
}

function endpointHost(environment) {
  if (environment === "sandbox") return "api.sandbox.push.apple.com";
  if (environment === "production") return "api.push.apple.com";
  throw new TypeError("endpoint.environment must be sandbox or production");
}

function expirationHeader(surface, payload, now) {
  if (surface !== "liveactivity-start" && surface !== "liveactivity-update") {
    return "0";
  }
  const lifetime =
    payload?.event === "end"
      ? LIVE_ACTIVITY_END_EXPIRATION_SECONDS
      : LIVE_ACTIVITY_EXPIRATION_SECONDS;
  return String(Math.floor(now / 1000) + lifetime);
}

async function responseDetails(response) {
  let body = null;
  try {
    const text = await response.text();
    if (text !== "") body = JSON.parse(text);
  } catch {
    // APNs error bodies are diagnostic only. HTTP status still determines a
    // safe fallback classification when the body is absent or malformed.
  }
  const reason = typeof body?.reason === "string" ? body.reason : null;
  return {
    reason,
    invalidatedAt: Number.isFinite(body?.timestamp) ? body.timestamp : null,
  };
}

/**
 * Construct a stateful APNs sender. The caller can restore `tokenCache` at
 * construction and persist the cache returned by every `send` result.
 */
export function createApnsClient(
  env,
  {
    fetchImpl = globalThis.fetch,
    now = () => Date.now(),
    cryptoImpl = globalThis.crypto,
    tokenCache: initialTokenCache = null,
  } = {},
) {
  if (typeof fetchImpl !== "function") throw new TypeError("fetch is unavailable");
  if (typeof now !== "function") throw new TypeError("now must be a function");
  let tokenCache = cloneTokenCache(initialTokenCache);

  return {
    get tokenCache() {
      return cloneTokenCache(tokenCache);
    },

    async send(endpoint, payload) {
      const value = plainObject(endpoint, "endpoint");
      const token = requiredString(value.token, "endpoint.token");
      if (token.length > 4096) throw new TypeError("endpoint.token is too long");
      const surface = requiredString(value.surface, "endpoint.surface");
      const config = APNS_SURFACES[surface];
      if (!config) throw new TypeError("endpoint.surface is not supported");
      const environment = value.environment ?? env?.APNS_ENVIRONMENT ?? "production";
      const host = endpointHost(environment);
      const sentAt = now();
      const body = buildApnsPayload(surface, payload, sentAt);
      const provider = await createProviderToken(env, {
        tokenCache,
        now: sentAt,
        cryptoImpl,
      });
      tokenCache = provider.tokenCache;

      const headers = {
        authorization: `bearer ${provider.token}`,
        "content-type": "application/json",
        "apns-push-type": config.pushType,
        "apns-topic": config.topic,
        "apns-priority":
          surface === "liveactivity-update" &&
          (
            payload?.event === "end" ||
            payload?.activity?.alert === true ||
            value.immediate === true
          )
            ? "10"
            : config.priority,
        // Non-zero expiration lets APNs retain ActivityKit transitions while
        // a device is briefly offline. End events live longer so an activity
        // cannot remain stranded; their past dismissal-date still removes the
        // UI immediately when delivery eventually succeeds.
        "apns-expiration": expirationHeader(surface, payload, sentAt),
      };
      if (value.apnsId !== undefined) {
        headers["apns-id"] = requiredString(value.apnsId, "endpoint.apnsId");
      }

      let response;
      try {
        response = await fetchImpl(
          `https://${host}/3/device/${encodeURIComponent(token)}`,
          {
            method: "POST",
            headers,
            body: JSON.stringify(body),
          },
        );
      } catch {
        return {
          ok: false,
          outcome: "retry",
          status: 0,
          reason: "NetworkError",
          apnsId: null,
          invalidatedAt: null,
          retryAfter: null,
          tokenCache: cloneTokenCache(tokenCache),
        };
      }

      const details = await responseDetails(response);
      let outcome = classifyApnsResponse(response.status, details.reason);
      if (
        details.reason === "ExpiredProviderToken" ||
        details.reason === "InvalidProviderToken"
      ) {
        tokenCache = null;
      }
      if (details.reason === "ExpiredProviderToken") outcome = "retry";
      return {
        ok: outcome === "success",
        outcome,
        status: response.status,
        reason: details.reason,
        apnsId: response.headers.get("apns-id"),
        invalidatedAt: details.invalidatedAt,
        retryAfter: response.headers.get("retry-after"),
        tokenCache: cloneTokenCache(tokenCache),
      };
    },
  };
}
