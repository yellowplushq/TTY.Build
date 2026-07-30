PRAGMA foreign_keys = ON;

-- Agent notifications: daemon-emitted pushes on blocked/error/finished.
-- The push surface renames 'ios-alert' -> 'ios-notification' (CHECK change
-- needs a rebuild); existing registrations carry over.
--
-- computer_state is rebuilt to drop agents_done: a done count only ever
-- grows, so the server-visible aggregate carries running/waiting only.
CREATE TABLE computer_state_v4 (
  computer_id TEXT PRIMARY KEY REFERENCES computers(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
  mutation_id TEXT CHECK (mutation_id IS NULL OR length(mutation_id) = 32),
  host_name TEXT CHECK (host_name IS NULL OR (length(host_name) BETWEEN 1 AND 128)),
  running_terminal_count INTEGER NOT NULL DEFAULT 0
    CHECK (running_terminal_count BETWEEN 0 AND 255),
  agents_running INTEGER NOT NULL DEFAULT 0 CHECK (agents_running BETWEEN 0 AND 255),
  agents_waiting INTEGER NOT NULL DEFAULT 0 CHECK (agents_waiting BETWEEN 0 AND 255),
  online INTEGER NOT NULL DEFAULT 0 CHECK (online IN (0, 1)),
  updated_at INTEGER NOT NULL DEFAULT 0
) STRICT;

INSERT INTO computer_state_v4
  (computer_id, revision, mutation_id, host_name, running_terminal_count,
   agents_running, agents_waiting, online, updated_at)
SELECT computer_id, revision, mutation_id, host_name, running_terminal_count,
       agents_running, agents_waiting, online, updated_at
  FROM computer_state;

DROP TABLE computer_state;
ALTER TABLE computer_state_v4 RENAME TO computer_state;

CREATE TABLE push_endpoints_v3 (
  id TEXT PRIMARY KEY CHECK (length(id) = 32),
  client_id TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  surface TEXT NOT NULL CHECK (
    surface IN (
      'ios-widget', 'watch-widget', 'liveactivity-start', 'liveactivity-update',
      'ios-notification'
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

INSERT INTO push_endpoints_v3
  (id, client_id, surface, apns_environment, token, token_hash, activity_key,
   created_at, updated_at, invalidated_at, last_sequence, last_total_running,
   retry_not_before, failure_count, last_failure_reason)
SELECT id, client_id,
       CASE surface WHEN 'ios-alert' THEN 'ios-notification' ELSE surface END,
       apns_environment, token, token_hash, activity_key,
       created_at, updated_at, invalidated_at, last_sequence, last_total_running,
       retry_not_before, failure_count, last_failure_reason
  FROM push_endpoints;

DROP TABLE push_endpoints;
ALTER TABLE push_endpoints_v3 RENAME TO push_endpoints;

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
