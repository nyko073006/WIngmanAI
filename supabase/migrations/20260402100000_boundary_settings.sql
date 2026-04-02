-- Boundary Settings: visible preferences to reduce mismatches
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS boundaries jsonb DEFAULT '{}'::jsonb;
COMMENT ON COLUMN profiles.boundaries IS 'User boundary preferences: relationship_goal, comm_style, dealbreakers array.';
