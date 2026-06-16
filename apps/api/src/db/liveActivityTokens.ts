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
  created_at: string;
  updated_at: string;
}

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
  },
): Promise<void> {
  const ts = now();
  await db
    .prepare(
      `INSERT INTO device_tokens
        (device_id, household_id, member_id, push_to_start_token,
         push_notification_token, live_activities_enabled, notifications_enabled,
         app_version, platform, token_valid, notification_token_valid,
         created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, COALESCE(?7, 0), ?8, ?9,
         CASE WHEN ?4 IS NULL THEN 0 ELSE 1 END,
         CASE WHEN ?5 IS NULL THEN 0 ELSE 1 END,
         ?10, ?10)
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
    )
    .run();
}

/** Devices in a household that are eligible to RECEIVE a push-to-start. */
export async function eligibleStartTokens(
  db: D1Database,
  householdId: string,
  excludeDeviceId?: string,
): Promise<DeviceTokenRow[]> {
  const where = excludeDeviceId
    ? `WHERE household_id = ?1
          AND device_id <> ?2
          AND live_activities_enabled = 1
          AND token_valid = 1
          AND push_to_start_token IS NOT NULL`
    : `WHERE household_id = ?1
          AND live_activities_enabled = 1
          AND token_valid = 1
          AND push_to_start_token IS NOT NULL`;

  const stmt = db.prepare(`SELECT * FROM device_tokens ${where}`);
  const { results } = excludeDeviceId
    ? await stmt.bind(householdId, excludeDeviceId).all<DeviceTokenRow>()
    : await stmt.bind(householdId).all<DeviceTokenRow>();
  return results ?? [];
}

/** Devices in a household that are eligible to receive ordinary alert pushes. */
export async function eligibleNotificationTokens(
  db: D1Database,
  householdId: string,
  excludeDeviceId?: string,
): Promise<DeviceTokenRow[]> {
  const where = excludeDeviceId
    ? `WHERE household_id = ?1
          AND device_id <> ?2
          AND notifications_enabled = 1
          AND notification_token_valid = 1
          AND push_notification_token IS NOT NULL`
    : `WHERE household_id = ?1
          AND notifications_enabled = 1
          AND notification_token_valid = 1
          AND push_notification_token IS NOT NULL`;

  const stmt = db.prepare(`SELECT * FROM device_tokens ${where}`);
  const { results } = excludeDeviceId
    ? await stmt.bind(householdId, excludeDeviceId).all<DeviceTokenRow>()
    : await stmt.bind(householdId).all<DeviceTokenRow>();
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
): Promise<ActivityTokenRow[]> {
  const { results } = await db
    .prepare(
      `SELECT * FROM activity_tokens
        WHERE session_id = ?1 AND token_valid = 1`,
    )
    .bind(sessionId)
    .all<ActivityTokenRow>();
  return results ?? [];
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
      | "heads_up_notification";
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
