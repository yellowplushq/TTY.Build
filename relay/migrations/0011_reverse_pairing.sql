PRAGMA foreign_keys = ON;

-- Reverse pairing: the phone issues a long-lived 8-digit enrollment token
-- whose durable public key computers seal to. A computer's claim waits here
-- until the user confirms it on the phone; only confirmation creates a
-- client_computers edge. Rows hold code hashes, public keys, and ciphertext
-- only — never a plaintext code or secret.

CREATE TABLE reverse_pairing_tokens (
  client_id TEXT PRIMARY KEY REFERENCES clients(id) ON DELETE CASCADE,
  code_hash TEXT NOT NULL UNIQUE CHECK (length(code_hash) = 64),
  client_public_key TEXT NOT NULL CHECK (length(client_public_key) = 43),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX reverse_pairing_tokens_expiry
  ON reverse_pairing_tokens (expires_at);

CREATE TABLE reverse_pairing_claims (
  id TEXT PRIMARY KEY CHECK (length(id) = 32),
  client_id TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  computer_id TEXT NOT NULL REFERENCES computers(id) ON DELETE CASCADE,
  computer_name TEXT NOT NULL CHECK (length(computer_name) BETWEEN 1 AND 64),
  host_public_key TEXT NOT NULL CHECK (length(host_public_key) = 43),
  encrypted_secret TEXT CHECK (
    encrypted_secret IS NULL OR length(encrypted_secret) BETWEEN 64 AND 256
  ),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  UNIQUE (client_id, computer_id)
) STRICT;

CREATE INDEX reverse_pairing_claims_by_client
  ON reverse_pairing_claims (client_id, created_at);

CREATE INDEX reverse_pairing_claims_expiry
  ON reverse_pairing_claims (expires_at);

-- Add the ios-app alert surface so a completed claim can raise a visible
-- "computer wants to connect" notification. SQLite cannot widen a CHECK, so
-- rebuild push_endpoints exactly as 0007/0008/0010 did.

CREATE TABLE push_endpoints_v5 (
  id TEXT PRIMARY KEY CHECK (length(id) = 32),
  client_id TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  surface TEXT NOT NULL CHECK (
    surface IN (
      'ios-app', 'ios-widget', 'watch-widget',
      'liveactivity-start', 'liveactivity-update'
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

INSERT INTO push_endpoints_v5
  (id, client_id, surface, apns_environment, token, token_hash, activity_key,
   created_at, updated_at, invalidated_at, last_sequence, last_total_running,
   retry_not_before, failure_count, last_failure_reason)
SELECT id, client_id, surface, apns_environment, token, token_hash, activity_key,
       created_at, updated_at, invalidated_at, last_sequence, last_total_running,
       retry_not_before, failure_count, last_failure_reason
  FROM push_endpoints;

DROP TABLE push_endpoints;
ALTER TABLE push_endpoints_v5 RENAME TO push_endpoints;

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
