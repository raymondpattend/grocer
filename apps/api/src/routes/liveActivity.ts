import { Hono } from "hono";
import type { Context } from "hono";
import {
  EndLiveActivityRequestSchema,
  RegisterTokenRequestSchema,
  RegisterUpdateTokenRequestSchema,
  StartLiveActivityRequestSchema,
  UpdateLiveActivityRequestSchema,
  type LiveActivityContent,
} from "@grocer/shared";
import type { Env } from "../env.js";
import { parseBody } from "../lib/validate.js";
import {
  ACTIVITY_ATTRIBUTES_TYPE,
  sendShoppingTripNotification,
  sendEnd,
  sendStart,
  sendUpdate,
  type ApnsResult,
  type ShoppingTripNotificationEvent,
} from "../services/apns.js";
import {
  activityTokensForSession,
  eligibleNotificationTokens,
  eligibleStartTokens,
  invalidateNotificationToken,
  invalidatePushToStartToken,
  invalidateUpdateToken,
  logApns,
  saveSessionSnapshot,
  upsertActivityToken,
  upsertDeviceToken,
} from "../db/liveActivityTokens.js";
import { createPostHogClient } from "../lib/posthog.js";

export const liveActivityRoute = new Hono<{ Bindings: Env }>();

const SIGNATURE_HEADER = "x-grocer-signature";
const TIMESTAMP_HEADER = "x-grocer-timestamp";
const DEVICE_HEADER = "x-grocer-device-id";
const MAX_CLOCK_SKEW_SECONDS = 5 * 60;

