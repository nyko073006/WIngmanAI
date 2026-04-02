-- Server-side usage counters for rate limiting
-- Prevents client-side bypass via UserDefaults manipulation

create table if not exists public.usage_counters (
  user_id   uuid        not null references auth.users(id) on delete cascade,
  date      date        not null default current_date,
  ai_used   int         not null default 0,
  primary key (user_id, date)
);

-- Only the user can read their own counters; no direct writes from client
alter table public.usage_counters enable row level security;

create policy "users read own counters"
  on public.usage_counters for select
  using (auth.uid() = user_id);

-- RPC: atomically check limit and increment.
-- Returns true if the call is allowed, false if limit exceeded.
-- tier_limit is passed by the Edge Function (derived from the user's subscription).
create or replace function public.consume_ai_credit(
  p_user_id   uuid,
  p_limit     int
) returns boolean
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_used int;
begin
  -- Upsert today's row
  insert into usage_counters(user_id, date, ai_used)
    values (p_user_id, current_date, 0)
    on conflict (user_id, date) do nothing;

  -- Lock the row and read current count
  select ai_used into v_used
    from usage_counters
   where user_id = p_user_id and date = current_date
   for update;

  if v_used >= p_limit then
    return false;
  end if;

  -- Increment
  update usage_counters
     set ai_used = ai_used + 1
   where user_id = p_user_id and date = current_date;

  return true;
end;
$$;

-- Allow Edge Functions (service role) to call this function
grant execute on function public.consume_ai_credit(uuid, int) to service_role;
grant execute on function public.consume_ai_credit(uuid, int) to authenticated;
