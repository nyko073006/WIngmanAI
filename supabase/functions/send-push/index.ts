// send-push: fires APNs push when a new message is inserted.
// Triggered via Supabase Database Webhook (INSERT on public.messages).
//
// Required env vars (set in Supabase Dashboard → Edge Functions → Secrets):
//   APNS_KEY_ID      – 10-char Key ID from Apple Developer Portal
//   APNS_TEAM_ID     – 10-char Team ID from Apple Developer Account
//   APNS_BUNDLE_ID   – e.g. com.yourcompany.WingmanAI
//   APNS_PRIVATE_KEY – Contents of your .p8 key file (include header/footer lines)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const APNS_KEY_ID     = Deno.env.get("APNS_KEY_ID")!;
const APNS_TEAM_ID    = Deno.env.get("APNS_TEAM_ID")!;
const APNS_BUNDLE_ID  = Deno.env.get("APNS_BUNDLE_ID")!;
const APNS_PRIVATE_KEY = Deno.env.get("APNS_PK")!;

// ---------------------------------------------------------------------------
// APNs JWT
// ---------------------------------------------------------------------------

let cachedJWT: { token: string; issuedAt: number } | null = null;

async function getAPNsJWT(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  // Reuse token for up to 55 minutes (APNs allows up to 60)
  if (cachedJWT && now - cachedJWT.issuedAt < 55 * 60) {
    return cachedJWT.token;
  }

  const b64url = (obj: object) =>
    btoa(JSON.stringify(obj))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=/g, "");

  const header  = b64url({ alg: "ES256", kid: APNS_KEY_ID });
  const payload = b64url({ iss: APNS_TEAM_ID, iat: now });
  const signingInput = `${header}.${payload}`;

  // Strip PEM headers and decode
  const pem = APNS_PRIVATE_KEY
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");
  const keyBytes = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));

  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );

  const sigBytes = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );

  const sig = btoa(String.fromCharCode(...new Uint8Array(sigBytes)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");

  const token = `${signingInput}.${sig}`;
  cachedJWT = { token, issuedAt: now };
  return token;
}

// ---------------------------------------------------------------------------
// Send one APNs push
// ---------------------------------------------------------------------------

async function sendAPNs(
  deviceToken: string,
  title: string,
  body: string,
  matchId: string,
  badge: number,
): Promise<void> {
  const jwt = await getAPNsJWT();
  const url = `https://api.push.apple.com/3/device/${deviceToken}`;

  const apnsPayload = JSON.stringify({
    aps: {
      alert: { title, body },
      sound: "default",
      badge,
    },
    matchId,
  });

  const resp = await fetch(url, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-expiration": "0",
      "content-type": "application/json",
    },
    body: apnsPayload,
  });

  if (!resp.ok) {
    const text = await resp.text();
    console.error(`APNs ${resp.status} for ${deviceToken}: ${text}`);
  }
}

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  try {
    const body = await req.json();

    // Supabase DB Webhook payload: { type, table, schema, record, old_record }
    const record = body.record;
    if (!record) {
      return new Response(JSON.stringify({ error: "no record" }), { status: 400 });
    }

    const matchId: string  = record.match_id;
    const senderId: string = record.sender_id;
    const text: string     = record.text ?? "";

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Resolve recipient from match
    const { data: match } = await supabase
      .from("matches")
      .select("user_low, user_high")
      .eq("id", matchId)
      .single();

    if (!match) {
      return new Response(JSON.stringify({ error: "match not found" }), { status: 404 });
    }

    const recipientId: string =
      match.user_low === senderId ? match.user_high : match.user_low;

    // Sender display name
    const { data: senderProfile } = await supabase
      .from("profiles")
      .select("display_name")
      .eq("user_id", senderId)
      .single();

    const senderName: string = (senderProfile?.display_name ?? "Jemand").substring(0, 50);

    // Recipient device tokens
    const { data: devices } = await supabase
      .from("user_devices")
      .select("token")
      .eq("user_id", recipientId)
      .eq("platform", "ios");

    if (!devices || devices.length === 0) {
      return new Response(JSON.stringify({ sent: 0 }), { status: 200 });
    }

    // Determine dynamic badge count: unread messages in this match for recipient
    const { data: readRow } = await supabase
      .from("match_reads")
      .select("last_seen_at")
      .eq("user_id", recipientId)
      .eq("match_id", matchId)
      .single();

    const lastSeenAt: string = readRow?.last_seen_at ?? "1970-01-01T00:00:00Z";

    const { count: unreadCount } = await supabase
      .from("messages")
      .select("id", { count: "exact", head: true })
      .eq("match_id", matchId)
      .neq("sender_id", recipientId)
      .gt("created_at", lastSeenAt);

    const badge = Math.max(1, unreadCount ?? 1);

    const isImage   = text.startsWith("[IMG]");
    const bodyText  = (isImage ? "📷 hat ein Foto gesendet" : text).substring(0, 100);

    const results = await Promise.allSettled(
      devices.map((d: { token: string }) =>
        sendAPNs(d.token, senderName, bodyText, matchId, badge)
      ),
    );

    const sent = results.filter((r) => r.status === "fulfilled").length;
    return new Response(JSON.stringify({ sent }), {
      headers: { "content-type": "application/json" },
    });
  } catch (err) {
    console.error("send-push error:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
});
