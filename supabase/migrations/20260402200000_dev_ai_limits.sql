-- DEV: raise free-tier AI limit to 999 for testing
-- TODO before launch: drop this migration or set back to 10
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
  select coalesce(subscription_tier, 'free') into v_tier
    from profiles
   where id = p_user_id;

  v_limit := case v_tier
    when 'elite'   then 999
    when 'premium' then 999
    else                 999  -- free: raised for dev/testing, reset to 10 before launch
  end;

  insert into usage_counters(user_id, date, ai_used)
    values (p_user_id, current_date, 0)
    on conflict (user_id, date) do nothing;

  select ai_used into v_used
    from usage_counters
   where user_id = p_user_id and date = current_date
   for update;

  if v_used >= v_limit then
    return false;
  end if;

  update usage_counters
     set ai_used = ai_used + 1
   where user_id = p_user_id and date = current_date;

  return true;
end;
$$;

grant execute on function public.consume_ai_credit(uuid) to service_role;
