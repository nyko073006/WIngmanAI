-- Add last_active_at to profiles for activity indicator
alter table public.profiles
  add column if not exists last_active_at timestamptz;

create index if not exists profiles_last_active_at_idx
  on public.profiles(last_active_at desc);
