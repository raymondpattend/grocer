/**
 * Documentation-only mirror of the D1 schema (see migrations/0001_init.sql).
 *
 * These tables exist solely to support APNs delivery for Live Activities,
 * shopping trip alert notifications, and lightweight diagnostics. They are NOT
 * a grocery database — CloudKit is the source of truth for households, lists,
 * items, sessions, and events.
 */

export const TABLES = {
  /** One row per device opted into family shopping pushes. */
  deviceTokens: "device_tokens",
  /** Per-activity update tokens, keyed by (device_id, session_id). */
  activityTokens: "activity_tokens",
  /** Latest Live Activity content per session, for retries/diagnostics. */
  sessionSnapshots: "session_snapshots",
  /** App feedback / bug reports. */
  feedback: "feedback",
  /** Append-only APNs delivery log. */
  apnsLog: "apns_log",
} as const;
