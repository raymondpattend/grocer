import { Effect } from "effect";
import type { PostHog } from "posthog-node";
import type { Env } from "../env.js";
import { attemptPromise, fromPromise } from "../effect/interop.js";
import { createPostHogClient } from "../lib/posthog.js";
import { sendRetentionNotification } from "../services/apns.js";
import {
  invalidateNotificationToken,
  logApns,
  markRetentionPushSent,
  retentionCandidates,
  unseenActivityForMember,
} from "../db/liveActivityTokens.js";

/** PostHog flag controlling the inactivity window (A/B testable). The variant
 *  key or payload is interpreted as a number of days; falls back to 3. */
const INACTIVITY_FLAG = "retention_nudge_inactivity_days";
const DEFAULT_INACTIVITY_DAYS = 3;

/** Don't nudge the same (device, household) more than once per this window. */
const FREQUENCY_CAP_DAYS = 7;

/** Only deliver between these local hours so we never wake people at 3am. */
const QUIET_START_HOUR = 9; // inclusive
const QUIET_END_HOUR = 20; // exclusive

/** Assumed offset for devices that never reported one (≈ US Central). */
const DEFAULT_TZ_OFFSET_MINUTES = -360;

const DAY_MS = 24 * 60 * 60 * 1000;

function localHour(nowMs: number, tzOffsetMinutes: number | null): number {
  const offset = tzOffsetMinutes ?? DEFAULT_TZ_OFFSET_MINUTES;
  return new Date(nowMs + offset * 60_000).getUTCHours();
}

async function resolveThresholdDays(
  posthog: PostHog,
  memberId: string,
): Promise<number> {
  try {
    const variant = await posthog.getFeatureFlag(INACTIVITY_FLAG, memberId);
    if (typeof variant === "string") {
      const n = parseInt(variant, 10);
      if (Number.isFinite(n) && n > 0) return n;
    }
    const payload = await posthog.getFeatureFlagPayload(INACTIVITY_FLAG, memberId);
    if (typeof payload === "number" && payload > 0) return payload;
    if (typeof payload === "string") {
      const n = parseInt(payload, 10);
      if (Number.isFinite(n) && n > 0) return n;
    }
    if (payload && typeof payload === "object" && "days" in payload) {
      const n = Number((payload as { days: unknown }).days);
      if (Number.isFinite(n) && n > 0) return n;
    }
  } catch (err) {
    console.error("[retention] flag eval failed:", err);
  }
  return DEFAULT_INACTIVITY_DAYS;
}

export interface RetentionSweepResult {
  candidates: number;
  sent: number;
  failed: number;
  skipped: number;
}

/**
 * Sends one retention push and records its outcome, resolving to whether it was
 * delivered. Mirrors the original try/logApns branches: a thrown send logs a
 * failure; a dead token is invalidated before logging.
 */
function deliverRetentionPush(
  env: Env,
  db: D1Database,
  device: { device_id: string; household_id: string },
  token: string,
  unseen: { itemCount: number; lastActorName?: string | null },
  notifId: string,
): Effect.Effect<boolean> {
  return Effect.gen(function* () {
    // Mirror the original single try/catch that wrapped BOTH the send and its
    // follow-up D1 writes: a throw from any of them (a transient D1 error, say)
    // is swallowed by a compensating "failed" log and the sweep keeps going,
    // and the `ok` computed before the throw still decides sent vs failed. So
    // the post-send writes use `attemptPromise` (recoverable), routed to the
    // compensator; only the compensating log itself is unprotected (as in the
    // original, whose catch block had no further guard).
    let ok = false;
    yield* Effect.gen(function* () {
      const apns = yield* attemptPromise(() =>
        sendRetentionNotification(env, token, {
          householdId: device.household_id,
          newItemCount: unseen.itemCount,
          actorName: unseen.lastActorName,
          notifId,
        }),
      );
      ok = apns.ok;
      if (apns.ok) {
        yield* attemptPromise(() =>
          logApns(db, {
            deviceId: device.device_id,
            event: "retention_notification",
            outcome: "sent",
            statusCode: apns.statusCode,
            apnsId: apns.apnsId,
          }),
        );
      } else {
        if (apns.tokenExpired) {
          yield* attemptPromise(() => invalidateNotificationToken(db, token));
        }
        yield* attemptPromise(() =>
          logApns(db, {
            deviceId: device.device_id,
            event: "retention_notification",
            outcome: apns.tokenExpired ? "expired" : "failed",
            statusCode: apns.statusCode,
            apnsId: apns.apnsId,
            detail: apns.reason ?? apns.detail,
          }),
        );
      }
    }).pipe(
      Effect.catchAll((err) =>
        fromPromise(() =>
          logApns(db, {
            deviceId: device.device_id,
            event: "retention_notification",
            outcome: "failed",
            detail: String(err),
          }),
        ),
      ),
    );

    return ok;
  });
}

