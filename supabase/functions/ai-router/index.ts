import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js";
import OpenAI from "npm:openai";

const openai = new OpenAI({ apiKey: Deno.env.get("OPENAI_API_KEY")! });
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// ── Task types ────────────────────────────────────────────────────────────────
type TaskType =
  | "message_suggestion"
  | "reply_analysis"
  | "profile_rewrite"
  | "bio_generation"
  | "conversation_strategy"
  | "red_flag_detection"
  | "date_planning"
  | "confidence_coaching"
  | "first_message";

// ── Global system prompt ──────────────────────────────────────────────────────
const GLOBAL_SYSTEM = `Du bist Wingman, ein intelligenter Dating-Coach für deutschsprachige Nutzer.

DEINE ROLLE:
- Du hilfst dem User, seine echte Persönlichkeit besser zu zeigen – nicht eine Rolle zu spielen
- Du bist ein cooler, ehrlicher Freund – nicht ein Ghostwriter
- Du machst den User attraktiver, authentischer und selbstsicherer

BRAND VOICE:
- Direkt, warm, manchmal witzig – nie cringe, nie unterwürfig, nie arrogant
- Kurze starke Sätze > lange schwache Sätze
- Zeigen > Beschreiben

ABSOLUT VERBOTEN:
- Manipulation, emotionaler Druck, Täuschung über Identität
- Sexualisierte Texte ohne klaren Kontext
- Stalking-artige Taktiken (mehrfach schreiben nach Ablehnung)
- Cringe-Phrasen: "lebe im Moment", "suche meine bessere Hälfte", "liebe lachen", "bin für alles offen"

SPRACHE: Deutsch. Authentisch. Prägnant.`;

Deno.serve(async (req) => {
  const startTime = Date.now();

  // ── 1. Auth ────────────────────────────────────────────────────────────────
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return json({ error: "Unauthorized" }, 401);
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_KEY);
  const { data: { user }, error: authError } = await supabase.auth.getUser(
    authHeader.replace("Bearer ", "")
  );
  if (authError || !user) return json({ error: "Unauthorized" }, 401);

  // ── 2. Rate limit (disabled during dev — re-enable before launch) ─────────
  // TODO: uncomment before App Store launch
  // const { data: allowed } = await supabase.rpc("consume_ai_credit", { p_user_id: user.id });
  // if (!allowed) return json({ error: "Daily AI limit reached. Upgrade to get more." }, 429);

  // ── 3. Parse input ─────────────────────────────────────────────────────────
  const body = await req.json();
  const {
    task_type,
    conversation_id,
    screen_context,
    user_input,
    chat_history = [],
    match_profile,
  } = body;

  if (!task_type) return json({ error: "task_type required" }, 400);

  // ── 4. Moderate input ──────────────────────────────────────────────────────
  if (user_input) {
    const modResult = await moderateText(user_input);
    if (modResult.flagged) {
      await logEvent(supabase, user.id, conversation_id, task_type as TaskType, body, null, Date.now() - startTime, null, null, null, modResult);
      return json({ error: "Input flagged by moderation", moderation: modResult }, 400);
    }
  }

  // ── 5. Load user context ───────────────────────────────────────────────────
  const [facts, notes, convState] = await Promise.all([
    loadUserFacts(supabase, user.id),
    loadUserNotes(supabase, user.id),
    loadConversationState(supabase, user.id, conversation_id),
  ]);

  // ── 6. Build task prompt ───────────────────────────────────────────────────
  const { taskPrompt, outputSchema } = buildTaskConfig(task_type as TaskType, body);

  // ── 7. Assemble context bundle ────────────────────────────────────────────
  const contextBundle = {
    user_memory: {
      facts: facts.slice(0, 10),
      notes: notes.slice(0, 5),
    },
    conversation: {
      rolling_summary: convState?.rolling_summary ?? null,
      latest_goal: convState?.latest_goal ?? null,
      chat_history: chat_history.slice(-15),
    },
    app_context: {
      screen: screen_context ?? null,
      match_profile: match_profile ?? null,
    },
  };

  // ── 8. Generate ───────────────────────────────────────────────────────────
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 55_000);
  let response: any;
  let tokensIn = 0, tokensOut = 0, model = "gpt-5.4-nano";

  try {
    const messages: OpenAI.Chat.ChatCompletionMessageParam[] = [
      { role: "system", content: GLOBAL_SYSTEM },
      {
        role: "user",
        content: JSON.stringify({
          task: taskPrompt,
          context: contextBundle,
          output_schema: outputSchema,
        }),
      },
    ];

    const r = await openai.chat.completions.create({
      model,
      messages,
      response_format: { type: "json_object" },
      temperature: 0.85,
    }, { signal: controller.signal });

    tokensIn  = r.usage?.prompt_tokens ?? 0;
    tokensOut = r.usage?.completion_tokens ?? 0;
    response  = JSON.parse(r.choices[0].message.content ?? "{}");
  } finally {
    clearTimeout(timeout);
  }

  // ── 9. Moderate output ────────────────────────────────────────────────────
  const outputText = response.variants?.map((v: any) => v.text).join(" ") ?? "";
  if (outputText) {
    const outMod = await moderateText(outputText);
    if (outMod.flagged) {
      response.risk_flags = [...(response.risk_flags ?? []), "output_flagged"];
      response.variants = response.variants?.filter((_: any, i: number) => i === 0) ?? [];
    }
  }

  // ── 10. Log event ─────────────────────────────────────────────────────────
  const eventId = await logEvent(
    supabase, user.id, conversation_id, task_type as TaskType,
    body, response, Date.now() - startTime, model, tokensIn, tokensOut, null
  );

  // ── 11. Async writeback (don't await) ─────────────────────────────────────
  EdgeRuntime.waitUntil(
    writebackMemory(supabase, user.id, conversation_id, task_type as TaskType, body, response, eventId)
  );

  return json({ ...response, event_id: eventId });
});

