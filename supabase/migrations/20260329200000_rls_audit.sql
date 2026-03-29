-- RLS Audit Migration
-- Adds missing row-level security policies identified during audit.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. PHOTOS
-- Photos should be readable:
--   a) by the owner (always)
--   b) by any authenticated user viewing the discover feed / profile cards
--      (public read is intentional for a dating app — users need to see photos)
-- Photos should only be written by the owner.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.photos ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "Anyone can view photos"
    ON public.photos FOR SELECT
    USING (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "Owner manages own photos"
    ON public.photos FOR ALL
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. MATCHES
-- Both users in a match can read it; no client-side writes (match creation
-- goes through the create_match RPC which runs as security definer).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.matches ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "Match participants can read"
    ON public.matches FOR SELECT
    USING (auth.uid() = user_low OR auth.uid() = user_high);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. MESSAGES
-- Only participants of the match can read/insert messages.
-- No updates or deletes from the client.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "Match participants read messages"
    ON public.messages FOR SELECT
    USING (
      EXISTS (
        SELECT 1 FROM matches m
        WHERE m.id = messages.match_id
          AND (m.user_low = auth.uid() OR m.user_high = auth.uid())
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "Match participants insert messages"
    ON public.messages FOR INSERT
    WITH CHECK (
      auth.uid() = sender_id
      AND EXISTS (
        SELECT 1 FROM matches m
        WHERE m.id = match_id
          AND (m.user_low = auth.uid() OR m.user_high = auth.uid())
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. MATCH_READS (read receipts)
-- Only the two participants may read/write.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.match_reads ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "Match participants manage reads"
    ON public.match_reads FOR ALL
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. SWIPES
-- Users can read & insert their own swipes only.
-- Prevents seeing who liked you for free (that's a Premium feature via LikesView).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.swipes ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "Users manage own swipes"
    ON public.swipes FOR ALL
    USING (auth.uid() = swiper_id)
    WITH CHECK (auth.uid() = swiper_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. BLOCKS & REPORTS
-- Users can read/write their own blocks and reports.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.blocks ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "Users manage own blocks"
    ON public.blocks FOR ALL
    USING (auth.uid() = blocker_id)
    WITH CHECK (auth.uid() = blocker_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "Users insert own reports"
    ON public.reports FOR INSERT
    WITH CHECK (auth.uid() = reporter_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY "Users read own reports"
    ON public.reports FOR SELECT
    USING (auth.uid() = reporter_id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. ANALYTICS_EVENTS table (for AnalyticsService)
-- Create the table if it doesn't exist yet.
-- Users can only insert their own events; reads are admin-only.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.analytics_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_name  text NOT NULL,
  user_id     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  properties  jsonb DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_analytics_events_user ON public.analytics_events (user_id);
CREATE INDEX IF NOT EXISTS idx_analytics_events_name ON public.analytics_events (event_name);
CREATE INDEX IF NOT EXISTS idx_analytics_events_time ON public.analytics_events (created_at);

ALTER TABLE public.analytics_events ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  CREATE POLICY "Users insert own analytics"
    ON public.analytics_events FOR INSERT
    WITH CHECK (auth.uid()::text = user_id::text OR user_id IS NULL);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Service role (used from Edge Functions / admin) has full access via RLS bypass.