const encoder = new TextEncoder();

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return [...new Uint8Array(signature)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function constantTimeEqualHex(a: string, b: string): boolean {
  if (!/^[0-9a-f]+$/i.test(a) || !/^[0-9a-f]+$/i.test(b)) return false;
  const left = a.toLowerCase();
  const right = b.toLowerCase();
  let diff = left.length ^ right.length;
  const maxLength = Math.max(left.length, right.length);
  for (let i = 0; i < maxLength; i++) {
    diff |= (left.charCodeAt(i) || 0) ^ (right.charCodeAt(i) || 0);
  }
  return diff === 0;
}

async function authenticateLiveActivityRequest(
  c: Context<{ Bindings: Env }>,
): Promise<Response | null> {
  const secret = c.env.LIVE_ACTIVITY_API_SECRET?.trim();
  if (!secret) {
    console.error("[live-activity] LIVE_ACTIVITY_API_SECRET is not configured");
    return c.json({ ok: false, error: "Live Activity auth is not configured" }, 503);
  }

  const timestamp = c.req.header(TIMESTAMP_HEADER);
  const signature = c.req.header(SIGNATURE_HEADER);
  if (!timestamp || !signature) {
    return c.json({ ok: false, error: "Missing request signature" }, 401);
  }

  const timestampSeconds = Number(timestamp);
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (!Number.isFinite(timestampSeconds)
      || Math.abs(nowSeconds - timestampSeconds) > MAX_CLOCK_SKEW_SECONDS) {
    return c.json({ ok: false, error: "Stale request signature" }, 401);
  }

  const url = new URL(c.req.url);
  const method = c.req.method.toUpperCase();
  const body = method === "GET" ? "" : await c.req.raw.clone().text();
  const expected = await hmacHex(secret, `${timestamp}.${method}.${url.pathname}.${body}`);
  if (!constantTimeEqualHex(signature, expected)) {
    return c.json({ ok: false, error: "Invalid request signature" }, 401);
  }
  return null;
}

function rateLimitConfig(pathname: string): { scope: string; limit: number; windowSeconds: number } {
  if (pathname.includes("/debug/")) return { scope: "debug", limit: 10, windowSeconds: 60 };
  if (pathname.endsWith("/start") || pathname.endsWith("/update") || pathname.endsWith("/end")) {
    return { scope: "fanout", limit: 30, windowSeconds: 60 };
  }
  return { scope: "register", limit: 90, windowSeconds: 60 };
}

async function consumeRateLimit(
  db: D1Database,
  key: string,
  limit: number,
  windowSeconds: number,
): Promise<boolean> {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const windowStart = Math.floor(nowSeconds / windowSeconds) * windowSeconds;
  const ts = new Date().toISOString();
  const row = await db
    .prepare("SELECT window_start, count FROM live_activity_rate_limits WHERE key = ?1")
    .bind(key)
    .first<{ window_start: number; count: number }>();

  if (!row || row.window_start !== windowStart) {
    await db
      .prepare(
        `INSERT INTO live_activity_rate_limits (key, window_start, count, updated_at)
         VALUES (?1, ?2, 1, ?3)
         ON CONFLICT(key) DO UPDATE SET window_start = ?2, count = 1, updated_at = ?3`,
      )
      .bind(key, windowStart, ts)
      .run();
    return true;
  }

  if (row.count >= limit) return false;
  await db
    .prepare("UPDATE live_activity_rate_limits SET count = count + 1, updated_at = ?2 WHERE key = ?1")
    .bind(key, ts)
    .run();
  return true;
}

async function enforceLiveActivityRateLimit(
  c: Context<{ Bindings: Env }>,
): Promise<Response | null> {
  const url = new URL(c.req.url);
  const config = rateLimitConfig(url.pathname);
  const deviceId = c.req.header(DEVICE_HEADER)
    ?? c.req.header("CF-Connecting-IP")
    ?? "unknown";
  const key = `${config.scope}:${deviceId}`;
  const ok = await consumeRateLimit(c.env.DB, key, config.limit, config.windowSeconds);
  if (!ok) {
    return c.json({ ok: false, error: "Rate limit exceeded" }, 429);
  }
  return null;
}

liveActivityRoute.use("/live-activity/*", async (c, next) => {
  const authError = await authenticateLiveActivityRequest(c);
  if (authError) return authError;
  const rateLimitError = await enforceLiveActivityRateLimit(c);
  if (rateLimitError) return rateLimitError;
  await next();
});

/** Pull just the content-state fields out of a start/update request. */
function toContent(
  body: Record<string, unknown> & {
    shopperName: string;
    status: "Active" | "Completed" | "Cancelled";
    itemsFound: number;
    itemsRemaining: number;
    totalItems: number;
    outOfStockCount: number;
    replacedCount: number;
  },
): LiveActivityContent {
  return {
    storeName: (body.storeName as string | null | undefined) ?? null,
    shopperName: body.shopperName,
    status: body.status,
    itemsFound: body.itemsFound,
    itemsRemaining: body.itemsRemaining,
    totalItems: body.totalItems,
    outOfStockCount: body.outOfStockCount,
    replacedCount: body.replacedCount,
    lastHandledItemName:
      (body.lastHandledItemName as string | null | undefined) ?? null,
    lastHandledItemStatus:
      (body.lastHandledItemStatus as LiveActivityContent["lastHandledItemStatus"]) ??
      null,
  };
}

async function sendShoppingTripNotificationFanout(
  c: Context<{ Bindings: Env }>,
  input: {
    householdId: string;
    sessionId: string;
    sourceDeviceId?: string;
    event: ShoppingTripNotificationEvent;
    shopperName?: string | null;
    storeName?: string | null;
    itemsFound?: number;
    totalItems?: number;
  },
): Promise<{ sent: number; failed: number }> {
  const devices = await eligibleNotificationTokens(
    c.env.DB,
    input.householdId,
    input.sourceDeviceId,
  );

  console.log(
    `[notifications] fanout event=${input.event} household=${input.householdId} ` +
    `excludeDevice=${input.sourceDeviceId ?? "none"} eligibleDevices=${devices.length}`,
  );

  let sent = 0;
  let failed = 0;
  const logEvent = input.event === "started" ? "start_notification" : "end_notification";

  await Promise.all(
    devices.map(async (device) => {
      const token = device.push_notification_token!;
      let result: ApnsResult;
      try {
        result = await sendShoppingTripNotification(c.env, token, input);
      } catch (err) {
        failed++;
        await logApns(c.env.DB, {
          sessionId: input.sessionId,
          deviceId: device.device_id,
          event: logEvent,
          outcome: "failed",
          detail: String(err),
        });
        return;
      }

      if (result.ok) {
        sent++;
        await logApns(c.env.DB, {
          sessionId: input.sessionId,
          deviceId: device.device_id,
          event: logEvent,
          outcome: "sent",
          statusCode: result.statusCode,
          apnsId: result.apnsId,
        });
      } else {
        failed++;
        if (result.tokenExpired) {
          await invalidateNotificationToken(c.env.DB, token);
        }
        await logApns(c.env.DB, {
          sessionId: input.sessionId,
          deviceId: device.device_id,
          event: logEvent,
          outcome: result.tokenExpired ? "expired" : "failed",
          statusCode: result.statusCode,
          apnsId: result.apnsId,
          detail: result.reason ?? result.detail,
        });
      }
    }),
  );

  return { sent, failed };
}

// ---------------------------------------------------------------------------
// POST /live-activity/register-token
// Registers (or refreshes) a device's push-to-start token + LA preference.
// ---------------------------------------------------------------------------
liveActivityRoute.post("/live-activity/register-token", async (c) => {
  const parsed = await parseBody(c, RegisterTokenRequestSchema);
  if ("error" in parsed) return parsed.error;

  await upsertDeviceToken(c.env.DB, parsed.data);

  const posthog = createPostHogClient(c.env);
  posthog.capture({
    distinctId: parsed.data.memberId,
    event: "device registered",
    properties: {
      household_id: parsed.data.householdId,
      platform: parsed.data.platform ?? "iOS",
      app_version: parsed.data.appVersion,
      live_activities_enabled: parsed.data.familyLiveActivitiesEnabled,
      has_push_to_start_token: !!parsed.data.pushToStartToken,
      has_push_notification_token: !!parsed.data.pushNotificationToken,
      $groups: { household: parsed.data.householdId },
    },
  });
  c.executionCtx.waitUntil(posthog.shutdown());

  return c.json({ ok: true });
});

// ---------------------------------------------------------------------------
// POST /live-activity/register-update-token
// A running activity's per-activity update token, so we can update/end it.
// ---------------------------------------------------------------------------
liveActivityRoute.post("/live-activity/register-update-token", async (c) => {
  const parsed = await parseBody(c, RegisterUpdateTokenRequestSchema);
  if ("error" in parsed) return parsed.error;

  await upsertActivityToken(c.env.DB, parsed.data);
  return c.json({ ok: true });
});

// ---------------------------------------------------------------------------
// POST /live-activity/start
// Fan out push-to-start to every eligible device in the household.
// ---------------------------------------------------------------------------
liveActivityRoute.post("/live-activity/start", async (c) => {
  const parsed = await parseBody(c, StartLiveActivityRequestSchema);
  if ("error" in parsed) return parsed.error;
  const body = parsed.data;
  const content = toContent(body);

  // Persist a snapshot for retries/diagnostics (CloudKit stays authoritative).
  await saveSessionSnapshot(c.env.DB, {
    sessionId: body.sessionId,
    householdId: body.householdId,
    content,
    status: "Active",
    startedAt: body.startedAt,
  });

  const devices = await eligibleStartTokens(
    c.env.DB,
    body.householdId,
    body.sourceDeviceId,
  );

  console.log(
    `[live-activity] start fanout household=${body.householdId} ` +
      `session=${body.sessionId} excludeDevice=${body.sourceDeviceId ?? "none"} ` +
      `eligibleDevices=${devices.length}`,
  );

  let sent = 0;
  let failed = 0;
  await Promise.all(
    devices.map(async (device) => {
      const token = device.push_to_start_token!;
      let result: ApnsResult;
      try {
        result = await sendStart(c.env, token, {
          content,
          attributesType: ACTIVITY_ATTRIBUTES_TYPE,
          attributes: {
            householdId: body.householdId,
            sessionId: body.sessionId,
            startedByMemberId: body.startedByMemberId ?? null,
          },
        });
      } catch (err) {
        failed++;
        await logApns(c.env.DB, {
          sessionId: body.sessionId,
          deviceId: device.device_id,
          event: "start",
          outcome: "failed",
          detail: String(err),
        });
        return;
      }

      if (result.ok) {
        sent++;
        await logApns(c.env.DB, {
          sessionId: body.sessionId,
          deviceId: device.device_id,
          event: "start",
          outcome: "sent",
          statusCode: result.statusCode,
          apnsId: result.apnsId,
        });
      } else {
        failed++;
        if (result.tokenExpired) {
          await invalidatePushToStartToken(c.env.DB, token);
        }
        await logApns(c.env.DB, {
          sessionId: body.sessionId,
          deviceId: device.device_id,
          event: "start",
          outcome: result.tokenExpired ? "expired" : "failed",
          statusCode: result.statusCode,
          apnsId: result.apnsId,
          detail: result.reason ?? result.detail,
        });
      }
    }),
  );

  const notifications = await sendShoppingTripNotificationFanout(c, {
    householdId: body.householdId,
    sessionId: body.sessionId,
    sourceDeviceId: body.sourceDeviceId,
    event: "started",
    shopperName: body.shopperName,
    storeName: body.storeName,
  });

  const posthog = createPostHogClient(c.env);
  posthog.capture({
    distinctId: body.startedByMemberId ?? body.householdId,
    event: "shopping trip started",
    properties: {
      session_id: body.sessionId,
      household_id: body.householdId,
      store_name: body.storeName ?? null,
      total_items: body.totalItems,
      devices_live_activity_sent: sent,
      devices_live_activity_failed: failed,
      devices_notified: notifications.sent,
      devices_notification_failed: notifications.failed,
      $groups: { household: body.householdId },
    },
  });
  c.executionCtx.waitUntil(posthog.shutdown());

  return c.json({
    ok: true,
    sent,
    failed,
    notificationsSent: notifications.sent,
    notificationsFailed: notifications.failed,
  });
});

// ---------------------------------------------------------------------------
// POST /live-activity/update
// Push an update to every running activity for this session.
// ---------------------------------------------------------------------------
liveActivityRoute.post("/live-activity/update", async (c) => {
  const parsed = await parseBody(c, UpdateLiveActivityRequestSchema);
  if ("error" in parsed) return parsed.error;
  const body = parsed.data;
  const content = toContent(body);

  await saveSessionSnapshot(c.env.DB, {
    sessionId: body.sessionId,
    householdId: body.householdId,
    content,
    status: "Active",
  });

  const activities = await activityTokensForSession(c.env.DB, body.sessionId);

  let sent = 0;
  let failed = 0;
  await Promise.all(
    activities.map(async (a) => {
      let result: ApnsResult;
      try {
        result = await sendUpdate(c.env, a.update_token, content);
      } catch (err) {
        failed++;
        await logApns(c.env.DB, {
          sessionId: body.sessionId,
          deviceId: a.device_id,
          event: "update",
          outcome: "failed",
          detail: String(err),
        });
        return;
      }

      if (result.ok) {
        sent++;
        await logApns(c.env.DB, {
          sessionId: body.sessionId,
          deviceId: a.device_id,
          event: "update",
          outcome: "sent",
          statusCode: result.statusCode,
          apnsId: result.apnsId,
        });
      } else {
        failed++;
        if (result.tokenExpired) await invalidateUpdateToken(c.env.DB, a.update_token);
        await logApns(c.env.DB, {
          sessionId: body.sessionId,
          deviceId: a.device_id,
          event: "update",
          outcome: result.tokenExpired ? "expired" : "failed",
          statusCode: result.statusCode,
          detail: result.reason ?? result.detail,
        });
      }
    }),
  );

  const posthog = createPostHogClient(c.env);
  posthog.capture({
    distinctId: body.householdId,
    event: "shopping trip updated",
    properties: {
      session_id: body.sessionId,
      household_id: body.householdId,
      items_found: body.itemsFound,
      items_remaining: body.itemsRemaining,
      total_items: body.totalItems,
      out_of_stock_count: body.outOfStockCount,
      replaced_count: body.replacedCount,
      devices_updated: sent,
      devices_update_failed: failed,
      $groups: { household: body.householdId },
    },
  });
  c.executionCtx.waitUntil(posthog.shutdown());

  return c.json({ ok: true, sent, failed });
});

// ---------------------------------------------------------------------------
// POST /live-activity/end
// End every running activity for this session with a completed/cancelled state.
// ---------------------------------------------------------------------------
liveActivityRoute.post("/live-activity/end", async (c) => {
  const parsed = await parseBody(c, EndLiveActivityRequestSchema);
  if ("error" in parsed) return parsed.error;
  const body = parsed.data;

  const status = body.status === "completed" ? "Completed" : "Cancelled";
  const content: LiveActivityContent = {
    storeName: body.storeName ?? null,
    shopperName: body.shopperName ?? "",
    status,
    itemsFound: body.itemsFound,
    itemsRemaining: body.itemsRemaining,
    totalItems: body.totalItems,
    outOfStockCount: body.outOfStockCount,
    replacedCount: body.replacedCount,
    lastHandledItemName: null,
    lastHandledItemStatus: null,
  };

  await saveSessionSnapshot(c.env.DB, {
    sessionId: body.sessionId,
    householdId: body.householdId,
    content,
    status,
  });

  const activities = await activityTokensForSession(c.env.DB, body.sessionId);

  let sent = 0;
  let failed = 0;
  await Promise.all(
    activities.map(async (a) => {
      let result: ApnsResult;
      try {
        result = await sendEnd(c.env, a.update_token, content);
      } catch (err) {
        failed++;
        await logApns(c.env.DB, {
          sessionId: body.sessionId,
          deviceId: a.device_id,
          event: "end",
          outcome: "failed",
          detail: String(err),
        });
        return;
      }

      if (result.ok) {
        sent++;
        await logApns(c.env.DB, {
          sessionId: body.sessionId,
          deviceId: a.device_id,
          event: "end",
          outcome: "sent",
          statusCode: result.statusCode,
          apnsId: result.apnsId,
        });
      } else {
        failed++;
        if (result.tokenExpired) await invalidateUpdateToken(c.env.DB, a.update_token);
        await logApns(c.env.DB, {
          sessionId: body.sessionId,
          deviceId: a.device_id,
          event: "end",
          outcome: result.tokenExpired ? "expired" : "failed",
          statusCode: result.statusCode,
          detail: result.reason ?? result.detail,
        });
      }
    }),
  );

  const notifications = await sendShoppingTripNotificationFanout(c, {
    householdId: body.householdId,
    sessionId: body.sessionId,
    sourceDeviceId: body.sourceDeviceId,
    event: body.status === "completed" ? "completed" : "cancelled",
    shopperName: body.shopperName,
    storeName: body.storeName,
    itemsFound: body.itemsFound,
    totalItems: body.totalItems,
  });

  const posthog = createPostHogClient(c.env);
  posthog.capture({
    distinctId: body.householdId,
    event: "shopping trip ended",
    properties: {
      session_id: body.sessionId,
      household_id: body.householdId,
      status: body.status,
      store_name: body.storeName ?? null,
      items_found: body.itemsFound,
      items_remaining: body.itemsRemaining,
      total_items: body.totalItems,
      out_of_stock_count: body.outOfStockCount,
      replaced_count: body.replacedCount,
      completion_rate: body.totalItems > 0
        ? Math.round((body.itemsFound / body.totalItems) * 100)
        : null,
      devices_notified: notifications.sent,
      devices_notification_failed: notifications.failed,
      $groups: { household: body.householdId },
    },
  });
  c.executionCtx.waitUntil(posthog.shutdown());

  return c.json({
    ok: true,
    sent,
    failed,
    notificationsSent: notifications.sent,
    notificationsFailed: notifications.failed,
  });
});

// ---------------------------------------------------------------------------
// GET /live-activity/debug/household/:id
// Diagnostic view of registered tokens for a household — helps debug
// notification delivery issues. Not exposed in the app UI.
// ---------------------------------------------------------------------------
liveActivityRoute.get("/live-activity/debug/household/:id", async (c) => {
  const householdId = c.req.param("id");
  const { results: devices } = await c.env.DB
    .prepare(
      `SELECT device_id, member_id, household_id,
              push_to_start_token IS NOT NULL AS has_start_token,
              push_notification_token IS NOT NULL AS has_notification_token,
              live_activities_enabled, notifications_enabled,
              token_valid, notification_token_valid,
              app_version, platform, updated_at
       FROM device_tokens WHERE household_id = ?1`,
    )
    .bind(householdId)
    .all();

  const { results: recentLogs } = await c.env.DB
    .prepare(
      `SELECT event, outcome, device_id, status_code, detail, created_at
       FROM apns_log
       WHERE session_id IN (
         SELECT session_id FROM session_snapshots WHERE household_id = ?1
       )
       ORDER BY created_at DESC LIMIT 20`,
    )
    .bind(householdId)
    .all();

  return c.json({ devices: devices ?? [], recentLogs: recentLogs ?? [] });
});
