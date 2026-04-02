// send-push-match: fires APNs push to BOTH users when a new match is created.
// Triggered via Supabase Database Webhook (INSERT on public.matches).
//
// Uses the same env vars as send-push:
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID, APNS_PK

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const APNS_KEY_ID      = Deno.env.get("APNS_KEY_ID")!;
const APNS_TEAM_ID     = Deno.env.get("APNS_TEAM_ID")!;
const APNS_BUNDLE_ID   = Deno.env.get("APNS_BUNDLE_ID")!;
const APNS_PRIVATE_KEY = Deno.env.get("APNS_PK")!;

// ---------------------------------------------------------------------------
// APNs JWT (same as send-push)
// ---------------------------------------------------------------------------

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

async function sendAPNs(deviceToken: string, title: string, body: string): Promise<void> {
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
    }),
  });
  if (!resp.ok) {
    console.error(`APNs ${resp.status} for ${deviceToken}: ${await resp.text()}`);
  }
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  try {
    const body = await req.json();
    const record = body.record;
    if (!record) return new Response(JSON.stringify({ error: "no record" }), { status: 400 });

    const userLow: string  = record.user_low;
    const userHigh: string = record.user_high;

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Load display names for both users
    const { data: profiles } = await supabase
      .from("profiles")
      .select("user_id, display_name")
      .in("user_id", [userLow, userHigh]);

    const names = new Map<string, string>(
      (profiles ?? []).map((p: { user_id: string; display_name: string | null }) => [
        p.user_id, p.display_name ?? "Jemand",
      ]),
    );

    // Load device tokens for both users
    const { data: devices } = await supabase
      .from("user_devices")
      .select("user_id, token")
      .in("user_id", [userLow, userHigh])
      .eq("platform", "ios");

    if (!devices?.length) return new Response(JSON.stringify({ sent: 0 }), { status: 200 });

    // Notify each user about their new match
    const pushes = (devices as { user_id: string; token: string }[]).map((d) => {
      const otherUserId = d.user_id === userLow ? userHigh : userLow;
      const otherName   = names.get(otherUserId) ?? "Jemand";
      return sendAPNs(d.token, "It's a Match! 🎉", `Du und ${otherName} habt euch geliked`);
    });

    const results = await Promise.allSettled(pushes);
    const sent = results.filter((r) => r.status === "fulfilled").length;
    return new Response(JSON.stringify({ sent }), { headers: { "content-type": "application/json" } });
  } catch (err) {
    console.error("send-push-match error:", err);
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
