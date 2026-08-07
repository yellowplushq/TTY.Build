import { DurableObject } from "cloudflare:workers";
import { createApnsClient } from "./apns.mjs";
import { aggregateClientState, isId } from "./core.mjs";

const PENDING_KEY = "pendingClientIds";
const FORCE_KEY = "forceClientIds";
const INFLIGHT_KEY = "inflightClientIds";
const INFLIGHT_FORCE_KEY = "inflightForceClientIds";
const TOKEN_CACHE_KEY = "apnsProviderToken";
const RECENT_AGENT_ACTIVITIES_KEY = "recentAgentActivities";
const COALESCE_MILLISECONDS = 150;
const RETRY_MILLISECONDS = 15 * 60_000;
const FATAL_RETRY_MILLISECONDS = 24 * 60 * 60_000;
const MINIMUM_RETRY_MILLISECONDS = 60_000;
const MAXIMUM_RETRY_MILLISECONDS = 24 * 60 * 60_000;
const WATCHDOG_MILLISECONDS = 60_000;
// A Live Activity push is capped at 4 KiB. Extra per-computer envelopes only
// ride along while the base64 total stays inside this budget, which leaves
// roughly 700 bytes for counts, keys, and the alert.
const SEALED_BUDGET_CHARACTERS = 3_400;
const MAX_EXTRA_ACTIVITIES = 1;

/// The additional per-computer envelopes (beyond the primary) that fit the
/// payload budget, newest first. Old daemons send envelopes near the 2700-
/// character cap; those simply leave no room and degrade to today's
/// single-envelope push.
function packExtraActivities(primaryActivity, others) {
  const extras = [];
  let used = primaryActivity.sealed.length;
  for (const entry of others) {
    if (extras.length >= MAX_EXTRA_ACTIVITIES) break;
    if (used + entry.activity.sealed.length > SEALED_BUDGET_CHARACTERS) continue;
    used += entry.activity.sealed.length;
    extras.push({
      computerId: entry.computerId,
      state: entry.activity.state,
      updatedAt: entry.activity.updatedAt,
      sealed: entry.activity.sealed,
    });
  }
  return extras;
}

function mergeIds(previous, incoming) {
  return [...new Set([...(previous ?? []), ...(incoming ?? [])])].filter(isId);
}

function fingerprint(state) {
  return JSON.stringify(state);
}

