-- User device tokens for push notifications
create table if not exists public.user_devices (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  platform    text not null default 'ios',
  token       text not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (platform, token)
);

-- Index for fast lookups by user
create index if not exists user_devices_user_id_idx on public.user_devices(user_id);

-- RLS: users can only read/write their own tokens
alter table public.user_devices enable row level security;

create policy "Users manage own devices"
  on public.user_devices
  for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
