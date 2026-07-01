import { Effect } from "effect";
import { Hono } from "hono";
import {
  EndLiveActivityRequestSchema,
  HeadsUpRequestSchema,
  RegisterTokenRequestSchema,
  RegisterUpdateTokenRequestSchema,
  StartLiveActivityRequestSchema,
  SyncRegistrationsRequestSchema,
  UpdateLiveActivityRequestSchema,
  type LiveActivityContent,
} from "@grocer/shared";
import type { Env } from "../env.js";
import { decodeJsonBody } from "../effect/body.js";
import { runGuard, runHandler } from "../effect/http.js";
import { fromPromise } from "../effect/interop.js";
import { Telemetry } from "../effect/services.js";
import {
  activityAttributesType,
  sendHeadsUpNotification,
  sendShoppingTripNotification,
  sendEnd,
  sendStart,
  sendUpdate,
  type ApnsResult,
  type ShoppingTripNotificationEvent,
} from "../services/apns.js";
import {
  activityTokensForSession,
  disableHouseholdRegistrationsExceptMembers,
  disableStaleDeviceRegistrations,
  eligibleNotificationTokens,
  eligibleStartTokens,
  invalidateSessionActivityTokensExceptMembers,
  invalidateNotificationToken,
  invalidatePushToStartToken,
  invalidateUpdateToken,
  logApns,
  saveSessionSnapshot,
  upsertActivityToken,
  upsertDeviceToken,
} from "../db/liveActivityTokens.js";
import { authenticateSignedRequest, enforceRateLimit } from "../lib/signing.js";

export const liveActivityRoute = new Hono<{ Bindings: Env }>();

type DeliveryOutcome = "sent" | "failed";

/**
 * Sends one APNs push and records its outcome, resolving to whether it counted
 * as sent or failed. Extracted from the five near-identical fan-out loops the
 * route used to repeat by hand — each caller now just supplies the send call and
 * its result-logging closures, keeping every `logApns` write byte-identical.
 * A thrown send logs a failure; a token Apple rejected is invalidated before the
 * failure is logged.
 */
function deliverPush(input: {
  send: () => Promise<ApnsResult>;
  onThrow: (err: unknown) => Promise<unknown>;
  onSent: (result: ApnsResult) => Promise<unknown>;
  onFailed: (result: ApnsResult) => Promise<unknown>;
  onExpiredToken?: (result: ApnsResult) => Promise<unknown>;
}): Effect.Effect<DeliveryOutcome> {
  return Effect.tryPromise({ try: input.send, catch: (err) => err }).pipe(
    Effect.matchEffect({
      onFailure: (err) =>
        fromPromise(() => input.onThrow(err)).pipe(Effect.as("failed" as const)),
      onSuccess: (result) =>
        Effect.gen(function* () {
          if (result.ok) {
            yield* fromPromise(() => input.onSent(result));
            return "sent" as const;
          }
          if (result.tokenExpired && input.onExpiredToken) {
            yield* fromPromise(() => input.onExpiredToken!(result));
          }
          yield* fromPromise(() => input.onFailed(result));
          return "failed" as const;
        }),
    }),
  );
}

/** Fan a push out to every device in parallel and total the sent/failed counts.
 *  Unbounded to match the original `Promise.all` — a household's device set is
 *  tiny (family size). */
function fanOut<T>(
  items: readonly T[],
  deliver: (item: T) => Effect.Effect<DeliveryOutcome>,
): Effect.Effect<{ sent: number; failed: number }> {
  return Effect.forEach(items, deliver, { concurrency: "unbounded" }).pipe(
    Effect.map((outcomes) => ({
      sent: outcomes.filter((o) => o === "sent").length,
      failed: outcomes.filter((o) => o === "failed").length,
    })),
  );
}

/** Live Activity callers authenticate with the `x-grocer-signature` HMAC header. */
function rateLimitConfig(
  pathname: string,
): { scope: string; limit: number; windowSeconds: number } {
  if (pathname.includes("/debug/")) return { scope: "debug", limit: 10, windowSeconds: 60 };
  if (pathname.endsWith("/start") || pathname.endsWith("/update") || pathname.endsWith("/end")) {
    return { scope: "fanout", limit: 30, windowSeconds: 60 };
  }
  return { scope: "register", limit: 90, windowSeconds: 60 };
}

