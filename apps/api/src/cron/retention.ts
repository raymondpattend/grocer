import type { PostHog } from "posthog-node";
import type { Env } from "../env.js";
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
 * One pass over all notifiable devices: for each, if the user has been inactive
 * past the (flag-driven) threshold AND other members added items meanwhile, and
 * it's daytime locally and we haven't nudged them recently, send a push.
 */
export async function runRetentionSweep(env: Env): Promise<RetentionSweepResult> {
  const db = env.DB;
  const posthog = createPostHogClient(env);
  const nowMs = Date.now();

  const candidates = await retentionCandidates(db);
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
    const thresholdDays = await resolveThresholdDays(posthog, device.member_id);
    const daysInactive = (nowMs - new Date(lastOpened).getTime()) / DAY_MS;
    if (daysInactive < thresholdDays) {
      result.skipped++;
      continue;
    }

    // Did other members add anything since they last looked?
    const unseen = await unseenActivityForMember(db, {
      householdId: device.household_id,
      memberId: device.member_id,
      sinceISO: lastOpened,
    });
    if (unseen.itemCount <= 0) {
      result.skipped++;
      continue;
    }

    const notifId = crypto.randomUUID();
    let ok = false;
    try {
      const apns = await sendRetentionNotification(env, token, {
        householdId: device.household_id,
        newItemCount: unseen.itemCount,
        actorName: unseen.lastActorName,
        notifId,
      });
      ok = apns.ok;
      if (apns.ok) {
        await logApns(db, {
          deviceId: device.device_id,
          event: "retention_notification",
          outcome: "sent",
          statusCode: apns.statusCode,
          apnsId: apns.apnsId,
        });
      } else {
        if (apns.tokenExpired) await invalidateNotificationToken(db, token);
        await logApns(db, {
          deviceId: device.device_id,
          event: "retention_notification",
          outcome: apns.tokenExpired ? "expired" : "failed",
          statusCode: apns.statusCode,
          apnsId: apns.apnsId,
          detail: apns.reason ?? apns.detail,
        });
      }
    } catch (err) {
      await logApns(db, {
        deviceId: device.device_id,
        event: "retention_notification",
        outcome: "failed",
        detail: String(err),
      });
    }

    if (ok) {
      result.sent++;
      await markRetentionPushSent(db, {
        deviceId: device.device_id,
        householdId: device.household_id,
      });
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

  await posthog.shutdown();
  return result;
}