/**
 * One pass over all notifiable devices: for each, if the user has been inactive
 * past the (flag-driven) threshold AND other members added items meanwhile, and
 * it's daytime locally and we haven't nudged them recently, send a push.
 */
function retentionSweep(env: Env): Effect.Effect<RetentionSweepResult> {
  return Effect.gen(function* () {
    const db = env.DB;
    const posthog = createPostHogClient(env);
    const nowMs = Date.now();

    const candidates = yield* fromPromise(() => retentionCandidates(db));
    const result: RetentionSweepResult = {
      candidates: candidates.length,
      sent: 0,
      failed: 0,
      skipped: 0,
    };

    for (const device of candidates) {
      const token = device.push_notification_token;
      const lastOpened = device.last_opened_at;
      if (!token || !lastOpened) {
        result.skipped++;
        continue;
      }

      // Daytime-local gate.
      const hour = localHour(nowMs, device.tz_offset_minutes);
      if (hour < QUIET_START_HOUR || hour >= QUIET_END_HOUR) {
        result.skipped++;
        continue;
      }

      // Frequency cap.
      if (device.last_retention_push_at) {
        const sinceLast = nowMs - new Date(device.last_retention_push_at).getTime();
        if (sinceLast < FREQUENCY_CAP_DAYS * DAY_MS) {
          result.skipped++;
          continue;
        }
      }

      // Inactivity threshold (A/B testable).
      const thresholdDays = yield* fromPromise(() =>
        resolveThresholdDays(posthog, device.member_id),
      );
      const daysInactive = (nowMs - new Date(lastOpened).getTime()) / DAY_MS;
      if (daysInactive < thresholdDays) {
        result.skipped++;
        continue;
      }

      // Did other members add anything since they last looked?
      const unseen = yield* fromPromise(() =>
        unseenActivityForMember(db, {
          householdId: device.household_id,
          memberId: device.member_id,
          sinceISO: lastOpened,
        }),
      );
      if (unseen.itemCount <= 0) {
        result.skipped++;
        continue;
      }

      const notifId = crypto.randomUUID();
      const delivered = yield* deliverRetentionPush(
        env,
        db,
        device,
        token,
        unseen,
        notifId,
      );

      if (delivered) {
        result.sent++;
        yield* fromPromise(() =>
          markRetentionPushSent(db, {
            deviceId: device.device_id,
            householdId: device.household_id,
          }),
        );
        posthog.capture({
          distinctId: device.member_id,
          event: "retention_notification_sent",
          properties: {
            new_item_count: unseen.itemCount,
            days_inactive: Math.round(daysInactive),
            inactivity_threshold_days: thresholdDays,
            household_id: device.household_id,
            notif_id: notifId,
            $groups: { household: device.household_id },
          },
        });
      } else {
        result.failed++;
      }
    }

    yield* fromPromise(() => posthog.shutdown());
    return result;
  });
}

/** Runs the retention sweep as an Effect, returning its summary as a promise for
 *  the Cloudflare Cron trigger. */
export function runRetentionSweep(env: Env): Promise<RetentionSweepResult> {
  return Effect.runPromise(retentionSweep(env));
}