function reconcileHouseholdRecipients(
  db: D1Database,
  householdId: string,
  recipientMemberIds?: string[],
): Effect.Effect<void> {
  return Effect.gen(function* () {
    const disabled = yield* fromPromise(() =>
      disableHouseholdRegistrationsExceptMembers(db, householdId, recipientMemberIds),
    );
    if (disabled > 0) {
      console.log(
        `[notifications] disabled stale household registrations ` +
          `household=${householdId} disabledRows=${disabled}`,
      );
    }
  });
}

function reconcileSessionRecipients(
  db: D1Database,
  input: { householdId: string; sessionId: string; recipientMemberIds?: string[] },
): Effect.Effect<void> {
  return Effect.gen(function* () {
    const disabled = yield* fromPromise(() =>
      invalidateSessionActivityTokensExceptMembers(db, {
        householdId: input.householdId,
        sessionId: input.sessionId,
        activeMemberIds: input.recipientMemberIds,
      }),
    );
    if (disabled > 0) {
      console.log(
        `[live-activity] invalidated stale session activity tokens ` +
          `household=${input.householdId} session=${input.sessionId} disabledRows=${disabled}`,
      );
    }
  });
}

liveActivityRoute.use("/live-activity/*", async (c, next) => {
  const rejection = await runGuard(
    c,
    Effect.gen(function* () {
      yield* authenticateSignedRequest(c);
      const { scope, limit, windowSeconds } = rateLimitConfig(new URL(c.req.url).pathname);
      yield* enforceRateLimit(c, scope, limit, windowSeconds);
    }),
  );
  if (rejection) return rejection;
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

function sendShoppingTripNotificationFanout(
  env: Env,
  input: {
    householdId: string;
    sessionId: string;
    sourceDeviceId?: string;
    recipientMemberIds?: string[];
    event: ShoppingTripNotificationEvent;
    startedByMemberId?: string | null;
    shopperName?: string | null;
    storeName?: string | null;
    itemsFound?: number;
    itemsRemaining?: number;
    totalItems?: number;
    outOfStockCount?: number;
    replacedCount?: number;
  },
): Effect.Effect<{ sent: number; failed: number }> {
  return Effect.gen(function* () {
    yield* reconcileHouseholdRecipients(env.DB, input.householdId, input.recipientMemberIds);

    const devices = yield* fromPromise(() =>
      eligibleNotificationTokens(
        env.DB,
        input.householdId,
        input.sourceDeviceId,
        input.recipientMemberIds,
      ),
    );

    console.log(
      `[notifications] fanout event=${input.event} household=${input.householdId} ` +
        `excludeDevice=${input.sourceDeviceId ?? "none"} eligibleDevices=${devices.length}`,
    );

    const logEvent = input.event === "started" ? "start_notification" : "end_notification";

    return yield* fanOut(devices, (device) => {
      const token = device.push_notification_token!;
      return deliverPush({
        send: () => sendShoppingTripNotification(env, token, input),
        onThrow: (err) =>
          logApns(env.DB, {
            sessionId: input.sessionId,
            deviceId: device.device_id,
            event: logEvent,
            outcome: "failed",
            detail: String(err),
          }),
        onSent: (result) =>
          logApns(env.DB, {
            sessionId: input.sessionId,
            deviceId: device.device_id,
            event: logEvent,
            outcome: "sent",
            statusCode: result.statusCode,
            apnsId: result.apnsId,
          }),
        onExpiredToken: () => invalidateNotificationToken(env.DB, token),
        onFailed: (result) =>
          logApns(env.DB, {
            sessionId: input.sessionId,
            deviceId: device.device_id,
            event: logEvent,
            outcome: result.tokenExpired ? "expired" : "failed",
            statusCode: result.statusCode,
            apnsId: result.apnsId,
            detail: result.reason ?? result.detail,
          }),
      });
    });
  });
}

// ---------------------------------------------------------------------------
// POST /live-activity/register-token
// Registers (or refreshes) a device's push-to-start token + LA preference.
// ---------------------------------------------------------------------------
liveActivityRoute.post("/live-activity/register-token", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const data = yield* decodeJsonBody(c, RegisterTokenRequestSchema);

      yield* fromPromise(() => upsertDeviceToken(c.env.DB, data));

      const telemetry = yield* Telemetry;
      yield* telemetry.capture({
        distinctId: data.memberId,
        event: "device registered",
        properties: {
          household_id: data.householdId,
          platform: data.platform ?? "iOS",
          app_version: data.appVersion,
          live_activities_enabled: data.familyLiveActivitiesEnabled,
          has_push_to_start_token: !!data.pushToStartToken,
          has_push_notification_token: !!data.pushNotificationToken,
          $groups: { household: data.householdId },
        },
      });

      return c.json({ ok: true });
    }),
  ),
);

