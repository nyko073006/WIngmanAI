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

    if (rpcError) { console.warn("consume_ai_credit RPC error:", rpcError.message); }
    if (!allowed) {
      return new Response(
        JSON.stringify({ error: "Daily AI limit reached. Upgrade to get more." }),
        { status: 429, headers: { "content-type": "application/json" } },
      );
    }

    // ── 3. AI call ────────────────────────────────────────────────────────
    const input = await req.json();

    const maxHooks = Number(input.maxHooks ?? 10);
    const maxVibes = Number(input.maxVibes ?? 8);

    const system = `You generate personalized conversation hooks and first date vibes for a German dating app profile.
Return ONLY valid JSON: {"hooks": ["..."], "firstDateVibes": ["..."]}.

HOOKS — strict rules:
- First-person statements, max 90 chars each.
- Must be specific to THIS person's interests/bio/city — never generic copy-paste.
- Must spark curiosity or a concrete question in the reader's mind.
- FORBIDDEN (reject these outright): "spontan", "ich liebe das Leben", "ich lebe im Moment", "ich liebe es zu reisen", "ich bin offen für Neues", "Humor ist mir wichtig", "ich bin teamplayer".
- GOOD examples: "Ich kann dir in 30 Sekunden sagen, ob ein Café was taugt.", "Ich hab eine Playlist für jeden Stimmungstyp – welcher bist du?", "Ich rate deinen Vibe an deinem Lieblingssong.", "Meine schlechteste Idee war [something specific]. Würd ich sofort wieder machen."
- BAD examples (too generic — never output these): "Ich bin immer down für Spontanes.", "Ich liebe es zu reisen.", "Ich bin ein kreativer Mensch."

FIRST DATE VIBES — strict rules:
- Short evocative phrase, 2–5 words. Specific activity or place type.
- Mix: calm/cozy + active + cultural. No alcohol focus.
- GOOD examples: "Kaffee & ehrliche Gespräche", "Abendspaziergang mit Snacks", "Flohmarkt-Date", "Kletterpark-Challenge", "Sonnenuntergang-Spot", "Buchhandlung stöbern".

Language: German. Use grammatically correct gendered forms based on the 'gender' field (männlich → masculine, weiblich → feminine, divers/null → neutral).`;

    const user_prompt = {
      context: {
        gender: input.gender ?? null,
        interestedIn: input.interestedIn ?? null,
        lookingFor: input.lookingFor ?? null,
        city: input.city ?? null,
        interests: input.interests ?? [],
        bio: input.bio ?? null,
        promptAnswers: input.promptAnswers ?? [],
      },
      output_schema: { hooks: `array of ${maxHooks} strings`, firstDateVibes: `array of ${maxVibes} strings` },
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

    const raw = JSON.parse(r.choices[0].message.content ?? "{}");
    raw.hooks = (raw.hooks ?? []).slice(0, maxHooks);
    raw.firstDateVibes = (raw.firstDateVibes ?? []).slice(0, maxVibes);

    return new Response(JSON.stringify(raw), {
      headers: { "content-type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
});
