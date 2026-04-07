-- During beta, give elite users 500 AI credits/day (effectively unlimited)
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
  select coalesce(subscription_tier, 'free') into v_tier
    from profiles
   where user_id = p_user_id;

  v_limit := case v_tier
    when 'elite'   then 500   -- beta: effectively unlimited
    when 'premium' then 50
    else                 15   -- free tier
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
grant execute on function public.consume_ai_credit(uuid) to authenticated;
