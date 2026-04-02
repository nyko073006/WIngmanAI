-- =============================================
-- WingmanAI Memory Architecture
-- =============================================

-- Enable pgvector if not already enabled
create extension if not exists vector;

-- =============================================
-- 1. ai_user_memory_facts
-- Hard structured facts per user
-- =============================================
create table if not exists ai_user_memory_facts (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  category      text not null, -- identity | preference | dating_goal | dealbreaker | style | pattern
  key           text not null, -- e.g. preferred_tone
  value_json    jsonb not null,
  confidence    float4 default 0.8,
  source        text, -- e.g. onboarding | chat_inference | user_explicit
  expires_at    timestamptz,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now(),
  unique(user_id, category, key)
);

alter table ai_user_memory_facts enable row level security;
create policy "users manage own facts"
  on ai_user_memory_facts for all
  using (auth.uid() = user_id);

create index ai_user_memory_facts_user_idx on ai_user_memory_facts(user_id, category);

-- =============================================
-- 2. ai_user_memory_notes
-- Soft learnings and patterns per user
-- =============================================
create table if not exists ai_user_memory_notes (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users(id) on delete cascade,
  note_type             text not null, -- pattern | lesson | warning | preference
  content               text not null,
  importance_score      float4 default 0.5,
  created_from_event_id uuid,
  created_at            timestamptz default now()
);

alter table ai_user_memory_notes enable row level security;
create policy "users manage own notes"
  on ai_user_memory_notes for all
  using (auth.uid() = user_id);

create index ai_user_memory_notes_user_idx on ai_user_memory_notes(user_id, note_type);

-- =============================================
-- 3. ai_user_memory_embeddings
-- Semantic search for user memory
-- =============================================
create table if not exists ai_user_memory_embeddings (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users(id) on delete cascade,
  source_type      text not null, -- chat_summary | interaction_lesson | profile_analysis | match_postmortem
  source_id        uuid,
  chunk_text       text not null,
  embedding        vector(1536),
  importance_score float4 default 0.5,
  created_at       timestamptz default now()
);

alter table ai_user_memory_embeddings enable row level security;
create policy "users manage own embeddings"
  on ai_user_memory_embeddings for all
  using (auth.uid() = user_id);

create index ai_user_memory_embeddings_user_idx on ai_user_memory_embeddings(user_id);

-- Semantic similarity search function for user memory
create or replace function match_user_memory(
  p_user_id   uuid,
  p_embedding vector(1536),
  p_limit     int default 5,
  p_threshold float default 0.7
)
returns table (
  id               uuid,
  chunk_text       text,
  importance_score float4,
  source_type      text,
  similarity       float
)
language sql stable
as $$
  select
    id,
    chunk_text,
    importance_score,
    source_type,
    1 - (embedding <=> p_embedding) as similarity
  from ai_user_memory_embeddings
  where user_id = p_user_id
    and 1 - (embedding <=> p_embedding) > p_threshold
  order by (1 - (embedding <=> p_embedding)) * importance_score desc
  limit p_limit;
$$;

-- =============================================
-- 4. ai_global_memory_docs
-- Product-wide knowledge base
-- =============================================
create table if not exists ai_global_memory_docs (
  id         uuid primary key default gen_random_uuid(),
  doc_type   text not null, -- brand_voice | anti_cringe | dating_framework | safety_rules | messaging_guide | profile_guide | cultural_heuristics
  title      text not null,
  content    text not null,
  version    int default 1,
  is_active  boolean default true,
  created_at timestamptz default now()
);

-- Admins only (no RLS user access)
alter table ai_global_memory_docs enable row level security;
create policy "service role only global docs"
  on ai_global_memory_docs for all
  using (false); -- only accessible via service role key in edge functions

-- =============================================
-- 5. ai_global_memory_embeddings
-- Embeddings for global knowledge
-- =============================================
create table if not exists ai_global_memory_embeddings (
  id         uuid primary key default gen_random_uuid(),
  doc_id     uuid not null references ai_global_memory_docs(id) on delete cascade,
  chunk_text text not null,
  embedding  vector(1536),
  priority   float4 default 0.5,
  created_at timestamptz default now()
);

alter table ai_global_memory_embeddings enable row level security;
create policy "service role only global embeddings"
  on ai_global_memory_embeddings for all
  using (false);

create or replace function match_global_memory(
  p_embedding vector(1536),
  p_doc_type  text default null,
  p_limit     int default 5,
  p_threshold float default 0.7
)
returns table (
  id         uuid,
  chunk_text text,
  priority   float4,
  doc_type   text,
  similarity float
)
language sql stable
as $$
  select
    e.id,
    e.chunk_text,
    e.priority,
    d.doc_type,
    1 - (e.embedding <=> p_embedding) as similarity
  from ai_global_memory_embeddings e
  join ai_global_memory_docs d on d.id = e.doc_id
  where d.is_active = true
    and (p_doc_type is null or d.doc_type = p_doc_type)
    and 1 - (e.embedding <=> p_embedding) > p_threshold
  order by (1 - (e.embedding <=> p_embedding)) * e.priority desc
  limit p_limit;
