import type { LiveActivityContent } from "@grocer/shared";

/**
 * Data-access helpers for the Live Activity support tables.
 * Thin wrappers over D1 — no business logic beyond persistence.
 */

export interface DeviceTokenRow {
  device_id: string;
  household_id: string;
  member_id: string;
  push_to_start_token: string | null;
  push_notification_token: string | null;
  live_activities_enabled: number;
  notifications_enabled: number;
  app_version: string | null;
  platform: string;
  token_valid: number;
  notification_token_valid: number;
  last_opened_at: string | null;
  last_retention_push_at: string | null;
  tz_offset_minutes: number | null;
  /** When this member was first observed missing from a household roster, used
   *  by the grace-period reconcile. NULL when present / confirmed. */
  roster_missing_since: string | null;
  created_at: string;
  updated_at: string;
}

/** How long a member must be continuously absent from a household's roster
 *  before the reconcile disables their delivery rows. Absorbs transient CloudKit
 *  roster lag so a not-yet-synced member is never wrongly cut off; a genuinely
 *  removed member is disabled once they've been gone this long. */
const ROSTER_RECONCILE_GRACE_MS = 48 * 60 * 60 * 1000;

export interface ActivityTokenRow {
  device_id: string;
  session_id: string;
  household_id: string;
  member_id: string;
  update_token: string;
  token_valid: number;
  created_at: string;
  updated_at: string;
}

const now = () => new Date().toISOString();

function uniqueMemberIds(memberIds?: string[]): string[] | undefined {
  if (memberIds === undefined) return undefined;
  return [...new Set(memberIds.filter(Boolean))];
}

function memberFilterClause(memberIds: string[] | undefined, startIndex: number) {
  if (memberIds === undefined) return "";
  if (memberIds.length === 0) return " AND 0";
  const placeholders = memberIds.map((_, idx) => `?${startIndex + idx}`).join(", ");
  return ` AND member_id IN (${placeholders})`;
}

export async function upsertDeviceToken(
  db: D1Database,
  input: {
    deviceId: string;
    householdId: string;
    memberId: string;
    pushToStartToken?: string | null;
    pushNotificationToken?: string | null;
    familyLiveActivitiesEnabled: boolean;
    notificationsEnabled?: boolean;
    appVersion?: string;
    platform?: string;
    tzOffsetMinutes?: number;
  },
): Promise<void> {
  const ts = now();
  await db
    .prepare(
      `INSERT INTO device_tokens
        (device_id, household_id, member_id, push_to_start_token,
         push_notification_token, live_activities_enabled, notifications_enabled,
         app_version, platform, token_valid, notification_token_valid,
         tz_offset_minutes, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, COALESCE(?7, 0), ?8, ?9,
         CASE WHEN ?4 IS NULL THEN 0 ELSE 1 END,
         CASE WHEN ?5 IS NULL THEN 0 ELSE 1 END,
         ?11, ?10, ?10)
       ON CONFLICT(device_id, household_id) DO UPDATE SET
         member_id = ?3,
         push_to_start_token = COALESCE(?4, device_tokens.push_to_start_token),
         push_notification_token = COALESCE(?5, device_tokens.push_notification_token),
         live_activities_enabled = ?6,
         notifications_enabled = COALESCE(?7, device_tokens.notifications_enabled),
         app_version = ?8,
         platform = ?9,
         token_valid = CASE WHEN ?4 IS NOT NULL THEN 1 ELSE device_tokens.token_valid END,
         notification_token_valid = CASE WHEN ?5 IS NOT NULL THEN 1 ELSE device_tokens.notification_token_valid END,
         tz_offset_minutes = COALESCE(?11, device_tokens.tz_offset_minutes),
         -- A device registering for itself is authoritative proof the member is
         -- present, so clear any pending grace-period stale marker.
         roster_missing_since = NULL,
         updated_at = ?10`,
    )
    .bind(
      input.deviceId,
      input.householdId,
      input.memberId,
      input.pushToStartToken ?? null,
      input.pushNotificationToken ?? null,
      input.familyLiveActivitiesEnabled ? 1 : 0,
      input.notificationsEnabled === undefined
        ? null
        : input.notificationsEnabled
          ? 1
          : 0,
      input.appVersion ?? null,
      input.platform ?? "iOS",
      ts,
      input.tzOffsetMinutes ?? null,
    )
    .run();
}