// ── Helpers ───────────────────────────────────────────────────────────────────

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function moderateText(text: string) {
  try {
    const r = await openai.moderations.create({ model: "omni-moderation-latest", input: text });
    return r.results[0];
  } catch {
    return { flagged: false };
  }
}

async function loadUserFacts(supabase: any, userId: string) {
  const { data } = await supabase
    .from("ai_user_memory_facts")
    .select("category, key, value_json, confidence")
    .eq("user_id", userId)
    .order("confidence", { ascending: false })
    .limit(20);
  return data ?? [];
}

async function loadUserNotes(supabase: any, userId: string) {
  const { data } = await supabase
    .from("ai_user_memory_notes")
    .select("note_type, content, importance_score")
    .eq("user_id", userId)
    .order("importance_score", { ascending: false })
    .limit(10);
  return data ?? [];
}

async function loadConversationState(supabase: any, userId: string, conversationId?: string) {
  if (!conversationId) return null;
  const { data } = await supabase
    .from("ai_conversation_state")
    .select("rolling_summary, latest_goal, latest_emotional_state, last_ai_strategy")
    .eq("user_id", userId)
    .eq("conversation_id", conversationId)
    .maybeSingle();
  return data;
}

async function logEvent(
  supabase: any, userId: string, conversationId: string | undefined,
  eventType: TaskType, input: any, output: any, latencyMs: number,
  model: string | null, tokensIn: number | null, tokensOut: number | null,
  moderationResult: any
) {
  const { data } = await supabase
    .from("ai_events")
    .insert({
      user_id: userId,
      conversation_id: conversationId,
      event_type: eventType,
      input_json: input,
      output_json: output,
      latency_ms: latencyMs,
      model,
      tokens_in: tokensIn,
      tokens_out: tokensOut,
      moderation_result_json: moderationResult,
    })
    .select("id")
    .single();
  return data?.id;
}

async function writebackMemory(
  supabase: any, userId: string, conversationId: string | undefined,
  taskType: TaskType, input: any, output: any, eventId: string
) {
  try {
    // Extract memory candidates from response
    const memoryCandidates: string[] = output?.memory_candidates ?? [];
    for (const candidate of memoryCandidates.slice(0, 3)) {
      await supabase.from("ai_user_memory_notes").insert({
        user_id: userId,
        note_type: "lesson",
        content: candidate,
        importance_score: 0.6,
        created_from_event_id: eventId,
      });
    }

    // Update conversation state rolling summary if relevant
    if (conversationId && output?.summary) {
      await supabase.from("ai_conversation_state").upsert({
        user_id: userId,
        conversation_id: conversationId,
        rolling_summary: output.summary,
        latest_goal: input.user_goal ?? null,
        last_ai_strategy: output.task_type ?? taskType,
        updated_at: new Date().toISOString(),
      }, { onConflict: "user_id,conversation_id" });
    }
  } catch (e) {
    console.error("[writeback] error:", e);
  }
}

// ── Task configs ──────────────────────────────────────────────────────────────