$$;

-- =============================================
-- 6. ai_conversation_state
-- Running state per chat thread
-- =============================================
create table if not exists ai_conversation_state (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references auth.users(id) on delete cascade,
  conversation_id       text not null, -- match_id or chat session id
  screen_context        text,
  rolling_summary       text,
  latest_goal           text,
  latest_emotional_state text,
  last_ai_strategy      text,
  updated_at            timestamptz default now(),
  unique(user_id, conversation_id)
);

alter table ai_conversation_state enable row level security;
create policy "users manage own conversation state"
  on ai_conversation_state for all
  using (auth.uid() = user_id);

create index ai_conversation_state_user_idx on ai_conversation_state(user_id, conversation_id);

-- =============================================
-- 7. ai_events
-- Full audit trail
-- =============================================
create table if not exists ai_events (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid references auth.users(id) on delete set null,
  conversation_id       text,
  event_type            text not null, -- message_suggestion | reply_analysis | profile_rewrite | bio_generation | etc.
  input_json            jsonb,
  output_json           jsonb,
  latency_ms            int,
  model                 text,
  tokens_in             int,
  tokens_out            int,
  moderation_result_json jsonb,
  variant_chosen        text, -- safe | playful | bold
  feedback_sent         boolean,
  reply_received        boolean,
  created_at            timestamptz default now()
);

alter table ai_events enable row level security;
create policy "users view own events"
  on ai_events for select
  using (auth.uid() = user_id);
-- inserts happen via service role in edge functions

create index ai_events_user_idx on ai_events(user_id, event_type, created_at desc);

-- =============================================
-- Seed global knowledge base
-- =============================================
insert into ai_global_memory_docs (doc_type, title, content, version) values
(
  'brand_voice',
  'Wingman Brand Voice v1',
  'Wingman ist ein intelligenter Dating-Coach, kein Ghostwriter. Wingman hilft dem User, seine echte Persönlichkeit besser zu zeigen – nicht eine Rolle zu spielen. Tonalität: direkt, warm, manchmal witzig, nie cringe. Keine Phrasen wie "lebe im Moment", "suche meine bessere Hälfte", "liebe lachen". Wingman-Antworten klingen wie ein cooler Freund, der ehrlich ist und weiß was er tut. Nie arrogant, nie unterwürfig.',
  1
),
(
  'anti_cringe',
  'Anti-Cringe Rules DE v1',
  'VERBOTEN in Dating-Texten: "Ich liebe lachen", "spontan und unkompliziert", "lebe im Moment", "suche meine bessere Hälfte", "bin für alles offen", "bin ein großer Familienmensch", "ich bin ein Teamplayer", "Humor ist mir wichtig" (stattdessen zeigen), "ich liebe es zu reisen" (zu generisch), "ich bin ehrgeizig" ohne Kontext. STATTDESSEN: konkret, spezifisch, neugierig machend, ehrlich, mit echtem Inhalt. Kurze Sätze > lange Sätze. Zeigen > Beschreiben.',
  1
),
(
  'messaging_guide',
  'Wingman Messaging Principles v1',
  'Erste Nachricht: Bezug auf Profil, kurze Frage oder Kommentar, max 2 Sätze, kein "Hey wie gehts". Follow-up nach Ghosting: max 1x, locker, kein Vorwurf. Antwort auf kurze Nachrichten: nicht überanalyieren, eigene Energie reinbringen. Eskalation Richtung Date: konkret werden, Vorschlag machen, nicht endlos chatten. Konflikte: ruhig bleiben, nicht verteidigen, Standpunkt halten.',
  1
),
(
  'cultural_heuristics',
  'DE Dating Cultural Context v1',
  'In Deutschland ist Dating direkter als in den USA. Zu viele Komplimente wirken schnell unauthentisch. Humor und Ironie werden geschätzt. Zu frühes emotionales Investieren wirkt unsicher. Date-Vorschläge konkret machen (was, wo, wann) statt vage "wir sollten mal". WhatsApp ist der primäre Kanal. Zu langes App-Chatten ohne Date-Vorschlag gilt als kein echtes Interesse.',
  1
),
(
  'safety_rules',
  'Wingman Safety Rules v1',
  'NIEMALS empfehlen: Manipulation durch emotionalen Druck, Drohungen, Lügen über Identität oder Absichten, sexualisierte Nachrichten ohne klaren Kontext, Stalking-artige Taktiken wie mehrfaches Schreiben nach Ablehnung, Texte die sich als die andere Person ausgeben, Inhalte die Minderjährige betreffen. IMMER sicherstellen: Antworten respektieren Grenzen, fördern echte Verbindungen, sind konsensbasiert.',
  1
);
