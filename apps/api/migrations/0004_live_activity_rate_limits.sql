-- Durable rolling-window rate limits for Live Activity fanout/debug endpoints.

CREATE TABLE IF NOT EXISTS live_activity_rate_limits (
  key          TEXT NOT NULL,
  window_start INTEGER NOT NULL,
  count        INTEGER NOT NULL,
  updated_at   TEXT NOT NULL,
  PRIMARY KEY (key)
);

