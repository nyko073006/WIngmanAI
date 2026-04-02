-- Replaces the consume_ai_credit RPC to read tier limits from the profiles table
-- instead of receiving p_limit from the client (Edge Function).
-- Tier limits are hardcoded in the DB function for security.

create or replace function public.consume_ai_credit(
  p_user_id   uuid
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
  -- Look up the user's tier
  select coalesce(subscription_tier, 'free') into v_tier
    from profiles
   where id = p_user_id;

  -- Map tier to daily limit
  v_limit := case v_tier
    when 'elite'   then 50
    when 'premium' then 25
    else                 10  -- free
  end;

  -- Upsert today's row
  insert into usage_counters(user_id, date, ai_used)
    values (p_user_id, current_date, 0)
    on conflict (user_id, date) do nothing;

  -- Lock and read current count
  select ai_used into v_used
    from usage_counters
   where user_id = p_user_id and date = current_date
   for update;

  if v_used >= v_limit then
    return false;
  end if;

  -- Increment
  update usage_counters
     set ai_used = ai_used + 1
   where user_id = p_user_id and date = current_date;

  return true;
end;
$$;

-- Revoke old 2-arg signature if it exists (idempotent)
do $$
begin
  revoke execute on function public.consume_ai_credit(uuid, int) from service_role;
  revoke execute on function public.consume_ai_credit(uuid, int) from authenticated;
exception when others then null;
end
$$;

grant execute on function public.consume_ai_credit(uuid) to service_role;