function buildTaskConfig(taskType: TaskType, input: any): { taskPrompt: string; outputSchema: object } {
  switch (taskType) {
    case "message_suggestion":
    case "first_message":
      return {
        taskPrompt: `Generiere 3 Nachricht-Varianten für den User.
Match-Profil vorhanden: ${JSON.stringify(input.match_profile ?? {})}.
Letzter Chatverlauf: ${JSON.stringify(input.chat_history?.slice(-5) ?? [])}.
Jede Variante soll einen anderen Ansatz haben: safe (freundlich-sicher), playful (leicht flirty), bold (direkt-mutig).
Maximal 2 Sätze pro Variante. Kein "Hey", kein generisches Kompliment.`,
        outputSchema: messageSuggestionSchema,
      };

    case "reply_analysis":
      return {
        taskPrompt: `Analysiere den folgenden Chatverlauf aus Sicht des Users.
Chat: ${JSON.stringify(input.chat_history ?? [])}.
Bewerte: Interesse des Matches, Fehler des Users, empfohlene nächste Aktion.`,
        outputSchema: replyAnalysisSchema,
      };

    case "bio_generation":
      return {
        taskPrompt: `Erstelle 3 Bio-Varianten auf Deutsch für das Profil.
Stil: ${input.tone ?? "authentisch"}. Länge: ${input.length ?? "medium"} (medium = 3 Sätze, long = 5-6 Sätze).
Interessen: ${JSON.stringify(input.interests ?? [])}.
Jede Variante mit unterschiedlichem Fokus: Persönlichkeit, Lifestyle, Hook.`,
        outputSchema: bioGenerationSchema,
      };

    case "conversation_strategy":
      return {
        taskPrompt: `Analysiere die aktuelle Gesprächsdynamik und gib eine klare Strategie.
Chat: ${JSON.stringify(input.chat_history?.slice(-10) ?? [])}.
Ziel des Users: ${input.user_goal ?? "unbekannt"}.`,
        outputSchema: conversationStrategySchema,
      };

    case "red_flag_detection":
      return {
        taskPrompt: `Analysiere diesen Chatverlauf auf Red Flags.
Chat: ${JSON.stringify(input.chat_history ?? [])}.
Gib konkrete Warnsignale und Handlungsempfehlungen.`,
        outputSchema: redFlagSchema,
      };

    case "confidence_coaching":
      return {
        taskPrompt: `Der User braucht Coaching-Feedback basierend auf: ${input.user_input ?? ""}.
Gib konkretes, ehrliches Feedback und einen Aktionsplan. Keine leeren Aufmunterungen.`,
        outputSchema: coachingSchema,
      };

    default:
      return {
        taskPrompt: `Beantworte die folgende Anfrage im Kontext von Dating-Coaching: ${input.user_input ?? ""}`,
        outputSchema: genericSchema,
      };
  }
}

// ── Output schemas ────────────────────────────────────────────────────────────

const messageSuggestionSchema = {
  task_type: "message_suggestion",
  summary: "string – kurze Beschreibung der Strategie",
  variants: [
    { label: "safe", text: "string" },
    { label: "playful", text: "string" },
    { label: "bold", text: "string" },
  ],
  best_variant_index: "number (0-2)",
  confidence: "number (0-1)",
  risk_flags: ["string"],
  memory_candidates: ["string – lernenswertes über den User"],
  ui_hints: { tone: "string", length: "short|medium" },
};

const replyAnalysisSchema = {
  task_type: "reply_analysis",
  interest_score: "number (0-10)",
  interest_label: "string (kalt/neutral/warm/sehr interessiert)",
  red_flags: ["string"],
  mistakes_by_user: ["string"],
  recommended_next_move: "string",
  confidence: "number (0-1)",
  memory_candidates: ["string"],
};

const bioGenerationSchema = {
  task_type: "bio_generation",
  bios: ["string – 3 bio variants"],
  best_index: "number (0-2)",
  summary: "string",
};

const conversationStrategySchema = {
  task_type: "conversation_strategy",
  current_dynamic: "string",
  recommended_strategy: "string",
  next_concrete_action: "string",
  risk_level: "low|medium|high",
  memory_candidates: ["string"],
};

const redFlagSchema = {
  task_type: "red_flag_detection",
  red_flags: [{ flag: "string", severity: "low|medium|high", explanation: "string" }],
  overall_risk: "low|medium|high",
  recommendation: "string",
};

const coachingSchema = {
  task_type: "confidence_coaching",
  feedback: "string",
  action_items: ["string"],
  encouragement: "string",
  memory_candidates: ["string"],
};

const genericSchema = {
  task_type: "generic",
  response: "string",
  memory_candidates: ["string"],
};