// ---------------------------------------------------------------------------
// POST /live-activity/sync-registrations
// Reconciles a device's registrations against its current group membership,
// disabling rows for groups the device has left. Self-healing cleanup for the
// stale-registration leak where non-members keep receiving a group's pushes.
// ---------------------------------------------------------------------------
liveActivityRoute.post("/live-activity/sync-registrations", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const data = yield* decodeJsonBody(c, SyncRegistrationsRequestSchema);

      const disabled = yield* fromPromise(() =>
        disableStaleDeviceRegistrations(c.env.DB, data.deviceId, data.householdIds),
      );

      console.log(
        `[notifications] sync-registrations device=${data.deviceId} ` +
          `activeHouseholds=${data.householdIds.length} disabledRows=${disabled}`,
      );

      return c.json({ ok: true, disabled });
    }),
  ),
);

// ---------------------------------------------------------------------------
// POST /live-activity/heads-up
// "I'm about to shop" — fans out a Time Sensitive alert to every other member
// of the group. No shopping session is involved.
// ---------------------------------------------------------------------------
liveActivityRoute.post("/live-activity/heads-up", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const body = yield* decodeJsonBody(c, HeadsUpRequestSchema);

      yield* reconcileHouseholdRecipients(c.env.DB, body.householdId, body.recipientMemberIds);

      const devices = yield* fromPromise(() =>
        eligibleNotificationTokens(
          c.env.DB,
          body.householdId,
          body.sourceDeviceId,
          body.recipientMemberIds,
        ),
      );

      console.log(
        `[notifications] heads-up household=${body.householdId} ` +
          `excludeDevice=${body.sourceDeviceId ?? "none"} eligibleDevices=${devices.length}`,
      );

      const { sent, failed } = yield* fanOut(devices, (device) => {
        const token = device.push_notification_token!;
        return deliverPush({
          send: () =>
            sendHeadsUpNotification(c.env, token, {
              householdId: body.householdId,
              shopperName: body.shopperName,
              storeName: body.storeName,
            }),
          onThrow: (err) =>
            logApns(c.env.DB, {
              deviceId: device.device_id,
              event: "heads_up_notification",
              outcome: "failed",
              detail: String(err),
            }),
          onSent: (result) =>
            logApns(c.env.DB, {
              deviceId: device.device_id,
              event: "heads_up_notification",
              outcome: "sent",
              statusCode: result.statusCode,
              apnsId: result.apnsId,
            }),
          onExpiredToken: () => invalidateNotificationToken(c.env.DB, token),
          onFailed: (result) =>
            logApns(c.env.DB, {
              deviceId: device.device_id,
              event: "heads_up_notification",
              outcome: result.tokenExpired ? "expired" : "failed",
              statusCode: result.statusCode,
              apnsId: result.apnsId,
              detail: result.reason ?? result.detail,
            }),
        });
      });

      const telemetry = yield* Telemetry;
      yield* telemetry.capture({
        distinctId: body.sourceDeviceId ?? body.householdId,
        event: "shopping heads up sent",
        properties: {
          household_id: body.householdId,
          store_name: body.storeName ?? null,
          devices_notified: sent,
          devices_notification_failed: failed,
          $groups: { household: body.householdId },
        },
      });

      return c.json({ ok: true, sent, failed });
    }),
  ),
);

// ---------------------------------------------------------------------------
// POST /live-activity/register-update-token
// A running activity's per-activity update token, so we can update/end it.
// ---------------------------------------------------------------------------
liveActivityRoute.post("/live-activity/register-update-token", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const data = yield* decodeJsonBody(c, RegisterUpdateTokenRequestSchema);
      yield* fromPromise(() => upsertActivityToken(c.env.DB, data));
      return c.json({ ok: true });
    }),
  ),
);

