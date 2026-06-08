-- Let one physical device register Live Activity / APNs tokens for multiple groups.
--
-- The original table used PRIMARY KEY(device_id), so opening or joining another
-- group overwrote the previous group's registration. Push-to-start fanout is
-- group-scoped, so the key must include household_id.

CREATE TABLE device_tokens_v2 (
  device_id            TEXT NOT NULL,
  household_id         TEXT NOT NULL,
  member_id            TEXT NOT NULL,
  push_to_start_token  TEXT,
  push_notification_token TEXT,
  live_activities_enabled INTEGER NOT NULL DEFAULT 1,
  notifications_enabled INTEGER NOT NULL DEFAULT 0,
  app_version          TEXT,
  platform             TEXT NOT NULL DEFAULT 'iOS',
  token_valid          INTEGER NOT NULL DEFAULT 1,
  notification_token_valid INTEGER NOT NULL DEFAULT 0,
  created_at           TEXT NOT NULL,
  updated_at           TEXT NOT NULL,
  PRIMARY KEY (device_id, household_id)
);

INSERT INTO device_tokens_v2 (
  device_id,
  household_id,
  member_id,
  push_to_start_token,
  push_notification_token,
  live_activities_enabled,
  notifications_enabled,
  app_version,
  platform,
  token_valid,
  notification_token_valid,
  created_at,
  updated_at
)
SELECT
  device_id,
  household_id,
  member_id,
  push_to_start_token,
  push_notification_token,
  live_activities_enabled,
  notifications_enabled,
  app_version,
  platform,
  token_valid,
  notification_token_valid,
  created_at,
  updated_at
FROM device_tokens;

DROP TABLE device_tokens;
ALTER TABLE device_tokens_v2 RENAME TO device_tokens;

CREATE INDEX IF NOT EXISTS idx_device_tokens_household
  ON device_tokens (household_id);
