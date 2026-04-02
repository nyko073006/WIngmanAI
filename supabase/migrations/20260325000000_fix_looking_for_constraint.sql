-- Drop the old check constraint that only allows single values
ALTER TABLE public.profiles
DROP CONSTRAINT IF EXISTS profiles_looking_for_chk;

-- Recreate constraint to accept the app's single-select values (or null)
ALTER TABLE public.profiles
ADD CONSTRAINT profiles_looking_for_chk
CHECK (
  looking_for IS NULL
  OR looking_for = ANY(ARRAY['serious', 'casual', 'friends', 'open_to_all', 'not_sure'])
);