// ---------------------------------------------------------------------------
// POST /live-activity/start
// Fan out push-to-start to every eligible device in the household.
// ---------------------------------------------------------------------------
liveActivityRoute.post("/live-activity/start", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const body = yield* decodeJsonBody(c, StartLiveActivityRequestSchema);
      const content = toContent(body);

      // Persist a snapshot for retries/diagnostics (CloudKit stays authoritative).
      yield* fromPromise(() =>
        saveSessionSnapshot(c.env.DB, {
          sessionId: body.sessionId,
          householdId: body.householdId,
          content,
          status: "Active",
          startedAt: body.startedAt,
        }),
      );

      yield* reconcileHouseholdRecipients(c.env.DB, body.householdId, body.recipientMemberIds);

      const devices = yield* fromPromise(() =>
        eligibleStartTokens(
          c.env.DB,
          body.householdId,
          body.sourceDeviceId,
          body.recipientMemberIds,
        ),
      );

      console.log(
        `[live-activity] start fanout household=${body.householdId} ` +
          `session=${body.sessionId} excludeDevice=${body.sourceDeviceId ?? "none"} ` +
          `eligibleDevices=${devices.length}`,
      );

      const { sent, failed } = yield* fanOut(devices, (device) => {
        const token = device.push_to_start_token!;
        return deliverPush({
          send: () =>
            sendStart(c.env, token, {
              content,
              attributesType: activityAttributesType(c.env),
              attributes: {
                householdId: body.householdId,
                sessionId: body.sessionId,
                startedByMemberId: body.startedByMemberId ?? null,
              },
            }),
          onThrow: (err) =>
            logApns(c.env.DB, {
              sessionId: body.sessionId,
              deviceId: device.device_id,
              event: "start",
              outcome: "failed",
              detail: String(err),
            }),
          onSent: (result) =>
            logApns(c.env.DB, {
              sessionId: body.sessionId,
              deviceId: device.device_id,
              event: "start",
              outcome: "sent",
              statusCode: result.statusCode,
              apnsId: result.apnsId,
            }),
          onExpiredToken: () => invalidatePushToStartToken(c.env.DB, token),
          onFailed: (result) =>
            logApns(c.env.DB, {
              sessionId: body.sessionId,
              deviceId: device.device_id,
              event: "start",
              outcome: result.tokenExpired ? "expired" : "failed",
              statusCode: result.statusCode,
              apnsId: result.apnsId,
              detail: result.reason ?? result.detail,
            }),
        });
      });

      const notifications = yield* sendShoppingTripNotificationFanout(c.env, {
        householdId: body.householdId,
        sessionId: body.sessionId,
        sourceDeviceId: body.sourceDeviceId,
        recipientMemberIds: body.recipientMemberIds,
        event: "started",
        startedByMemberId: body.startedByMemberId,
        shopperName: body.shopperName,
        storeName: body.storeName,
        itemsFound: body.itemsFound,
        itemsRemaining: body.itemsRemaining,
        totalItems: body.totalItems,
        outOfStockCount: body.outOfStockCount,
        replacedCount: body.replacedCount,
      });

      const telemetry = yield* Telemetry;
      yield* telemetry.capture({
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

      return c.json({
        ok: true,
        sent,
        failed,
        notificationsSent: notifications.sent,
        notificationsFailed: notifications.failed,
      });
    }),
  ),
);

// ---------------------------------------------------------------------------
// POST /live-activity/update
// Push an update to every running activity for this session.
// ---------------------------------------------------------------------------
liveActivityRoute.post("/live-activity/update", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const body = yield* decodeJsonBody(c, UpdateLiveActivityRequestSchema);
      const content = toContent(body);

      yield* fromPromise(() =>
        saveSessionSnapshot(c.env.DB, {
          sessionId: body.sessionId,
          householdId: body.householdId,
          content,
          status: "Active",
        }),
      );

      yield* reconcileSessionRecipients(c.env.DB, {
        householdId: body.householdId,
        sessionId: body.sessionId,
        recipientMemberIds: body.recipientMemberIds,
      });

      const activities = yield* fromPromise(() =>
        activityTokensForSession(
          c.env.DB,
          body.sessionId,
          body.householdId,
          body.recipientMemberIds,
        ),
      );

      const { sent, failed } = yield* fanOut(activities, (a) =>
        deliverPush({
          send: () => sendUpdate(c.env, a.update_token, content),
          onThrow: (err) =>
            logApns(c.env.DB, {
              sessionId: body.sessionId,
              deviceId: a.device_id,
              event: "update",
              outcome: "failed",
              detail: String(err),
            }),
          onSent: (result) =>
            logApns(c.env.DB, {
              sessionId: body.sessionId,
              deviceId: a.device_id,
              event: "update",
              outcome: "sent",
              statusCode: result.statusCode,
              apnsId: result.apnsId,
            }),
          onExpiredToken: () => invalidateUpdateToken(c.env.DB, a.update_token),
          onFailed: (result) =>
            logApns(c.env.DB, {
              sessionId: body.sessionId,
              deviceId: a.device_id,
              event: "update",
              outcome: result.tokenExpired ? "expired" : "failed",
              statusCode: result.statusCode,
              detail: result.reason ?? result.detail,
            }),
        }),
      );

      const telemetry = yield* Telemetry;
      yield* telemetry.capture({
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

      return c.json({ ok: true, sent, failed });
    }),
  ),
);

