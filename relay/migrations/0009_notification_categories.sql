-- Per-endpoint notification category preferences ("notify me when…"):
-- comma-joined subset of waiting,error,done. NULL means all categories.
ALTER TABLE push_endpoints ADD COLUMN notification_categories TEXT
  CHECK (
    notification_categories IS NULL
    OR length(notification_categories) BETWEEN 1 AND 32
  );