/** Devices in a household that are eligible to RECEIVE a push-to-start. */
export async function eligibleStartTokens(
  db: D1Database,
  householdId: string,
  excludeDeviceId?: string,
  recipientMemberIds?: string[],
): Promise<DeviceTokenRow[]> {
  const members = uniqueMemberIds(recipientMemberIds);
  const memberClause = memberFilterClause(members, excludeDeviceId ? 3 : 2);
  const where = excludeDeviceId
    ? `WHERE household_id = ?1
          AND device_id <> ?2
          ${memberClause}
          AND live_activities_enabled = 1
          AND token_valid = 1
          AND push_to_start_token IS NOT NULL`
    : `WHERE household_id = ?1
          ${memberClause}
          AND live_activities_enabled = 1
          AND token_valid = 1
          AND push_to_start_token IS NOT NULL`;

  const stmt = db.prepare(`SELECT * FROM device_tokens ${where}`);
  const { results } = excludeDeviceId
    ? await stmt.bind(householdId, excludeDeviceId, ...(members ?? [])).all<DeviceTokenRow>()
    : await stmt.bind(householdId, ...(members ?? [])).all<DeviceTokenRow>();
  return results ?? [];
}

/** Devices in a household that are eligible to receive ordinary alert pushes. */
export async function eligibleNotificationTokens(
  db: D1Database,
  householdId: string,
  excludeDeviceId?: string,
  recipientMemberIds?: string[],
): Promise<DeviceTokenRow[]> {
  const members = uniqueMemberIds(recipientMemberIds);
  const memberClause = memberFilterClause(members, excludeDeviceId ? 3 : 2);
  const where = excludeDeviceId
    ? `WHERE household_id = ?1
          AND device_id <> ?2
          ${memberClause}
          AND notifications_enabled = 1
          AND notification_token_valid = 1
          AND push_notification_token IS NOT NULL`
    : `WHERE household_id = ?1
          ${memberClause}
          AND notifications_enabled = 1
          AND notification_token_valid = 1
          AND push_notification_token IS NOT NULL`;

  const stmt = db.prepare(`SELECT * FROM device_tokens ${where}`);
  const { results } = excludeDeviceId
    ? await stmt.bind(householdId, excludeDeviceId, ...(members ?? [])).all<DeviceTokenRow>()
    : await stmt.bind(householdId, ...(members ?? [])).all<DeviceTokenRow>();
  return results ?? [];
}

export async function upsertActivityToken(
  db: D1Database,
  input: {
    deviceId: string;
    sessionId: string;
    householdId: string;
    memberId: string;
    updateToken: string;
  },
): Promise<void> {
  const ts = now();
  await db
    .prepare(
      `INSERT INTO activity_tokens
        (device_id, session_id, household_id, member_id, update_token,
         token_valid, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, ?6)
       ON CONFLICT(device_id, session_id) DO UPDATE SET
         update_token = ?5,
         token_valid = 1,
         updated_at = ?6`,
    )
    .bind(
      input.deviceId,
      input.sessionId,
      input.householdId,
      input.memberId,
      input.updateToken,
      ts,
    )
    .run();
}

/** Update tokens for every running Live Activity on a given session. */
export async function activityTokensForSession(
  db: D1Database,
  sessionId: string,
  householdId?: string,
  recipientMemberIds?: string[],
): Promise<ActivityTokenRow[]> {
  const members = uniqueMemberIds(recipientMemberIds);
  const householdClause = householdId ? " AND household_id = ?2" : "";
  const memberStart = householdId ? 3 : 2;
  const memberClause = memberFilterClause(members, memberStart);
  const { results } = await db
    .prepare(
      `SELECT * FROM activity_tokens
        WHERE session_id = ?1
          ${householdClause}
          ${memberClause}
          AND token_valid = 1`,
    )
    .bind(sessionId, ...(householdId ? [householdId] : []), ...(members ?? []))
    .all<ActivityTokenRow>();
  return results ?? [];
}