// ---------------------------------------------------------------------------
// POST /live-activity/end
// End every running activity for this session with a completed/cancelled state.
// ---------------------------------------------------------------------------
liveActivityRoute.post("/live-activity/end", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const body = yield* decodeJsonBody(c, EndLiveActivityRequestSchema);

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

      yield* fromPromise(() =>
        saveSessionSnapshot(c.env.DB, {
          sessionId: body.sessionId,
          householdId: body.householdId,
          content,
          status,
        }),
      );

      yield* reconcileSessionRecipients(c.env.DB, {
        householdId: body.householdId,
        sessionId: body.sessionId,
        recipientMemberIds: body.recipientMemberIds,
      });

      const activities = yield* fromPromise(() =>
        activityTokensForSession(
          c.env.DB,
          body.sessionId,
          body.householdId,
          body.recipientMemberIds,
        ),
      );

      const { sent, failed } = yield* fanOut(activities, (a) =>
        deliverPush({
          send: () => sendEnd(c.env, a.update_token, content),
          onThrow: (err) =>
            logApns(c.env.DB, {
              sessionId: body.sessionId,
              deviceId: a.device_id,
              event: "end",
              outcome: "failed",
              detail: String(err),
            }),
          onSent: (result) =>
            logApns(c.env.DB, {
              sessionId: body.sessionId,
              deviceId: a.device_id,
              event: "end",
              outcome: "sent",
              statusCode: result.statusCode,
              apnsId: result.apnsId,
            }),
          onExpiredToken: () => invalidateUpdateToken(c.env.DB, a.update_token),
          onFailed: (result) =>
            logApns(c.env.DB, {
              sessionId: body.sessionId,
              deviceId: a.device_id,
              event: "end",
              outcome: result.tokenExpired ? "expired" : "failed",
              statusCode: result.statusCode,
              detail: result.reason ?? result.detail,
            }),
        }),
      );

      const notifications = yield* sendShoppingTripNotificationFanout(c.env, {
        householdId: body.householdId,
        sessionId: body.sessionId,
        sourceDeviceId: body.sourceDeviceId,
        recipientMemberIds: body.recipientMemberIds,
        event: body.status === "completed" ? "completed" : "cancelled",
        shopperName: body.shopperName,
        storeName: body.storeName,
        itemsFound: body.itemsFound,
        itemsRemaining: body.itemsRemaining,
        totalItems: body.totalItems,
        outOfStockCount: body.outOfStockCount,
        replacedCount: body.replacedCount,
      });

      const telemetry = yield* Telemetry;
      yield* telemetry.capture({
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
          completion_rate:
            body.totalItems > 0
              ? Math.round((body.itemsFound / body.totalItems) * 100)
              : null,
          devices_notified: notifications.sent,
          devices_notification_failed: notifications.failed,
          $groups: { household: body.householdId },
        },
      });

      return c.json({
        ok: true,
        sent,
        failed,
        notificationsSent: notifications.sent,
        notificationsFailed: notifications.failed,
      });
    }),
  ),
);

// ---------------------------------------------------------------------------
// GET /live-activity/debug/household/:id
// Diagnostic view of registered tokens for a household — helps debug
// notification delivery issues. Not exposed in the app UI.
// ---------------------------------------------------------------------------
liveActivityRoute.get("/live-activity/debug/household/:id", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const householdId = c.req.param("id");

      const devices = yield* fromPromise(() =>
        c.env.DB.prepare(
          `SELECT device_id, member_id, household_id,
                  push_to_start_token IS NOT NULL AS has_start_token,
                  push_notification_token IS NOT NULL AS has_notification_token,
                  live_activities_enabled, notifications_enabled,
                  token_valid, notification_token_valid,
                  app_version, platform, updated_at
           FROM device_tokens WHERE household_id = ?1`,
        )
          .bind(householdId)
          .all(),
      );

      const recentLogs = yield* fromPromise(() =>
        c.env.DB.prepare(
          `SELECT event, outcome, device_id, status_code, detail, created_at
           FROM apns_log
           WHERE session_id IN (
             SELECT session_id FROM session_snapshots WHERE household_id = ?1
           )
           ORDER BY created_at DESC LIMIT 20`,
        )
          .bind(householdId)
          .all(),
      );

      return c.json({
        devices: devices.results ?? [],
        recentLogs: recentLogs.results ?? [],
      });
    }),
  ),
);
