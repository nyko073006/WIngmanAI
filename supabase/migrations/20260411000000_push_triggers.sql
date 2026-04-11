-- Push notification triggers via pg_net
-- Calls send-push on new messages, send-push-match on new matches

create extension if not exists pg_net;

-- ── Trigger: new message → send-push ─────────────────────────────────────────

create or replace function public.trigger_send_push_message()
returns trigger language plpgsql security definer as $$
begin
  perform net.http_post(
    url     := 'https://axkxzozfwecdyulnvwmx.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer wingman-push-2026'
    ),
    body    := jsonb_build_object(
      'type',       'INSERT',
      'table',      'messages',
      'schema',     'public',
      'record',     row_to_json(NEW),
      'old_record', null
    )
  );
  return NEW;
end;
$$;

drop trigger if exists on_message_send_push on public.messages;
create trigger on_message_send_push
  after insert on public.messages
  for each row execute function public.trigger_send_push_message();

-- ── Trigger: new match → send-push-match ──────────────────────────────────────

create or replace function public.trigger_send_push_match()
returns trigger language plpgsql security definer as $$
begin
  perform net.http_post(
    url     := 'https://axkxzozfwecdyulnvwmx.supabase.co/functions/v1/send-push-match',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer wingman-push-2026'
    ),
    body    := jsonb_build_object(
      'type',       'INSERT',
      'table',      'matches',
      'schema',     'public',
      'record',     row_to_json(NEW),
      'old_record', null
    )
  );
  return NEW;
end;
$$;

drop trigger if exists on_match_send_push on public.matches;
create trigger on_match_send_push
  after insert on public.matches
  for each row execute function public.trigger_send_push_match();