/**
 * Disables push/notification delivery for every registration of `deviceId`
 * whose household is NOT in `activeHouseholdIds`. This reconciles stale rows
 * left behind when a device stops being a member of a group — without it, those
 * rows keep matching the household-scoped fan-out and the device keeps getting
 * that group's trip notifications and Live Activities.
 *
 * Returns the number of rows disabled.
 */
export async function disableStaleDeviceRegistrations(
  db: D1Database,
  deviceId: string,
  activeHouseholdIds: string[],
): Promise<number> {
  const ts = now();
  // De-dupe to keep the placeholder list tight.
  const active = [...new Set(activeHouseholdIds)];

  const setClause = `notifications_enabled = 0,
        live_activities_enabled = 0,
        token_valid = 0,
        notification_token_valid = 0,
        updated_at = ?`;

  if (active.length === 0) {
    const result = await db
      .prepare(
        `UPDATE device_tokens SET ${setClause} WHERE device_id = ?`,
      )
      .bind(ts, deviceId)
      .run();
    return result.meta.changes ?? 0;
  }

  const placeholders = active.map(() => "?").join(", ");
  const result = await db
    .prepare(
      `UPDATE device_tokens SET ${setClause}
        WHERE device_id = ? AND household_id NOT IN (${placeholders})`,
    )
    .bind(ts, deviceId, ...active)
    .run();
  return result.meta.changes ?? 0;
}

/**
 * Reconciles a household's delivery rows against its current roster, disabling
 * rows for members who have left. Unlike device-scoped sync, this heals
 * removed/left users even if their own app never opens again.
 *
 * It is **grace-period based and non-destructive on the hot path**: the roster
 * comes from a single shopper's device and can transiently miss a member whose
 * CloudKit record hasn't synced yet. Disabling immediately on that snapshot is
 * what cut legitimate members off from trips. Instead, on each reconcile we:
 *   1. clear the stale marker for members present this round (they're confirmed),
 *   2. stamp newly-absent members with "missing since now" WITHOUT disabling, and
 *   3. disable only members who have stayed absent past the grace window.
 * A member whose own device re-registers also clears the marker (see
 * `upsertDeviceToken`), so only genuinely-gone members ever reach step 3.
 *
 * `activeMemberIds === undefined` means the caller did not provide an
 * authoritative roster, so no cleanup is attempted. An explicit empty array is
 * authoritative (no members) and runs the same grace-period flow for every row.
 *
 * Returns the number of rows actually disabled this call (0 while members are
 * still inside the grace window).
 */
export async function disableHouseholdRegistrationsExceptMembers(
  db: D1Database,
  householdId: string,
  activeMemberIds?: string[],
): Promise<number> {
  const active = uniqueMemberIds(activeMemberIds);
  if (active === undefined) return 0;

  const ts = now();
  const graceCutoff = new Date(Date.now() - ROSTER_RECONCILE_GRACE_MS).toISOString();
  const hasRoster = active.length > 0;
  const placeholders = active.map(() => "?").join(", ");
  // Scope clause shared by the stamp + disable steps. With a roster we target
  // everyone NOT in it; with an empty roster every row in the household.
  const absentClause = hasRoster
    ? `household_id = ? AND member_id NOT IN (${placeholders})`
    : `household_id = ?`;

  // 1. Members present this round → clear any pending marker so a momentary
  //    absence never accumulates toward the grace deadline.
  if (hasRoster) {
    await db
      .prepare(
        `UPDATE device_tokens
            SET roster_missing_since = NULL, updated_at = ?
          WHERE household_id = ?
            AND member_id IN (${placeholders})
            AND roster_missing_since IS NOT NULL`,
      )
      .bind(ts, householdId, ...active)
      .run();
  }

  // 2. Members newly absent → start the grace clock, but keep delivery on. Only
  //    stamp rows that are still active and not already being tracked.
  await db
    .prepare(
      `UPDATE device_tokens
          SET roster_missing_since = ?, updated_at = ?
        WHERE ${absentClause}
          AND roster_missing_since IS NULL
          AND (notifications_enabled = 1 OR live_activities_enabled = 1)`,
    )
    .bind(ts, ts, householdId, ...active)
    .run();

  // 3. Members absent past the grace window → now safe to disable.
  const result = await db
    .prepare(
      `UPDATE device_tokens
          SET notifications_enabled = 0,
              live_activities_enabled = 0,
              token_valid = 0,
              notification_token_valid = 0,
              updated_at = ?
        WHERE ${absentClause}
          AND roster_missing_since IS NOT NULL
          AND roster_missing_since <= ?`,
    )
    .bind(ts, householdId, ...active, graceCutoff)
    .run();
  return result.meta.changes ?? 0;
}

