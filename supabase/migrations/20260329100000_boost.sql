-- Migration: Profile Boost feature
-- Adds boost_active_until to profiles so the discover function can sort boosted profiles first.

ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS boost_active_until timestamptz DEFAULT NULL;

-- Index for efficient discover sorting
CREATE INDEX IF NOT EXISTS idx_profiles_boost_active_until
  ON public.profiles (boost_active_until)
  WHERE boost_active_until IS NOT NULL;

-- Update discover_profiles_v2 to prioritize boosted profiles.
-- Boosted profiles (boost_active_until > now()) sort above non-boosted ones.
CREATE OR REPLACE FUNCTION public.discover_profiles_v2(
  p_user_id      uuid,
  p_lat          double precision,
  p_lng          double precision,
  p_distance_km  int     DEFAULT 50,
  p_age_min      int     DEFAULT 18,
  p_age_max      int     DEFAULT 45,
  p_gender       text[]  DEFAULT NULL,
  p_looking_for  text    DEFAULT NULL,
  p_cursor       timestamptz DEFAULT NULL,
  p_limit        int     DEFAULT 40
)
RETURNS TABLE (
  user_id           uuid,
  display_name      text,
  bio               text,
  birthdate         text,
  city              text,
  interests         text[],
  first_date_vibes  text[],
  hooks             text[],
  primary_photo_url text,
  distance_km       double precision,
  boost_active      boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    p.user_id,
    p.display_name,
    p.bio,
    p.birthdate,
    p.city,
    p.interests,
    p.first_date_vibes,
    p.hooks,
    (SELECT ph.url FROM photos ph WHERE ph.user_id = p.user_id AND ph.is_primary = true LIMIT 1) AS primary_photo_url,
    -- Haversine distance in km
    (2 * 6371 * asin(sqrt(
      power(sin(radians((p.location_lat - p_lat) / 2)), 2) +
      cos(radians(p_lat)) * cos(radians(p.location_lat)) *
      power(sin(radians((p.location_lng - p_lng) / 2)), 2)
    ))) AS distance_km,
    (p.boost_active_until IS NOT NULL AND p.boost_active_until > now()) AS boost_active
  FROM profiles p
  WHERE
    p.user_id != p_user_id
    AND p.onboarding_complete = true
    AND NOT EXISTS (
      SELECT 1 FROM swipes s
      WHERE s.swiper_id = p_user_id AND s.target_id = p.user_id
    )
    AND NOT EXISTS (
      SELECT 1 FROM blocks b
      WHERE (b.blocker_id = p_user_id AND b.blocked_id = p.user_id)
         OR (b.blocker_id = p.user_id AND b.blocked_id = p_user_id)
    )
    AND (p_cursor IS NULL OR p.created_at < p_cursor)
    AND (p_gender IS NULL OR p.gender = ANY(p_gender))
    AND (p_looking_for IS NULL OR p.looking_for = p_looking_for)
    AND (p.location_lat IS NOT NULL AND p.location_lng IS NOT NULL)
    AND (2 * 6371 * asin(sqrt(
      power(sin(radians((p.location_lat - p_lat) / 2)), 2) +
      cos(radians(p_lat)) * cos(radians(p.location_lat)) *
      power(sin(radians((p.location_lng - p_lng) / 2)), 2)
    ))) <= p_distance_km
    AND (
      p.birthdate IS NULL
      OR (
        date_part('year', age(p.birthdate::date)) >= p_age_min
        AND date_part('year', age(p.birthdate::date)) <= p_age_max
      )
    )
  ORDER BY
    (p.boost_active_until IS NOT NULL AND p.boost_active_until > now()) DESC,
    p.created_at DESC
  LIMIT p_limit;
$$;

GRANT EXECUTE ON FUNCTION public.discover_profiles_v2 TO authenticated;
