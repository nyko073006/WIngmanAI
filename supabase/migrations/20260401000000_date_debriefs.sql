-- Date Debrief feature
-- Stores post-date reflections per user + match, with AI feedback.

CREATE TABLE public.date_debriefs (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  match_id    UUID        NOT NULL REFERENCES public.matches(id) ON DELETE CASCADE,
  rating      INT         NOT NULL CHECK (rating BETWEEN 1 AND 5),
  notes       TEXT        NOT NULL DEFAULT '',
  ai_feedback TEXT,
  ai_patterns TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.date_debriefs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users manage own debriefs"
  ON public.date_debriefs FOR ALL
  USING  (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE INDEX date_debriefs_user_created_idx
  ON public.date_debriefs (user_id, created_at DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- pg_cron setup (run manually after enabling pg_cron in Supabase Dashboard):
--
-- SELECT cron.schedule(
--   'date-debrief-reminder',
--   '0 10 * * *',
--   $$
--     SELECT net.http_post(
--       url    := 'https://axkxzozfwecdyulnvwmx.supabase.co/functions/v1/send-push-debrief',
--       headers := jsonb_build_object(
--         'Content-Type',  'application/json',
--         'Authorization', 'Bearer <SERVICE_ROLE_KEY>'
--       ),
--       body   := '{}'::jsonb
--     );
--   $$
-- );
-- ─────────────────────────────────────────────────────────────────────────────
