// send-push-debrief: daily cron job that reminds users to debrief
// after 7 days of silence in a match.
//
// Called by pg_cron every day at 10:00 UTC.
// Uses same env vars as send-push.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const APNS_KEY_ID      = Deno.env.get("APNS_KEY_ID")!;
const APNS_TEAM_ID     = Deno.env.get("APNS_TEAM_ID")!;
const APNS_BUNDLE_ID   = Deno.env.get("APNS_BUNDLE_ID")!;
const APNS_PRIVATE_KEY = Deno.env.get("APNS_PK")!;

// ── APNs JWT ──────────────────────────────────────────────────────────────────

let cachedJWT: { token: string; issuedAt: number } | null = null;

async function getAPNsJWT(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJWT && now - cachedJWT.issuedAt < 55 * 60) return cachedJWT.token;

  const b64url = (obj: object) =>
    btoa(JSON.stringify(obj)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");

  const header  = b64url({ alg: "ES256", kid: APNS_KEY_ID });
  const payload = b64url({ iss: APNS_TEAM_ID, iat: now });
  const signingInput = `${header}.${payload}`;

  const pem = APNS_PRIVATE_KEY
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");
  const keyBytes = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8", keyBytes, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  const sigBytes = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, cryptoKey,
    new TextEncoder().encode(signingInput),
  );
  const sig = btoa(String.fromCharCode(...new Uint8Array(sigBytes)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");

  const token = `${signingInput}.${sig}`;
  cachedJWT = { token, issuedAt: now };
  return token;
}

async function sendAPNs(
  deviceToken: string,
  title: string,
  body: string,
  matchId: string,
): Promise<void> {
  const jwt = await getAPNsJWT();
  const resp = await fetch(`https://api.push.apple.com/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-expiration": "0",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      aps: { alert: { title, body }, sound: "default", badge: 1 },
      matchId,
      type: "debrief_reminder",
    }),
  });
  if (!resp.ok) {
    console.error(`APNs ${resp.status}: ${await resp.text()}`);
  }
}

// ── Handler ───────────────────────────────────────────────────────────────────

Deno.serve(async () => {
  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
    const eightDaysAgo = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000).toISOString();

    // Find matches where the last message was exactly 7 days ago (±1 day window)
    const { data: silentMatches } = await supabase
      .from("messages")
      .select("match_id, sender_id, created_at")
      .gte("created_at", eightDaysAgo)
      .lte("created_at", sevenDaysAgo)
      .order("created_at", { ascending: false });

    if (!silentMatches?.length) {
      return new Response(JSON.stringify({ sent: 0 }), { status: 200 });
    }

    // Deduplicate: one push per match, per participant
    const seen = new Set<string>();
    const toNotify: { matchId: string; userId: string }[] = [];

    for (const msg of silentMatches) {
      const key = msg.match_id;
      if (seen.has(key)) continue;
      seen.add(key);

      // Get both participants
      const { data: match } = await supabase
        .from("matches")
        .select("user_low, user_high")
        .eq("id", msg.match_id)
        .single();

      if (!match) continue;

      // Check: no newer messages exist in this match
      const { count } = await supabase
        .from("messages")
        .select("id", { count: "exact", head: true })
        .eq("match_id", msg.match_id)
        .gt("created_at", sevenDaysAgo);

      if ((count ?? 0) > 0) continue; // Messages were sent after the window — skip

      // Check: user hasn't already submitted a debrief for this match
      for (const userId of [match.user_low, match.user_high]) {
        const { count: debriefCount } = await supabase
          .from("date_debriefs")
          .select("id", { count: "exact", head: true })
          .eq("user_id", userId)
          .eq("match_id", msg.match_id);

        if ((debriefCount ?? 0) === 0) {
          toNotify.push({ matchId: msg.match_id, userId });
        }
      }
    }

    let sent = 0;
    for (const { matchId, userId } of toNotify) {
      // Get other user's name
      const { data: match } = await supabase
        .from("matches")
        .select("user_low, user_high")
        .eq("id", matchId)
        .single();
      if (!match) continue;

      const otherUserId = match.user_low === userId ? match.user_high : match.user_low;
      const { data: otherProfile } = await supabase
        .from("profiles")
        .select("display_name")
        .eq("user_id", otherUserId)
        .single();

      const otherName = (otherProfile?.display_name ?? "Jemand").substring(0, 50);

      // Get device tokens
      const { data: devices } = await supabase
        .from("user_devices")
        .select("token")
        .eq("user_id", userId)
        .eq("platform", "ios");

      for (const d of (devices ?? [])) {
        await sendAPNs(
          d.token,
          "Wie war das Date? 💬",
          `Wie lief's mit ${otherName}? Mach ein kurzes Debrief.`,
          matchId,
        );
        sent++;
      }
    }

    return new Response(JSON.stringify({ sent }), {
      headers: { "content-type": "application/json" },
    });
  } catch (err) {
    console.error("send-push-debrief error:", err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
