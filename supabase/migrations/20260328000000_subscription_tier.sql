-- Migration: add subscription_tier to profiles so Edge Functions can enforce rate limits

ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS subscription_tier text NOT NULL DEFAULT 'free'
CHECK (subscription_tier IN ('free', 'premium', 'elite'));

-- Edge Functions read this value with the service role key to determine AI credit limits.
-- It is updated by the iOS PremiumService (via Supabase updateUser metadata) after a
-- successful StoreKit purchase verification.
