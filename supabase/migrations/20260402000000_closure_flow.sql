-- Closure Flow: Track honest match endings (Anti-Ghosting USP)

ALTER TABLE matches ADD COLUMN IF NOT EXISTS closure_sent_at timestamptz;
ALTER TABLE matches ADD COLUMN IF NOT EXISTS closure_archived_at timestamptz;

COMMENT ON COLUMN matches.closure_sent_at IS 'Timestamp when a user sent a polite closure message via the Closure Flow.';
COMMENT ON COLUMN matches.closure_archived_at IS 'Timestamp when a match was silently archived via the Closure Flow.';
