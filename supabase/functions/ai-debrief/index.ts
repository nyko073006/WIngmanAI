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
        status: 401, headers: { "content-type": "application/json" },
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
        status: 401, headers: { "content-type": "application/json" },
      });
    }

    // ── 2. Rate limit ────────────────────────────────────────────────────
    const { data: allowed, error: rpcError } = await supabase.rpc(
      "consume_ai_credit", { p_user_id: user.id },
    );
    if (rpcError || !allowed) {
      return new Response(
        JSON.stringify({ error: "Daily AI limit reached. Upgrade to get more." }),
        { status: 429, headers: { "content-type": "application/json" } },
      );
    }

    // ── 3. Input ─────────────────────────────────────────────────────────
    const input = await req.json();
    const rating: number = Number(input.rating ?? 3);
    const notes: string  = String(input.notes ?? "").substring(0, 1000);
    const matchId: string = String(input.match_id ?? "");

    if (!matchId || rating < 1 || rating > 5) {
      return new Response(JSON.stringify({ error: "match_id and rating (1-5) required" }), {
        status: 400, headers: { "content-type": "application/json" },
      });
    }

    // ── 4. Load past debriefs for pattern recognition ────────────────────
    const { data: pastDebriefs } = await supabase
      .from("date_debriefs")
      .select("rating, notes, ai_feedback, created_at")
      .eq("user_id", user.id)
      .order("created_at", { ascending: false })
      .limit(10);

    const hasPastData = pastDebriefs && pastDebriefs.length > 0;

    // ── 5. AI call ────────────────────────────────────────────────────────
    const stars = "⭐".repeat(rating);
    const pastSummary = hasPastData
      ? pastDebriefs.map((d: { rating: number; notes: string }, i: number) =>
          `Date ${i + 1}: ${d.rating}/5 Sterne — ${d.notes || "(keine Notizen)"}`
        ).join("\n")
      : null;

    const system = [
      "Du bist ein empathischer Dating-Coach. Deine Aufgabe ist es, nach einem Date ehrliches, konstruktives Feedback zu geben.",
      "Antworte immer auf Deutsch. Sei direkt aber warmherzig.",
      "Return ONLY valid JSON.",
    ].join(" ");

    const userPrompt = {
      thisDate: { rating, stars, notes: notes || "(keine Notizen)" },
      pastDates: pastSummary,
      tasks: [
        "feedback: 2-3 Sätze konkretes Feedback zu diesem Date. Was lief gut? Was könnte besser sein?",
        hasPastData
          ? "patterns: Falls du über mehrere Dates Muster erkennst (z.B. immer zu früh über Zukunft reden, nervös bei Stille, etc.), beschreibe sie in 1-2 Sätzen. Sonst null."
          : "patterns: null (zu wenig Daten)",
      ],
      output_schema: { feedback: "string", patterns: "string | null" },
    };

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 60_000);
    let r;
    try {
      r = await openai.chat.completions.create({
        model: "gpt-4o",
        messages: [
          { role: "system", content: system },
          { role: "user", content: JSON.stringify(userPrompt) },
        ],
        response_format: { type: "json_object" },
      }, { signal: controller.signal });
    } finally {
      clearTimeout(timeout);
    }

    const result = JSON.parse(r.choices[0].message.content ?? "{}");
    const feedback: string = result.feedback ?? "";
    const patterns: string | null = result.patterns ?? null;

    // ── 6. Save debrief to DB ─────────────────────────────────────────────
    await supabase.from("date_debriefs").insert({
      user_id:     user.id,
      match_id:    matchId,
      rating,
      notes,
      ai_feedback: feedback,
      ai_patterns: patterns,
    });

    return new Response(JSON.stringify({ feedback, patterns }), {
      headers: { "content-type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), {
      status: 500, headers: { "content-type": "application/json" },
    });
  }
});