/**
 * Invalidates per-activity update tokens for members outside the current
 * session household roster. These are what drive update/end pushes after a
 * Live Activity has already been started.
 */
export async function invalidateSessionActivityTokensExceptMembers(
  db: D1Database,
  input: {
    sessionId: string;
    householdId: string;
    activeMemberIds?: string[];
  },
): Promise<number> {
  const active = uniqueMemberIds(input.activeMemberIds);
  if (active === undefined) return 0;

  const ts = now();
  const setClause = `token_valid = 0, updated_at = ?`;

  if (active.length === 0) {
    const result = await db
      .prepare(
        `UPDATE activity_tokens SET ${setClause}
          WHERE session_id = ? AND household_id = ?`,
      )
      .bind(ts, input.sessionId, input.householdId)
      .run();
    return result.meta.changes ?? 0;
  }

  const placeholders = active.map(() => "?").join(", ");
  const result = await db
    .prepare(
      `UPDATE activity_tokens SET ${setClause}
        WHERE session_id = ? AND household_id = ? AND member_id NOT IN (${placeholders})`,
    )
    .bind(ts, input.sessionId, input.householdId, ...active)
    .run();
  return result.meta.changes ?? 0;
}

export async function invalidatePushToStartToken(
  db: D1Database,
  token: string,
): Promise<void> {
  await db
    .prepare(
      `UPDATE device_tokens SET token_valid = 0, updated_at = ?2
        WHERE push_to_start_token = ?1`,
    )
    .bind(token, now())
    .run();
}

export async function invalidateUpdateToken(
  db: D1Database,
  token: string,
): Promise<void> {
  await db
    .prepare(
      `UPDATE activity_tokens SET token_valid = 0, updated_at = ?2
        WHERE update_token = ?1`,
    )
    .bind(token, now())
    .run();
}

export async function invalidateNotificationToken(
  db: D1Database,
  token: string,
): Promise<void> {
  await db
    .prepare(
      `UPDATE device_tokens SET notification_token_valid = 0, updated_at = ?2
        WHERE push_notification_token = ?1`,
    )
    .bind(token, now())
    .run();
}

export async function saveSessionSnapshot(
  db: D1Database,
  input: {
    sessionId: string;
    householdId: string;
    content: LiveActivityContent;
    status: string;
    startedAt?: string;
  },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO session_snapshots
        (session_id, household_id, content_json, status, started_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6)
       ON CONFLICT(session_id) DO UPDATE SET
         content_json = ?3,
         status = ?4,
         updated_at = ?6`,
    )
    .bind(
      input.sessionId,
      input.householdId,
      JSON.stringify(input.content),
      input.status,
      input.startedAt ?? null,
      now(),
    )
    .run();
}

export async function logApns(
  db: D1Database,
  input: {
    sessionId?: string;
    deviceId?: string;
    event:
      | "start"
      | "update"
      | "end"
      | "start_notification"
      | "end_notification"
      | "heads_up_notification"
      | "retention_notification";
    outcome: "sent" | "failed" | "expired";
    statusCode?: number;
    apnsId?: string;
    detail?: string;
  },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO apns_log
        (id, session_id, device_id, event, outcome, status_code, apns_id, detail, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`,
    )
    .bind(
      crypto.randomUUID(),
      input.sessionId ?? null,
      input.deviceId ?? null,
      input.event,
      input.outcome,
      input.statusCode ?? null,
      input.apnsId ?? null,
      input.detail ?? null,
      now(),
    )
    .run();
}

