-- Fix gender filter: normalize interested_in labels to match profiles.gender values.
-- interested_in_arr stores: "Frauen", "Männer", "Divers", "Alle"
-- profiles.gender stores:   "weiblich", "männlich", "divers"
-- Without this mapping the filter never matched anything.

DROP FUNCTION IF EXISTS public.get_discover_profiles(text,text,text,text,text,text,text,text,text);

CREATE OR REPLACE FUNCTION public.get_discover_profiles(
  p_limit              text DEFAULT '40',
  p_relaxed            text DEFAULT 'false',
  p_cursor_updated_at  text DEFAULT NULL,
  p_cursor_user_id     text DEFAULT NULL,
  p_age_min            text DEFAULT NULL,
  p_age_max            text DEFAULT NULL,
  p_distance_km        text DEFAULT NULL,
  p_looking_for_filter text DEFAULT NULL,
  p_interested_in      text DEFAULT NULL
)
RETURNS TABLE (
  user_id           uuid,
  updated_at        timestamptz,
  display_name      text,
  city              text,
  bio               text,
  interests         text[],
  birthdate         text,
  primary_photo_url text,
  distance_km       int,
  last_active_at    timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_my_id         uuid := auth.uid();
  v_limit         int  := COALESCE(NULLIF(p_limit, '')::int, 40);
  v_relaxed       bool := (p_relaxed = 'true');
  v_lat           double precision;
  v_lng           double precision;
  v_distance_km   int;
  v_age_min       int;
  v_age_max       int;
  v_looking_for   text;
  v_interested_in text[];
BEGIN
  -- Load caller's profile defaults
  SELECT
    pr.location_lat,
    pr.location_lng,
    COALESCE(pr.distance_km, 50),
    COALESCE(pr.age_min, 18),
    COALESCE(pr.age_max, 45),
    pr.looking_for,
    pr.interested_in_arr
  INTO v_lat, v_lng, v_distance_km, v_age_min, v_age_max, v_looking_for, v_interested_in
  FROM profiles pr
  WHERE pr.user_id = v_my_id;

  -- Apply session overrides from SearchSettingsSheet
  IF p_age_min            IS NOT NULL THEN v_age_min     := p_age_min::int; END IF;
  IF p_age_max            IS NOT NULL THEN v_age_max     := p_age_max::int; END IF;
  IF p_distance_km        IS NOT NULL THEN v_distance_km := p_distance_km::int; END IF;
  IF p_looking_for_filter IS NOT NULL THEN
    v_looking_for := NULLIF(p_looking_for_filter, '_all_');
  END IF;
  IF p_interested_in IS NOT NULL THEN
    IF p_interested_in = '_all_' THEN
      v_interested_in := NULL;
    ELSE
      v_interested_in := string_to_array(p_interested_in, ',');
    END IF;
  END IF;

  -- Normalize interested_in display labels → profiles.gender values
  -- "Frauen"/"women" → "weiblich", "Männer"/"men" → "männlich", "Alle"/"all" → no filter
  IF v_interested_in IS NOT NULL THEN
    v_interested_in := ARRAY(
      SELECT CASE i
        WHEN 'Frauen'   THEN 'weiblich'
        WHEN 'Männer'   THEN 'männlich'
        WHEN 'Divers'   THEN 'divers'
        WHEN 'women'    THEN 'weiblich'
        WHEN 'men'      THEN 'männlich'
        WHEN 'diverse'  THEN 'divers'
        ELSE i
      END
      FROM unnest(v_interested_in) AS i
      WHERE i NOT IN ('Alle', 'all')
    );
    -- If only "Alle"/"all" was in the array, treat as no filter
    IF array_length(v_interested_in, 1) IS NULL THEN
      v_interested_in := NULL;
    END IF;
  END IF;

  -- Relaxed mode: widen age ±2 years, distance +50 % (cap 100 km)
  IF v_relaxed AND v_distance_km < 9999 THEN
    v_age_min     := GREATEST(18, v_age_min - 2);
    v_age_max     := v_age_max + 2;
    v_distance_km := LEAST(100, (v_distance_km * 1.5)::int);
  END IF;

  RETURN QUERY
  SELECT
    p.user_id,
    p.updated_at,
    p.display_name,
    p.city,
    p.bio,
    p.interests,
    p.birthdate::text,
    (
      SELECT ph.url FROM photos ph
      WHERE ph.user_id = p.user_id AND ph.is_primary = true
      LIMIT 1
    ) AS primary_photo_url,
    CASE
      WHEN v_lat IS NOT NULL AND v_lng IS NOT NULL
        AND p.location_lat IS NOT NULL AND p.location_lng IS NOT NULL
      THEN (2 * 6371 * asin(sqrt(
          power(sin(radians((p.location_lat - v_lat) / 2)), 2) +
          cos(radians(v_lat)) * cos(radians(p.location_lat)) *
          power(sin(radians((p.location_lng - v_lng) / 2)), 2)
        )))::int
      ELSE NULL
    END AS distance_km,
    p.last_active_at
  FROM profiles p
  WHERE
    p.user_id != v_my_id
    AND p.onboarding_complete = true
    AND (
      p_cursor_updated_at IS NULL
      OR p.updated_at < p_cursor_updated_at::timestamptz
      OR (
        p.updated_at = p_cursor_updated_at::timestamptz
        AND p.user_id::text < COALESCE(p_cursor_user_id, '')
      )
    )
    AND NOT EXISTS (
      SELECT 1 FROM swipes s WHERE s.swiper_id = v_my_id AND s.target_id = p.user_id
    )
    AND NOT EXISTS (
      SELECT 1 FROM blocks b
      WHERE (b.blocker_id = v_my_id AND b.blocked_id = p.user_id)
         OR (b.blocker_id = p.user_id AND b.blocked_id = v_my_id)
    )
    AND (
      v_interested_in IS NULL
      OR array_length(v_interested_in, 1) IS NULL
      OR p.gender = ANY(v_interested_in)
    )
    AND (
      v_relaxed
      OR v_looking_for IS NULL
      OR p.looking_for IS NULL
      OR p.looking_for = v_looking_for
      OR v_looking_for = 'open_to_all'
      OR p.looking_for = 'open_to_all'
    )
    AND (
      p.birthdate IS NULL
      OR (
        date_part('year', age(p.birthdate::date)) >= v_age_min
        AND date_part('year', age(p.birthdate::date)) <= v_age_max
      )
    )
    AND (
      v_lat IS NULL OR v_lng IS NULL
      OR p.location_lat IS NULL OR p.location_lng IS NULL
      OR v_distance_km >= 9999
      OR (2 * 6371 * asin(sqrt(
          power(sin(radians((p.location_lat - v_lat) / 2)), 2) +
          cos(radians(v_lat)) * cos(radians(p.location_lat)) *
          power(sin(radians((p.location_lng - v_lng) / 2)), 2)
        ))) <= v_distance_km
    )
  ORDER BY p.updated_at DESC, p.user_id DESC
  LIMIT v_limit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_discover_profiles(text,text,text,text,text,text,text,text,text) TO authenticated;
