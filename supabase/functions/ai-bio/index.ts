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

    // ── 2. Rate limit (disabled during dev — re-enable before launch) ──────
    // TODO: uncomment before App Store launch
    // await supabase.rpc("consume_ai_credit", { p_user_id: user.id });

    // ── 3. AI call ────────────────────────────────────────────────────────
    const input = await req.json();

    if (!input?.interests || !Array.isArray(input.interests) || input.interests.length < 1) {
      return new Response(JSON.stringify({ error: "interests required (>=1)" }), { status: 400 });
    }

    const tone = input.tone ?? "playful";
    const length = input.length ?? "short";
    const adjustment = input.adjustment ?? null;

    const lengthRule = length === "short"
      ? "LENGTH = SHORT: Exactly 1-2 sentences per bio. Max 130 chars. Punchy, no filler."
      : length === "medium"
      ? "LENGTH = MEDIUM: Exactly 3 sentences per bio. Each sentence on its own line. Min 180 chars, max 300 chars. DO NOT write 1 sentence and call it done. 3 sentences means 3 full sentences."
      : "LENGTH = LONG: Exactly 5-6 sentences per bio. Min 350 chars. Use 2 short paragraphs. Paint a full picture — personality, lifestyle, what to expect.";

    const system = [
      "You generate dating profile bios in German.",
      "Return ONLY valid JSON.",
      "Use correct German grammatical gender based on the gender field (männlich → maskuline, weiblich → feminine, divers → neutral).",
      `MOST IMPORTANT RULE: ${lengthRule}`,
      "OTHER RULES:",
      "1. Each bio has ONE focus only — do NOT pack in multiple facts unless the length asks for it.",
      "2. No lists, no comma overload.",
      "3. No cringe clichés ('lebe im Moment', 'suche meinen Partner', 'liebe lachen').",
      "4. Sound like a real person texting, not a LinkedIn profile.",
    ].join(" ");

    const user_prompt = {
      goal: "Generate exactly 3 bio variants, each with a DIFFERENT single focus angle.",
      angles: {
        bio_1: "Vibe / personality — who they are in one sentence. Mention at most ONE interest.",
        bio_2: "Lifestyle / what they actually do — one specific activity or habit, no fluff.",
        bio_3: "Hook / opener bait — something that invites a reply or shows wit. No info dump.",
      },
      constraints: {
        tone,
        adjustment,
        language: "German",
        targetLength: length === "short"
          ? "1-2 sentences max (120 chars) — punchy & scannable"
          : length === "medium"
          ? "3-4 sentences (280 chars) — show personality, one story or detail"
          : "5-7 sentences (500 chars) — full personality portrait, warm & readable. Use 2-3 short paragraphs if needed.",
        maxCharsPerBio: length === "short" ? 120 : length === "medium" ? 280 : 500,
        rule: length === "short" ? "If you feel the urge to add more facts — don't. Cut instead." : "Be natural and conversational, not listy.",
      },
      context: {
        displayName: input.displayName ?? null,
        gender: input.gender ?? null,
        city: input.city ?? null,
        lookingFor: input.lookingFor ?? null,
        interests: input.interests,
        keywords: Array.isArray(input.keywords) ? input.keywords : [],
      },
      output_schema: { bios: ["string"] },
    };

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 60_000);
    let r;
    try {
      r = await openai.chat.completions.create({
        model: "gpt-4o",
        messages: [
          { role: "system", content: system },
          { role: "user", content: JSON.stringify(user_prompt) },
        ],
        response_format: { type: "json_object" },
      }, { signal: controller.signal });
    } finally {
      clearTimeout(timeout);
    }

    const raw = r.choices[0].message.content ?? "{}";
    const parsed = JSON.parse(raw);

    // Extract a plain string from whatever GPT hands back
    const toStr = (v: unknown): string => {
      if (typeof v === "string") return v;
      if (v && typeof v === "object") {
        const obj = v as Record<string, unknown>;
        // Common wrapper keys GPT uses
        for (const k of ["text", "bio", "content", "value", "bio_1", "bio_2", "bio_3"]) {
          if (typeof obj[k] === "string") return obj[k] as string;
        }
        // First string value in the object
        const first = Object.values(obj).find((x) => typeof x === "string");
        if (first) return first as string;
      }
      return JSON.stringify(v);
    };

    // Normalise to { bios: string[] }
    let bios: string[] = [];
    if (Array.isArray(parsed.bios)) {
      bios = parsed.bios.map(toStr);
    } else {
      // GPT returned { bio_1: "...", bio_2: "...", bio_3: "..." } flat
      bios = Object.values(parsed).map(toStr).filter((s) => s.length > 5);
    }

    return new Response(JSON.stringify({ bios }), {
      headers: { "content-type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
});
