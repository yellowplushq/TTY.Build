PRAGMA foreign_keys = ON;

-- Agent monitoring phase 2 (docs/AGENT_MONITORING_DESIGN.md §5/§6):
-- 1. Per-state coding-agent aggregate counts projected next to the alive-TTY
--    count. Counts only — agent names, projects, and messages remain E2EE.
ALTER TABLE computer_state ADD COLUMN agents_running INTEGER NOT NULL DEFAULT 0
  CHECK (agents_running BETWEEN 0 AND 255);
ALTER TABLE computer_state ADD COLUMN agents_waiting INTEGER NOT NULL DEFAULT 0
  CHECK (agents_waiting BETWEEN 0 AND 255);
ALTER TABLE computer_state ADD COLUMN agents_done INTEGER NOT NULL DEFAULT 0
  CHECK (agents_done BETWEEN 0 AND 255);

-- 2. A visible-alert push surface ('ios-alert'): rebuild push_endpoints to
--    widen the surface CHECK, carrying every column 0001+0002 defined.
CREATE TABLE push_endpoints_v2 (
  id TEXT PRIMARY KEY CHECK (length(id) = 32),
  client_id TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  surface TEXT NOT NULL CHECK (
    surface IN (
      'ios-widget', 'watch-widget', 'liveactivity-start', 'liveactivity-update',
      'ios-alert'
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

INSERT INTO push_endpoints_v2
  (id, client_id, surface, apns_environment, token, token_hash, activity_key,
   created_at, updated_at, invalidated_at, last_sequence, last_total_running,
   retry_not_before, failure_count, last_failure_reason)
SELECT id, client_id, surface, apns_environment, token, token_hash, activity_key,
       created_at, updated_at, invalidated_at, last_sequence, last_total_running,
       retry_not_before, failure_count, last_failure_reason
  FROM push_endpoints;

DROP TABLE push_endpoints;
ALTER TABLE push_endpoints_v2 RENAME TO push_endpoints;

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
