import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js";
import OpenAI from "npm:openai";

const openai = new OpenAI({ apiKey: Deno.env.get("OPENAI_API_KEY")! });
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Called asynchronously after AI responses to update memory
Deno.serve(async (req) => {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return new Response("Unauthorized", { status: 401 });

  const supabase = createClient(SUPABASE_URL, SERVICE_KEY);
  const { data: { user } } = await supabase.auth.getUser(authHeader.replace("Bearer ", ""));
  if (!user) return new Response("Unauthorized", { status: 401 });

  const { event_id, user_id, conversation_id, task_type, input_json, output_json } = await req.json();
  if (user_id !== user.id) return new Response("Forbidden", { status: 403 });

  try {
    // 1. Extract and store memory candidates as notes
    const candidates: string[] = output_json?.memory_candidates ?? [];
    for (const candidate of candidates.slice(0, 5)) {
      if (candidate.length < 10) continue;
      await supabase.from("ai_user_memory_notes").insert({
        user_id,
        note_type: "lesson",
        content: candidate,
        importance_score: 0.65,
        created_from_event_id: event_id,
      });
    }

    // 2. Update conversation rolling summary
    if (conversation_id && output_json?.summary) {
      await supabase.from("ai_conversation_state").upsert({
        user_id,
        conversation_id,
        rolling_summary: output_json.summary,
        latest_goal: input_json?.user_goal ?? null,
        last_ai_strategy: task_type,
        updated_at: new Date().toISOString(),
      }, { onConflict: "user_id,conversation_id" });
    }

    // 3. Extract hard facts if present (e.g. from profile analysis)
    if (output_json?.facts_to_store) {
      for (const fact of output_json.facts_to_store) {
        await supabase.from("ai_user_memory_facts").upsert({
          user_id,
          category: fact.category,
          key: fact.key,
          value_json: { value: fact.value },
          confidence: fact.confidence ?? 0.7,
          source: task_type,
          updated_at: new Date().toISOString(),
        }, { onConflict: "user_id,category,key" });
      }
    }

    // 4. Generate and store embedding for this interaction (async, best effort)
    const chunkText = buildMemoryChunk(task_type, input_json, output_json);
    if (chunkText.length > 50) {
      try {
        const embRes = await openai.embeddings.create({
          model: "text-embedding-3-small",
          input: chunkText,
        });
        const embedding = embRes.data[0].embedding;
        await supabase.from("ai_user_memory_embeddings").insert({
          user_id,
          source_type: task_type,
          source_id: event_id,
          chunk_text: chunkText,
          embedding,
          importance_score: 0.5,
        });
      } catch (e) {
        console.error("[writeback] embedding failed:", e);
      }
    }

    return new Response(JSON.stringify({ ok: true }), {
      headers: { "content-type": "application/json" },
    });
  } catch (e) {
    console.error("[writeback] error:", e);
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});

function buildMemoryChunk(taskType: string, input: any, output: any): string {
  if (taskType === "message_suggestion" || taskType === "first_message") {
    const best = output?.variants?.[output?.best_variant_index ?? 0]?.text ?? "";
    return `Message suggestion for context: ${input?.screen_context ?? "chat"}. Best variant: ${best}. Strategy: ${output?.summary ?? ""}`;
  }
  if (taskType === "reply_analysis") {
    return `Reply analysis: interest=${output?.interest_label}, mistakes=${(output?.mistakes_by_user ?? []).join(", ")}, next_move=${output?.recommended_next_move ?? ""}`;
  }
  if (taskType === "bio_generation") {
    return `Bio generated with tone=${input?.tone}, length=${input?.length}. Best bio: ${output?.bios?.[output?.best_index ?? 0] ?? ""}`;
  }
  return `${taskType}: ${JSON.stringify(output).slice(0, 300)}`;
}
