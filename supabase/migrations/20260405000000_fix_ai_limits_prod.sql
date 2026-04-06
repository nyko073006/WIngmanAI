-- Production AI rate limits
-- Fixes column bug (id → user_id in profiles lookup) from v2 migration.
-- Supersedes dev migration 20260402 (which set everyone to 999).
-- Limits are strictly per-user per-day — there is no global counter.

create or replace function public.consume_ai_credit(
  p_user_id uuid
) returns boolean
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_used  int;
  v_tier  text;
  v_limit int;
begin
  -- Look up the user's subscription tier (fix: user_id column, not id)
  select coalesce(subscription_tier, 'free') into v_tier
    from profiles
   where user_id = p_user_id;

  -- Per-user daily limits by tier
  v_limit := case v_tier
    when 'elite'   then 50
    when 'premium' then 25
    else                 10  -- free tier
  end;

  -- Upsert today's row for this user
  insert into usage_counters(user_id, date, ai_used)
    values (p_user_id, current_date, 0)
    on conflict (user_id, date) do nothing;

  -- Lock row and read current count (per-user, per-day)
  select ai_used into v_used
    from usage_counters
   where user_id = p_user_id and date = current_date
   for update;

  if v_used >= v_limit then
    return false;
  end if;

  -- Increment this user's counter
  update usage_counters
     set ai_used = ai_used + 1
   where user_id = p_user_id and date = current_date;

  return true;
end;
$$;

grant execute on function public.consume_ai_credit(uuid) to service_role;
grant execute on function public.consume_ai_credit(uuid) to authenticated;
