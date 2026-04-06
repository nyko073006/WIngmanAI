import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import OpenAI from "npm:openai";
import { createClient } from "npm:@supabase/supabase-js";

const openai = new OpenAI({ apiKey: Deno.env.get("OPENAI_API_KEY")! });

// Tier-to-limit mapping lives in the consume_ai_credit DB function → not here.

Deno.serve(async (req) => {
  try {
    // ── 1. Auth ──────────────────────────────────────────────────────────
    const authHeader = req.headers.get("Authorization");
    if (!authHeader?.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { "content-type": "application/json" },
      });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: { user }, error: authError } = await supabase.auth.getUser(
      authHeader.replace("Bearer ", ""),
    );
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { "content-type": "application/json" },
      });
    }

    // ── 2. Rate limit ──────────────────────────────────────────────────────
    const { data: allowed } = await supabase.rpc("consume_ai_credit", { p_user_id: user.id });
    if (!allowed) return new Response(JSON.stringify({ error: "Daily AI limit reached. Upgrade to get more." }), { status: 429, headers: { "content-type": "application/json" } });

    // ── 3. AI call ────────────────────────────────────────────────────────
    const input = await req.json();

    const theirName: string = input.theirName ?? "der andere";
    const theirBio: string | null = input.theirBio ?? null;
    const theirInterests: string[] = Array.isArray(input.theirInterests) ? input.theirInterests : [];
    const conversation: { role: string; text: string }[] = Array.isArray(input.conversation)
      ? input.conversation
      : [];

    const profileCtx = [
      theirBio ? `Bio: ${theirBio}` : null,
      theirInterests.length > 0 ? `Interessen: ${theirInterests.join(", ")}` : null,
    ]
      .filter(Boolean)
      .join("\n");

    const convoText = conversation
      .map((m) => `${m.role === "me" ? "Ich" : theirName}: ${m.text}`)
      .join("\n");

    const system = [
      "Du bist Wingman, ein KI-Assistent für Dating-Chats.",
      "Generiere kurze, natürliche Antwortvorschläge auf Deutsch.",
      "Sei charmant und authentisch — kein Cringe, kein Aufdrängen.",
      "Gib genau 3 Vorschläge zurück, unterschiedlich in Ton und Länge.",
      'Return ONLY valid JSON: { "suggestions": ["...", "...", "..."] }',
    ].join(" ");

    const user_prompt = {
      goal: "Generiere 3 passende Antworten für mich.",
      context: {
        theirName,
        theirProfile: profileCtx || null,
        conversation: convoText || "(noch keine Nachrichten)",
      },
      output_schema: { suggestions: ["string"] },
    };

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 60_000);
    let r;
    try {
      r = await openai.chat.completions.create({
        model: "gpt-4o-mini",
        messages: [
          { role: "system", content: system },
          { role: "user", content: JSON.stringify(user_prompt) },
        ],
        response_format: { type: "json_object" },
      }, { signal: controller.signal });
    } finally {
      clearTimeout(timeout);
    }

    const output_text = r.choices[0].message.content ?? "{}";

    return new Response(output_text, {
      headers: { "content-type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
});