async function deliveryApnsId(endpointId, deliveryKey, event) {
  const digest = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(`${endpointId}:${deliveryKey}:${event}`),
    ),
  ).slice(0, 16);
  digest[6] = (digest[6] & 0x0f) | 0x40;
  digest[8] = (digest[8] & 0x3f) | 0x80;
  const hex = [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function retryAtFromHeader(value, now = Date.now()) {
  if (typeof value !== "string" || value.trim() === "") {
    return now + RETRY_MILLISECONDS;
  }
  const trimmed = value.trim();
  let candidate;
  if (/^\d+$/.test(trimmed)) {
    candidate = now + Number(trimmed) * 1000;
  } else {
    candidate = Date.parse(trimmed);
  }
  if (!Number.isFinite(candidate) || candidate <= now) {
    return now + RETRY_MILLISECONDS;
  }
  return Math.min(
    now + MAXIMUM_RETRY_MILLISECONDS,
    Math.max(now + MINIMUM_RETRY_MILLISECONDS, candidate),
  );
}

function earlier(first, second) {
  if (!Number.isFinite(first)) return second;
  if (!Number.isFinite(second)) return first;
  return Math.min(first, second);
}

export class PushCoordinator extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx = ctx;
    this.env = env;
  }

  async fetch(request) {
    const pathname = new URL(request.url).pathname;
    if (request.method === "POST" && pathname === "/activity") {
      return this.handleActivity(request);
    }
    if (request.method !== "POST" || pathname !== "/invalidate") {
      return new Response("not found", { status: 404 });
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return new Response("bad request", { status: 400 });
    }
    if (!Array.isArray(body.clientIds) || body.clientIds.some((id) => !isId(id))) {
      return new Response("bad request", { status: 400 });
    }

    await this.ctx.blockConcurrencyWhile(async () => {
      const pending = await this.ctx.storage.get(PENDING_KEY);
      await this.ctx.storage.put(PENDING_KEY, mergeIds(pending, body.clientIds));
      if (body.force === true) {
        const forced = await this.ctx.storage.get(FORCE_KEY);
        await this.ctx.storage.put(FORCE_KEY, mergeIds(forced, body.clientIds));
      }
      const alarm = await this.ctx.storage.getAlarm();
      const desired = Date.now() + COALESCE_MILLISECONDS;
      if (alarm === null || alarm > desired) await this.ctx.storage.setAlarm(desired);
    });
    return new Response(null, { status: 202 });
  }

  async cacheAgentActivity(computerId, activity, highPriority) {
    return this.ctx.blockConcurrencyWhile(async () => {
      const cached = await this.ctx.storage.get(RECENT_AGENT_ACTIVITIES_KEY);
      const activities = cached && typeof cached === "object" && !Array.isArray(cached)
        ? cached
        : {};
      // Aggregate active count does not change for done/waiting -> running,
      // but this is the user-driven resume edge and must not use APNs's
      // delayable priority. Repeated working-text refreshes remain low
      // priority so they stay within ActivityKit's update budget.
      const resumedWorking = activity.state === "running"
        && activities[computerId]?.activity?.state !== "running";
      const priority = highPriority === true || resumedWorking
        || activities[computerId]?.highPriority === true;
      activities[computerId] = {
        computerId,
        activity,
        highPriority: priority,
      };
      await this.ctx.storage.put(RECENT_AGENT_ACTIVITIES_KEY, activities);
      return priority;
    });
  }

  /// Every retained envelope for this client's active computers, newest
  /// first. The first entry is the primary Live Activity card; later entries
  /// may ride along as `moreActivities` so the island can rank agent rows
  /// across computers.
  async recentAgentActivities(state) {
    const cached = await this.ctx.storage.get(RECENT_AGENT_ACTIVITIES_KEY);
    if (!cached || typeof cached !== "object" || Array.isArray(cached)) return [];
    const activeComputerIds = new Set(
      state.computers
        .filter((computer) =>
          computer.online &&
          computer.agents &&
          computer.agents.running + computer.agents.waiting + computer.agents.done > 0)
        .map((computer) => computer.id),
    );
    const retained = {};
    for (const [computerId, entry] of Object.entries(cached)) {
      if (
        activeComputerIds.has(computerId) &&
        entry &&
        typeof entry === "object" &&
        entry.computerId === computerId &&
        entry.activity &&
        typeof entry.activity === "object"
      ) {
        retained[computerId] = entry;
      }
    }
    const retainedKeys = Object.keys(retained);
    if (retainedKeys.length !== Object.keys(cached).length) {
      if (retainedKeys.length === 0) {
        await this.ctx.storage.delete(RECENT_AGENT_ACTIVITIES_KEY);
      } else {
        await this.ctx.storage.put(RECENT_AGENT_ACTIVITIES_KEY, retained);
      }
    }
    return Object.values(retained).sort(
      (lhs, rhs) => Number(rhs.activity.updatedAt) - Number(lhs.activity.updatedAt),
    );
  }

  async markAgentActivityDelivered(computerId, eventID) {
    await this.ctx.blockConcurrencyWhile(async () => {
      const cached = await this.ctx.storage.get(RECENT_AGENT_ACTIVITIES_KEY);
      const entry = cached?.[computerId];
      if (!entry || entry.activity?.eventID !== eventID) return;
      if (entry.highPriority !== true && entry.activity?.alert !== true) return;
      await this.ctx.storage.put(RECENT_AGENT_ACTIVITIES_KEY, {
        ...cached,
        [computerId]: {
          ...entry,
          activity: { ...entry.activity, alert: false },
          highPriority: false,
        },
      });
    });
  }

  async clearAgentActivities() {
    await this.ctx.storage.delete(RECENT_AGENT_ACTIVITIES_KEY);
  }

  async enqueueActivityRetry(clientId, retryAt) {
    await this.ctx.blockConcurrencyWhile(async () => {
      const [pending, forced, alarm] = await Promise.all([
        this.ctx.storage.get(PENDING_KEY),
        this.ctx.storage.get(FORCE_KEY),
        this.ctx.storage.getAlarm(),
      ]);
      await this.ctx.storage.put(PENDING_KEY, mergeIds(pending, [clientId]));
      await this.ctx.storage.put(FORCE_KEY, mergeIds(forced, [clientId]));
      const desired = Math.max(Date.now() + COALESCE_MILLISECONDS, retryAt);
      if (alarm === null || alarm > desired) await this.ctx.storage.setAlarm(desired);
    });
  }

  async alarm() {
    const { pending, forced } = await this.ctx.blockConcurrencyWhile(async () => {
      const [pendingClientIds, forcedClientIds, inflightClientIds, inflightForcedIds] =
        await Promise.all([
        this.ctx.storage.get(PENDING_KEY),
        this.ctx.storage.get(FORCE_KEY),
        this.ctx.storage.get(INFLIGHT_KEY),
        this.ctx.storage.get(INFLIGHT_FORCE_KEY),
      ]);
      const work = mergeIds(inflightClientIds, pendingClientIds);
      const workForced = mergeIds(inflightForcedIds, forcedClientIds);
      if (work.length === 0) {
        await this.ctx.storage.delete([
          PENDING_KEY,
          FORCE_KEY,
          INFLIGHT_KEY,
          INFLIGHT_FORCE_KEY,
        ]);
        await this.ctx.storage.deleteAlarm();
        return { pending: [], forced: [] };
      }
      await this.ctx.storage.put(INFLIGHT_KEY, work);
      if (workForced.length > 0) {
        await this.ctx.storage.put(INFLIGHT_FORCE_KEY, workForced);
      }
      await this.ctx.storage.delete([PENDING_KEY, FORCE_KEY]);
      // If the invocation is terminated after taking work, this durable alarm
      // makes the in-flight set visible to a later retry.
      await this.ctx.storage.setAlarm(Date.now() + WATCHDOG_MILLISECONDS);
      return { pending: work, forced: workForced };
    });
    const forcedSet = new Set(forced ?? []);
    const retries = [];
    const forcedRetries = [];
    let earliestRetryAt = null;

    for (const clientId of pending ?? []) {
      try {
        const retryAt = await this.deliverClient(clientId, forcedSet.has(clientId));
        if (Number.isFinite(retryAt)) {
          retries.push(clientId);
          if (forcedSet.has(clientId)) forcedRetries.push(clientId);
          earliestRetryAt = earlier(earliestRetryAt, retryAt);
        }
      } catch (error) {
        const retryAt = Date.now() + RETRY_MILLISECONDS;
        await this.deferClient(clientId, retryAt);
        retries.push(clientId);
        if (forcedSet.has(clientId)) forcedRetries.push(clientId);
        earliestRetryAt = earlier(earliestRetryAt, retryAt);
        console.error("APNs delivery failed", error instanceof Error ? error.message : error);
      }
    }

    await this.ctx.blockConcurrencyWhile(async () => {
      const [currentPending, currentForced] = await Promise.all([
        this.ctx.storage.get(PENDING_KEY),
        this.ctx.storage.get(FORCE_KEY),
      ]);
      const nextPending = mergeIds(currentPending, retries);
      const nextForced = mergeIds(currentForced, forcedRetries);
      await this.ctx.storage.delete([INFLIGHT_KEY, INFLIGHT_FORCE_KEY]);
      if (nextPending.length === 0) {
        await this.ctx.storage.delete([PENDING_KEY, FORCE_KEY]);
        await this.ctx.storage.deleteAlarm();
        return;
      }
      await this.ctx.storage.put(PENDING_KEY, nextPending);
      if (nextForced.length > 0) {
        await this.ctx.storage.put(FORCE_KEY, nextForced);
      } else {
        await this.ctx.storage.delete(FORCE_KEY);
      }
      // `setAlarm` replaces the 60-second crash watchdog installed above.
      // Fresh invalidations that arrived during delivery run immediately;
      // otherwise APNs Retry-After / durable endpoint backoff wins.
      const hasFreshWork = (currentPending ?? []).length > 0;
      const desired = hasFreshWork
        ? Date.now() + COALESCE_MILLISECONDS
        : Math.max(Date.now() + COALESCE_MILLISECONDS, earliestRetryAt ?? Date.now() + RETRY_MILLISECONDS);
      await this.ctx.storage.setAlarm(desired);
    });
  }

  /// Direct E2EE agent content for the aggregate Live Activity. The newest
  /// opaque envelope per computer is retained in this client's Durable Object
  /// only while that computer has an active agent. This lets the normal
  /// sequence/retry queue re-attach the card after a terminal count change
  /// without storing agent content in D1.
  /// Working updates are always silent. Because ActivityKit requires a visible
  /// alert for every remote push-to-start, only an explicit waiting/error/done
  /// attention edge may consume that token. An existing activity can still
  /// receive working updates immediately.
  async handleActivity(request) {
    let body;
    try {
      body = await request.json();
    } catch {
      return new Response("bad request", { status: 400 });
    }
    const { clientId, computerId, activity } = body ?? {};
    if (
      !isId(clientId) ||
      !isId(computerId) ||
      !activity || typeof activity !== "object" ||
      typeof activity.eventID !== "string" || activity.eventID.length !== 36 ||
      !["running", "waiting", "error", "done"].includes(activity.state) ||
      !Number.isSafeInteger(activity.updatedAt) || activity.updatedAt < 0 ||
      typeof activity.alert !== "boolean" ||
      typeof activity.sealed !== "string" || activity.sealed.length > 2_700
    ) {
      return new Response("bad request", { status: 400 });
    }

    const [binding, state, result] = await Promise.all([
      this.env.DB.prepare(
        `SELECT 1 AS present FROM client_computers
          WHERE client_id = ?1 AND computer_id = ?2`,
      ).bind(clientId, computerId).first(),
      aggregateClientState(this.env.DB, clientId),
      this.env.DB.prepare(
        `SELECT id, apns_environment AS environment, token,
                surface, last_total_running AS lastTotalRunning,
                retry_not_before AS retryNotBefore
           FROM push_endpoints
          WHERE client_id = ?1
            AND surface IN ('liveactivity-start', 'liveactivity-update')
            AND invalidated_at IS NULL
          ORDER BY id`,
      ).bind(clientId).all(),
    ]);
    if (!binding) return new Response("forbidden", { status: 403 });
    const endpoints = result.results ?? [];
    if (endpoints.length === 0) return new Response(null, { status: 202 });

    const cached = await this.ctx.storage.get(TOKEN_CACHE_KEY);
    const apns = createApnsClient(this.env, { tokenCache: cached ?? null });
    const now = Date.now();
    const totalActive = state.totalRunning + state.agentsRunning
      + state.agentsWaiting + (state.agentsDone ?? 0);
    // An update token proves that an activity already exists for this client.
    // Keep the global push-to-start token for a future lifecycle, but never
    // consume it for another agent event and create a duplicate island.
    const hasUpdateEndpoint = endpoints.some(
      (endpoint) => endpoint.surface === "liveactivity-update",
    );
    const mayStartActivity = activity.alert;
    const aggregateChanged = endpoints.some(
      (endpoint) =>
        endpoint.surface === "liveactivity-update" &&
        Number(endpoint.lastTotalRunning ?? 0) !== totalActive,
    );
    const highPriority = await this.cacheAgentActivity(
      computerId,
      activity,
      aggregateChanged,
    );
    // The incoming envelope leads the card; retained envelopes from other
    // active computers ride along so the island can rank rows like Home.
    const extraActivities = packExtraActivities(
      activity,
      (await this.recentAgentActivities(state)).filter(
        (entry) => entry.computerId !== computerId,
      ),
    );
    let earliestRetryAt = null;
    let deliveredRichActivity = false;

    for (const endpoint of endpoints) {
      const retryNotBefore = Number(endpoint.retryNotBefore);
      if (Number.isFinite(retryNotBefore) && retryNotBefore > Math.floor(now / 1000)) {
        earliestRetryAt = earlier(earliestRetryAt, retryNotBefore * 1000);
        continue;
      }
      if (
        endpoint.surface === "liveactivity-start" &&
        (
          !mayStartActivity || totalActive === 0 || hasUpdateEndpoint ||
          Number(endpoint.lastTotalRunning ?? 0) > 0
        )
      ) {
        continue;
      }
      const event = endpoint.surface === "liveactivity-start"
        ? "start"
        : totalActive === 0 ? "end" : "update";
      const payload = { state, event, activity: { ...activity, computerId } };
      if (extraActivities.length > 0) payload.moreActivities = extraActivities;
      let outcome;
      try {
        outcome = await apns.send(
          {
            token: endpoint.token,
            surface: endpoint.surface,
            environment: endpoint.environment,
            apnsId: await deliveryApnsId(endpoint.id, activity.eventID, event),
            immediate: highPriority,
          },
          payload,
        );
      } catch (error) {
        const retryAt = now + RETRY_MILLISECONDS;
        await this.deferEndpoint(
          endpoint.id,
          retryAt,
          error instanceof Error ? error.message : "ProviderConfigurationError",
        );
        earliestRetryAt = earlier(earliestRetryAt, retryAt);
        console.error(
          "agent activity build/send failed",
          error instanceof Error ? error.message : error,
        );
        continue;
      }
      if (outcome.tokenCache) {
        await this.ctx.storage.put(TOKEN_CACHE_KEY, outcome.tokenCache);
      } else {
        await this.ctx.storage.delete(TOKEN_CACHE_KEY);
      }
      if (outcome.outcome === "success") {
        if (event === "end") {
          await this.deleteEndpoint(endpoint.id);
          await this.resetStartBaseline(clientId);
        } else {
          await this.markDelivered(endpoint.id, state, totalActive);
        }
        deliveredRichActivity = true;
      } else if (outcome.outcome === "invalidate") {
        if (endpoint.surface === "liveactivity-update") {
          await this.deleteEndpoint(endpoint.id);
        } else {
          await this.invalidateEndpoint(endpoint.id);
        }
      } else if (outcome.outcome === "retry" || outcome.outcome === "fatal") {
        const retryAt = outcome.outcome === "retry"
          ? retryAtFromHeader(outcome.retryAfter, now)
          : now + FATAL_RETRY_MILLISECONDS;
        await this.deferEndpoint(endpoint.id, retryAt, outcome.reason ?? "APNsError");
        earliestRetryAt = earlier(earliestRetryAt, retryAt);
      }
    }
    if (Number.isFinite(earliestRetryAt)) {
      await this.enqueueActivityRetry(clientId, earliestRetryAt);
    } else if (deliveredRichActivity) {
      await this.markAgentActivityDelivered(computerId, activity.eventID);
    }
    return new Response(null, { status: 202 });
  }

  async deliverClient(clientId, force) {
    const state = await aggregateClientState(this.env.DB, clientId);
    const totalAgents =
      (state.agentsRunning ?? 0) + (state.agentsWaiting ?? 0)
      + (state.agentsDone ?? 0);
    const retainedActivities = totalAgents > 0
      ? await this.recentAgentActivities(state)
      : [];
    const recentAgent = retainedActivities[0] ?? null;
    const extraActivities = recentAgent
      ? packExtraActivities(recentAgent.activity, retainedActivities.slice(1))
      : [];
    const result = await this.env.DB
      .prepare(
        `SELECT id, surface, apns_environment AS environment, token,
                activity_key AS activityId, last_sequence AS lastSequence,
                last_total_running AS lastTotalRunning,
                retry_not_before AS retryNotBefore
           FROM push_endpoints
          WHERE client_id = ?1 AND invalidated_at IS NULL
          ORDER BY id`,
      )
      .bind(clientId)
      .all();
    const endpoints = result.results;
    if (endpoints.length === 0) {
      if (totalAgents === 0) await this.clearAgentActivities();
      await this.clearClientDeferral(clientId);
      return null;
    }

    const cached = await this.ctx.storage.get(TOKEN_CACHE_KEY);
    const apns = createApnsClient(this.env, { tokenCache: cached ?? null });
    let earliestRetryAt = null;
    let pushed = false;
    const now = Date.now();

    // The Live Activity lives while anything is active, including a recent
    // completion during its short visibility window.
    const totalActive =
      state.totalRunning + (state.agentsRunning ?? 0) + (state.agentsWaiting ?? 0)
      + (state.agentsDone ?? 0);
    const hasUpdateEndpoint = endpoints.some(
      (endpoint) => endpoint.surface === "liveactivity-update",
    );

    for (const endpoint of endpoints) {
      const surface = endpoint.surface;
      if (!force && Number(endpoint.lastSequence) >= state.sequence) continue;
      const retryNotBefore = Number(endpoint.retryNotBefore);
      if (Number.isFinite(retryNotBefore) && retryNotBefore > Math.floor(now / 1000)) {
        earliestRetryAt = earlier(earliestRetryAt, retryNotBefore * 1000);
        continue;
      }
      let payload = {};

      if (surface === "liveactivity-start") {
        // APNs requires a visible alert for push-to-start. Ordinary count
        // invalidations never start an activity; a retained rich envelope may
        // retry a failed agent-driven start without losing the card.
        if (
          !recentAgent ||
          hasUpdateEndpoint ||
          totalActive === 0 ||
          Number(endpoint.lastTotalRunning ?? 0) > 0 ||
          recentAgent.activity.alert !== true
        ) continue;
        payload = {
          state,
          event: "start",
          activity: {
            ...recentAgent.activity,
            computerId: recentAgent.computerId,
          },
        };
        if (extraActivities.length > 0) payload.moreActivities = extraActivities;
      } else if (surface === "liveactivity-update") {
        // ActivityKit ContentState updates are full replacements. Aggregate
        // state must carry the retained opaque envelope while an agent exists,
        // otherwise the full replacement would erase the concrete agent card.
        if (totalAgents > 0) {
          if (!recentAgent) continue;
          payload = {
            state,
            event: "update",
            activity: {
              ...recentAgent.activity,
              computerId: recentAgent.computerId,
            },
          };
          if (extraActivities.length > 0) payload.moreActivities = extraActivities;
        } else {
          payload = {
            state,
            event: totalActive === 0 ? "end" : "update",
          };
        }
      }

      const deliveryKey = recentAgent && payload.activity
        ? `${state.sequence}:${recentAgent.activity.eventID}`
        : state.sequence;
      const request = {
        token: endpoint.token,
        surface,
        environment: endpoint.environment,
        apnsId: await deliveryApnsId(
          endpoint.id,
          deliveryKey,
          payload.event ?? surface,
        ),
        immediate: recentAgent?.highPriority === true,
      };
      let outcome;
      try {
        outcome = await apns.send(request, payload);
        if (outcome.reason === "ExpiredProviderToken") {
          // The client cleared its provider-token cache; one immediate resend
          // avoids delaying a valid state transition for the normal backoff.
          outcome = await apns.send(request, payload);
        }
      } catch (error) {
        const retryAt = now + RETRY_MILLISECONDS;
        await this.deferEndpoint(
          endpoint.id,
          retryAt,
          error instanceof Error ? error.message : "ProviderConfigurationError",
        );
        earliestRetryAt = earlier(earliestRetryAt, retryAt);
        continue;
      }
      if (outcome.tokenCache) {
        await this.ctx.storage.put(TOKEN_CACHE_KEY, outcome.tokenCache);
      } else {
        await this.ctx.storage.delete(TOKEN_CACHE_KEY);
      }

      if (outcome.outcome === "success") {
        const endActivity = surface === "liveactivity-update" && totalActive === 0;
        if (endActivity) {
          await this.deleteEndpoint(endpoint.id);
          await this.resetStartBaseline(clientId);
          await this.clearAgentActivities();
        } else {
          await this.markDelivered(endpoint.id, state, totalActive);
          if (recentAgent && payload.activity) {
            await this.markAgentActivityDelivered(
              recentAgent.computerId,
              recentAgent.activity.eventID,
            );
          }
        }
        pushed = true;
      } else if (outcome.outcome === "invalidate") {
        if (surface === "liveactivity-update") {
          await this.deleteEndpoint(endpoint.id);
        } else {
          await this.invalidateEndpoint(endpoint.id);
        }
      } else if (outcome.outcome === "retry") {
        const retryAt = retryAtFromHeader(outcome.retryAfter, now);
        await this.deferEndpoint(endpoint.id, retryAt, outcome.reason ?? "RetryableAPNsError");
        earliestRetryAt = earlier(earliestRetryAt, retryAt);
      } else {
        // Payload/topic/configuration failures cannot succeed on a minute loop.
        // Keep the registration recoverable, but quarantine it for a day; a
        // fresh PUT clears the deferral immediately.
        const retryAt = now + FATAL_RETRY_MILLISECONDS;
        await this.deferEndpoint(endpoint.id, retryAt, outcome.reason ?? "FatalAPNsError");
        earliestRetryAt = earlier(earliestRetryAt, retryAt);
      }
    }

    if (pushed) {
      await this.env.DB
        .prepare(
          `UPDATE client_delivery_state
              SET last_fingerprint = ?2, last_pushed_at = ?3
            WHERE client_id = ?1`,
        )
        .bind(clientId, fingerprint(state), Math.floor(Date.now() / 1000))
        .run();
    }
    await this.clearClientDeferral(clientId);
    return earliestRetryAt;
  }

  /// `totalActive` (TTYs + active/recent agents) is the Live Activity
  /// lifecycle baseline stored in last_total_running; it defaults to the TTY
  /// count for callers that predate agent counts.
  async markDelivered(endpointId, state, totalActive = state.totalRunning) {
    const now = Math.floor(Date.now() / 1000);
    await this.env.DB
      .prepare(
          `UPDATE push_endpoints
            SET last_sequence = ?2,
                last_total_running = ?3,
                updated_at = ?4,
                retry_not_before = NULL,
                failure_count = 0,
                last_failure_reason = NULL
          WHERE id = ?1`,
      )
      .bind(endpointId, state.sequence, totalActive, now)
      .run();
  }

  async deleteEndpoint(endpointId) {
    await this.env.DB
      .prepare(`DELETE FROM push_endpoints WHERE id = ?1`)
      .bind(endpointId)
      .run();
  }

  async resetStartBaseline(clientId) {
    await this.env.DB
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
      .bind(clientId, Math.floor(Date.now() / 1000))
      .run();
  }

  async invalidateEndpoint(endpointId) {
    await this.env.DB
      .prepare(`UPDATE push_endpoints SET invalidated_at = ?2 WHERE id = ?1`)
      .bind(endpointId, Math.floor(Date.now() / 1000))
      .run();
  }

  async deferEndpoint(endpointId, retryAtMilliseconds, reason) {
    const retryAt = Math.floor(retryAtMilliseconds / 1000);
    await this.env.DB
      .prepare(
        `UPDATE push_endpoints
            SET retry_not_before = ?2,
                failure_count = failure_count + 1,
                last_failure_reason = ?3,
                updated_at = ?4
          WHERE id = ?1`,
      )
      .bind(
        endpointId,
        retryAt,
        String(reason ?? "APNsError").slice(0, 128),
        Math.floor(Date.now() / 1000),
      )
      .run();
  }

  async deferClient(clientId, retryAtMilliseconds) {
    await this.env.DB
      .prepare(
        `UPDATE client_delivery_state
            SET retry_not_before = ?2
          WHERE client_id = ?1`,
      )
      .bind(clientId, Math.floor(retryAtMilliseconds / 1000))
      .run();
  }

  async clearClientDeferral(clientId) {
    await this.env.DB
      .prepare(
        `UPDATE client_delivery_state
            SET retry_not_before = NULL
          WHERE client_id = ?1 AND retry_not_before IS NOT NULL`,
      )
      .bind(clientId)
      .run();
  }
}
