-- Add intro_message to swipes so a "like with message" can be stored
-- and shown to the recipient in their Likes view.
ALTER TABLE swipes ADD COLUMN IF NOT EXISTS intro_message text;
