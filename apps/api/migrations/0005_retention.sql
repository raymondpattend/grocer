-- Retention push notifications.
--
-- Re-engage users who have stopped opening the app when OTHER members of their
-- shared list(s) have added items in the meantime. The scheduled (cron) handler
-- needs two things the backend didn't previously track:
--   1. when each device last had the app in the foreground (last_opened_at), and
--   2. a lightweight log of item-add activity per household (list_activity).
-- CloudKit remains the source of truth for the grocery data itself; list_activity
-- only stores counts + the adder's display name for notification copy.

ALTER TABLE device_tokens ADD COLUMN last_opened_at TEXT;
ALTER TABLE device_tokens ADD COLUMN last_retention_push_at TEXT;
ALTER TABLE device_tokens ADD COLUMN tz_offset_minutes INTEGER;

-- Append-only log of items added to a (shared) household, modeled on apns_log.
CREATE TABLE IF NOT EXISTS list_activity (
  id                 TEXT PRIMARY KEY,
  household_id       TEXT NOT NULL,
  actor_member_id    TEXT NOT NULL,
  actor_display_name TEXT,
  item_count         INTEGER NOT NULL,
  created_at         TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_list_activity_household_created
  ON list_activity (household_id, created_at);
