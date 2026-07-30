PRAGMA foreign_keys = ON;

-- Live Activity is the sole attention surface. Remove every ordinary iOS
-- notification endpoint and its category-preference column, and restore the
-- short-lived completion count used by ActivityKit lifecycle decisions.
ALTER TABLE computer_state ADD COLUMN agents_done INTEGER NOT NULL DEFAULT 0
  CHECK (agents_done BETWEEN 0 AND 255);

CREATE TABLE push_endpoints_v4 (
  id TEXT PRIMARY KEY CHECK (length(id) = 32),
  client_id TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  surface TEXT NOT NULL CHECK (
    surface IN (
      'ios-widget', 'watch-widget', 'liveactivity-start', 'liveactivity-update'
    )
  ),
  apns_environment TEXT NOT NULL CHECK (apns_environment IN ('sandbox', 'production')),
  token TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE CHECK (length(token_hash) = 64),
  activity_key TEXT NOT NULL DEFAULT '' CHECK (
    surface = 'liveactivity-update' OR activity_key = ''
  ),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  invalidated_at INTEGER,
  last_sequence INTEGER NOT NULL DEFAULT -1 CHECK (last_sequence >= -1),
  last_total_running INTEGER,
  retry_not_before INTEGER,
  failure_count INTEGER NOT NULL DEFAULT 0 CHECK (failure_count >= 0),
  last_failure_reason TEXT
    CHECK (last_failure_reason IS NULL OR length(last_failure_reason) <= 128),
  UNIQUE (client_id, surface, activity_key)
) STRICT;

INSERT INTO push_endpoints_v4
  (id, client_id, surface, apns_environment, token, token_hash, activity_key,
   created_at, updated_at, invalidated_at, last_sequence, last_total_running,
   retry_not_before, failure_count, last_failure_reason)
SELECT id, client_id, surface, apns_environment, token, token_hash, activity_key,
       created_at, updated_at, invalidated_at, last_sequence, last_total_running,
       retry_not_before, failure_count, last_failure_reason
  FROM push_endpoints
 WHERE surface != 'ios-notification';

DROP TABLE push_endpoints;
ALTER TABLE push_endpoints_v4 RENAME TO push_endpoints;

CREATE INDEX push_endpoints_by_client
  ON push_endpoints (client_id, invalidated_at);

CREATE INDEX push_endpoints_reconcile
  ON push_endpoints (retry_not_before, client_id)
  WHERE retry_not_before IS NOT NULL;

CREATE TRIGGER push_endpoints_limit
BEFORE INSERT ON push_endpoints
WHEN NOT EXISTS (
       SELECT 1 FROM push_endpoints
        WHERE client_id = NEW.client_id
          AND surface = NEW.surface
          AND activity_key = NEW.activity_key
     )
 AND (
       SELECT COUNT(*) FROM push_endpoints
        WHERE client_id = NEW.client_id
          AND invalidated_at IS NULL
     ) >= 8
BEGIN
  SELECT RAISE(ABORT, 'push endpoint limit exceeded');
END;
