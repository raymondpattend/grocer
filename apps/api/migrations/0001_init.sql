-- Grocer API — Live Activity support tables.
-- This database holds ONLY what is needed to deliver ActivityKit pushes.
-- CloudKit remains the authoritative store for all grocery data.

-- One row per device that has opted into family shopping Live Activities.
-- The push-to-start token lets the backend START a Live Activity remotely.
CREATE TABLE IF NOT EXISTS device_tokens (
  device_id            TEXT NOT NULL,
  household_id         TEXT NOT NULL,
  member_id            TEXT NOT NULL,
  push_to_start_token  TEXT,
  push_notification_token TEXT,
  live_activities_enabled INTEGER NOT NULL DEFAULT 1,  -- boolean (0/1)
  notifications_enabled INTEGER NOT NULL DEFAULT 0,      -- boolean (0/1)
  app_version          TEXT,
  platform             TEXT NOT NULL DEFAULT 'iOS',
  token_valid          INTEGER NOT NULL DEFAULT 1,      -- boolean (0/1)
  notification_token_valid INTEGER NOT NULL DEFAULT 0, -- boolean (0/1)
  created_at           TEXT NOT NULL,
  updated_at           TEXT NOT NULL,
  PRIMARY KEY (device_id)
);

CREATE INDEX IF NOT EXISTS idx_device_tokens_household
  ON device_tokens (household_id);

-- One row per running Live Activity on a device. ActivityKit hands the app
-- a per-activity update token after the activity starts; the device posts it
-- back here so the backend can target update/end pushes at that activity.
CREATE TABLE IF NOT EXISTS activity_tokens (
  device_id     TEXT NOT NULL,
  session_id    TEXT NOT NULL,
  household_id  TEXT NOT NULL,
  member_id     TEXT NOT NULL,
  update_token  TEXT NOT NULL,
  token_valid   INTEGER NOT NULL DEFAULT 1,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  PRIMARY KEY (device_id, session_id)
);

CREATE INDEX IF NOT EXISTS idx_activity_tokens_session
  ON activity_tokens (session_id);

-- Lightweight snapshot of the latest Live Activity content per session.
-- Used for APNs retries and diagnostics only — not a grocery database.
CREATE TABLE IF NOT EXISTS session_snapshots (
  session_id    TEXT NOT NULL,
  household_id  TEXT NOT NULL,
  content_json  TEXT NOT NULL,   -- serialized LiveActivityContent
  status        TEXT NOT NULL,   -- Active | Completed | Cancelled
  started_at    TEXT,
  updated_at    TEXT NOT NULL,
  PRIMARY KEY (session_id)
);

-- Feedback / bug reports captured from the app.
CREATE TABLE IF NOT EXISTS feedback (
  id           TEXT NOT NULL,
  message      TEXT NOT NULL,
  email        TEXT,
  app_version  TEXT,
  device       TEXT,
  created_at   TEXT NOT NULL,
  PRIMARY KEY (id)
);

-- Append-only log of APNs delivery attempts for diagnostics.
CREATE TABLE IF NOT EXISTS apns_log (
  id           TEXT NOT NULL,
  session_id   TEXT,
  device_id    TEXT,
  event        TEXT NOT NULL,   -- start | update | end
  outcome      TEXT NOT NULL,   -- sent | failed | expired
  status_code  INTEGER,
  apns_id      TEXT,
  detail       TEXT,
  created_at   TEXT NOT NULL,
  PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_apns_log_session
  ON apns_log (session_id);