// ---------------------------------------------------------------------------
// Retention — re-engagement nudges
// ---------------------------------------------------------------------------

/** Stamp last_opened_at (and refresh tz) for every registration of this device.
 *  Called from the foreground heartbeat. */
export async function markDeviceOpened(
  db: D1Database,
  input: { deviceId: string; tzOffsetMinutes?: number },
): Promise<void> {
  const ts = now();
  await db
    .prepare(
      `UPDATE device_tokens
         SET last_opened_at = ?2,
             tz_offset_minutes = COALESCE(?3, tz_offset_minutes),
             updated_at = ?2
       WHERE device_id = ?1`,
    )
    .bind(input.deviceId, ts, input.tzOffsetMinutes ?? null)
    .run();
}

/** Record that `actor` added `itemCount` items to a shared household's list. */
export async function insertListActivity(
  db: D1Database,
  input: {
    householdId: string;
    actorMemberId: string;
    actorDisplayName?: string;
    itemCount: number;
  },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO list_activity
        (id, household_id, actor_member_id, actor_display_name, item_count, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
    )
    .bind(
      crypto.randomUUID(),
      input.householdId,
      input.actorMemberId,
      input.actorDisplayName ?? null,
      input.itemCount,
      now(),
    )
    .run();
}

/** Devices that could be nudged: opted into notifications, have a valid token,
 *  and have opened the app at least once (so we know how long they've been away). */
export async function retentionCandidates(
  db: D1Database,
): Promise<DeviceTokenRow[]> {
  const { results } = await db
    .prepare(
      `SELECT * FROM device_tokens
        WHERE notifications_enabled = 1
          AND notification_token_valid = 1
          AND push_notification_token IS NOT NULL
          AND last_opened_at IS NOT NULL`,
    )
    .all<DeviceTokenRow>();
  return results ?? [];
}

export interface UnseenActivity {
  itemCount: number;
  entries: number;
  lastActorName: string | null;
}

/** Sum of items OTHER members added to this household since `sinceISO`. */
export async function unseenActivityForMember(
  db: D1Database,
  input: { householdId: string; memberId: string; sinceISO: string },
): Promise<UnseenActivity> {
  const row = await db
    .prepare(
      `SELECT COALESCE(SUM(item_count), 0) AS item_count,
              COUNT(*) AS entries,
              (SELECT actor_display_name FROM list_activity
                 WHERE household_id = ?1 AND actor_member_id <> ?2 AND created_at > ?3
                 ORDER BY created_at DESC LIMIT 1) AS last_actor_name
         FROM list_activity
        WHERE household_id = ?1 AND actor_member_id <> ?2 AND created_at > ?3`,
    )
    .bind(input.householdId, input.memberId, input.sinceISO)
    .first<{ item_count: number; entries: number; last_actor_name: string | null }>();

  return {
    itemCount: row?.item_count ?? 0,
    entries: row?.entries ?? 0,
    lastActorName: row?.last_actor_name ?? null,
  };
}

/** Records that a retention push was just sent to this (device, household). */
export async function markRetentionPushSent(
  db: D1Database,
  input: { deviceId: string; householdId: string },
): Promise<void> {
  const ts = now();
  await db
    .prepare(
      `UPDATE device_tokens SET last_retention_push_at = ?3, updated_at = ?3
        WHERE device_id = ?1 AND household_id = ?2`,
    )
    .bind(input.deviceId, input.householdId, ts)
    .run();
}

export async function saveFeedback(
  db: D1Database,
  input: {
    message: string;
    email?: string;
    appVersion?: string;
    device?: string;
  },
): Promise<void> {
  await db
    .prepare(
      `INSERT INTO feedback (id, message, email, app_version, device, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
    )
    .bind(
      crypto.randomUUID(),
      input.message,
      input.email ?? null,
      input.appVersion ?? null,
      input.device ?? null,
      now(),
    )
    .run();
}
