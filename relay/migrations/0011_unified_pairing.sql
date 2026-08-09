PRAGMA foreign_keys = ON;

-- Unified pairing: either principal issues a code; the counterpart claims
-- it; the computer (which owns the E2EE secret) seals an envelope onto the
-- claim; and the client's explicit accept is the ONLY operation that creates
-- a client_computers edge. A client's own claim is accepted by itself right
-- after decryption (typing the computer's code was its consent); a
-- host-initiated claim waits for the user's confirmation card. Rows hold
-- code hashes, public keys, and ciphertext only — never a plaintext code or
-- secret.
--
-- Replaces the forward-only pairing_sessions ceremony. In-flight sessions
-- are 15-minute ephemera; dropping them at deploy time is harmless.

DROP TABLE pairing_sessions;

CREATE TABLE pairing_codes (
  id TEXT PRIMARY KEY CHECK (length(id) = 32),
  code_hash TEXT NOT NULL UNIQUE CHECK (length(code_hash) = 64),
  issuer TEXT NOT NULL CHECK (issuer IN ('host', 'client')),
  computer_id TEXT REFERENCES computers(id) ON DELETE CASCADE,
  client_id TEXT REFERENCES clients(id) ON DELETE CASCADE,
  public_key TEXT NOT NULL CHECK (length(public_key) = 43),
  single_use INTEGER NOT NULL CHECK (single_use IN (0, 1)),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  CHECK (
    (issuer = 'host' AND computer_id IS NOT NULL AND client_id IS NULL) OR
    (issuer = 'client' AND client_id IS NOT NULL AND computer_id IS NULL)
  )
) STRICT;

CREATE INDEX pairing_codes_by_computer ON pairing_codes (computer_id)
  WHERE computer_id IS NOT NULL;
CREATE INDEX pairing_codes_by_client ON pairing_codes (client_id)
  WHERE client_id IS NOT NULL;
CREATE INDEX pairing_codes_expiry ON pairing_codes (expires_at);

CREATE TABLE pairing_claims (
  id TEXT PRIMARY KEY CHECK (length(id) = 32),
  -- Correlates a claim to the code it consumed for the issuing host's poll;
  -- severed (not cascaded) when the code is replaced or expires, because a
  -- sealed claim outlives its code and stays acceptable.
  code_id TEXT REFERENCES pairing_codes(id) ON DELETE SET NULL,
  client_id TEXT NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  computer_id TEXT NOT NULL REFERENCES computers(id) ON DELETE CASCADE,
  claimed_by TEXT NOT NULL CHECK (claimed_by IN ('host', 'client')),
  computer_name TEXT NOT NULL DEFAULT '' CHECK (length(computer_name) <= 64),
  host_public_key TEXT NOT NULL CHECK (length(host_public_key) = 43),
  client_public_key TEXT NOT NULL CHECK (length(client_public_key) = 43),
  encrypted_secret TEXT CHECK (
    encrypted_secret IS NULL OR length(encrypted_secret) BETWEEN 64 AND 256
  ),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  UNIQUE (client_id, computer_id)
) STRICT;

CREATE INDEX pairing_claims_by_client ON pairing_claims (client_id, created_at);
CREATE INDEX pairing_claims_expiry ON pairing_claims (expires_at);

-- Add the ios-app alert surface so a host-initiated claim can raise a
-- visible "computer wants to connect" notification. SQLite cannot widen a
-- CHECK, so rebuild push_endpoints exactly as 0007/0008/0010 did.

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
