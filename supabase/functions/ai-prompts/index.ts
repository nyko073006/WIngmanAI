import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import OpenAI from "npm:openai";
import { createClient } from "npm:@supabase/supabase-js";

const openai = new OpenAI({ apiKey: Deno.env.get("OPENAI_API_KEY")! });



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

    // ── 2. Rate limit (tier limits enforced in DB function) ──────────────
    const { data: allowed, error: rpcError } = await supabase.rpc(
      "consume_ai_credit",
      { p_user_id: user.id },
    );

    if (rpcError || !allowed) {
      return new Response(
        JSON.stringify({ error: "Daily AI limit reached. Upgrade to get more." }),
        { status: 429, headers: { "content-type": "application/json" } },
      );
    }

    // ── 3. AI call ────────────────────────────────────────────────────────
    const input = await req.json();

    if (!Array.isArray(input?.prompts) || input.prompts.length !== 3) {
      return new Response(JSON.stringify({ error: "prompts must be exactly 3" }), { status: 400 });
    }

    const system = [
      "You generate short dating-app prompt answers.",
      "Return ONLY valid JSON.",
      "No cringe, no generic lines, no sexual content.",
      "Answers must be conversation-starters.",
      "Language: German.",
    ].join(" ");

    const user_prompt = {
      goal: "For each of 3 prompts, generate 3 candidate answers.",
      style: input.style ?? "balanced",
      adjustment: input.adjustment ?? null,
      context: {
        displayName: input.displayName ?? null,
        lookingFor: input.lookingFor ?? null,
        interests: input.interests ?? [],
        city: input.city ?? null,
      },
      prompts: input.prompts,
      output_schema: { answers: [["string"]] },
      constraints: { perAnswerMaxChars: 140 },
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
