/**
 * Beacon license server — Cloudflare Worker (Stripe).
 *
 * Stripe is a payment processor, not a merchant of record, and it does NOT
 * generate license keys. So unlike the old Lemon Squeezy flow (where LS minted
 * and emailed the key), we mint the key ourselves against a paid Checkout
 * Session, then validate it against the subscription's live status.
 *
 * Endpoints:
 *   POST /claim    {sessionId}  -> verifies a Stripe Checkout Session is paid
 *                                  (or in its free trial) for Beacon's price,
 *                                  mints+stores a BEACON key (idempotent per
 *                                  session), and returns it. Called by the
 *                                  post-purchase thanks page.
 *   POST /validate {key}        -> looks up the stored key and confirms the
 *                                  Stripe subscription is still active/trialing.
 *
 * KV (LICENSES) layout:
 *   session:<SESSION_ID>  -> KEY            (idempotency for /claim)
 *   license:<KEY>         -> {subscriptionId, customerId, email, createdAt}
 *   status:<KEY>          -> {valid, expiresAt}   (24h cache of /validate)
 *
 * Secrets/vars (wrangler):
 *   STRIPE_SECRET_KEY  (secret) — set via `wrangler secret put STRIPE_SECRET_KEY`
 *   STRIPE_PRICE_ID    (var)    — the recurring yearly price the key must be for
 */

const STRIPE_API = "https://api.stripe.com/v1";
// Unambiguous alphabet: no 0/O/1/I/L.
const KEY_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
const KEY_RE = /^BEACON-[A-Z0-9]{5}-[A-Z0-9]{5}-[A-Z0-9]{5}$/;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

function generateKey() {
  const groups = [];
  const bytes = new Uint8Array(15);
  crypto.getRandomValues(bytes);
  for (let g = 0; g < 3; g++) {
    let group = "";
    for (let i = 0; i < 5; i++) {
      group += KEY_ALPHABET[bytes[g * 5 + i] % KEY_ALPHABET.length];
    }
    groups.push(group);
  }
  return `BEACON-${groups.join("-")}`;
}

/** GET a Stripe resource. `params` become repeated query args (for expand[]). */
async function stripe(env, path, params = []) {
  const qs = params.length ? `?${params.join("&")}` : "";
  const res = await fetch(`${STRIPE_API}${path}${qs}`, {
    headers: {
      Authorization: `Bearer ${env.STRIPE_SECRET_KEY}`,
      Accept: "application/json",
    },
  });
  if (!res.ok) {
    throw new Error(`stripe ${path} -> ${res.status}`);
  }
  return res.json();
}

async function handleClaim(request, env) {
  const { sessionId } = await request.json().catch(() => ({}));
  if (!sessionId || !/^cs_[A-Za-z0-9_]+$/.test(sessionId)) {
    return json({ error: "missing or malformed sessionId" }, 400);
  }

  // Idempotent: a refresh of the thanks page returns the same key.
  const existing = await env.LICENSES.get(`session:${sessionId}`);
  if (existing) {
    return json({ key: existing });
  }

  let session;
  try {
    session = await stripe(env, `/checkout/sessions/${sessionId}`, [
      "expand[]=line_items",
    ]);
  } catch {
    return json({ error: "session not found" }, 404);
  }

  // A completed session for a subscription is legitimate even during a free
  // trial, when nothing has been charged yet (payment_status is then
  // "no_payment_required"). So gate on completion, not on a captured payment.
  const paidStates = ["paid", "no_payment_required"];
  const completed =
    session.status === "complete" || paidStates.includes(session.payment_status);
  if (!completed) {
    return json({ error: `checkout not complete (${session.status})` }, 402);
  }

  const boughtBeacon = (session.line_items?.data || []).some(
    (item) => item.price?.id === env.STRIPE_PRICE_ID
  );
  if (!boughtBeacon) {
    return json({ error: "session is not for Beacon" }, 402);
  }

  const key = generateKey();
  const record = {
    subscriptionId: session.subscription || null,
    customerId: session.customer || null,
    email: session.customer_details?.email || "",
    createdAt: new Date().toISOString(),
  };
  await env.LICENSES.put(`license:${key}`, JSON.stringify(record));
  await env.LICENSES.put(`session:${sessionId}`, key);
  return json({ key });
}

async function subscriptionStatus(env, record) {
  // No subscription id (e.g. a one-off charge): treat as perpetual.
  if (!record.subscriptionId) {
    return { valid: true, expiresAt: null };
  }
  const sub = await stripe(env, `/subscriptions/${record.subscriptionId}`);
  const activeStates = ["active", "trialing", "past_due"];
  const valid = activeStates.includes(sub.status);
  const expiresAt = sub.current_period_end
    ? new Date(sub.current_period_end * 1000).toISOString()
    : null;
  return { valid, expiresAt };
}

async function handleValidate(request, env) {
  const { key } = await request.json().catch(() => ({}));
  // The app trims + uppercases before sending; keys are our BEACON- format.
  const normalized = (key || "").trim().toUpperCase();
  if (!KEY_RE.test(normalized)) {
    return json({ valid: false, error: "malformed key" }, 400);
  }

  // Serve a cached verdict for a day so app launches don't hammer Stripe.
  const cached = await env.LICENSES.get(`status:${normalized}`, "json");
  if (cached) {
    return json(cached);
  }

  const record = await env.LICENSES.get(`license:${normalized}`, "json");
  if (!record) {
    return json({ valid: false, error: "unknown key" });
  }

  let verdict;
  try {
    verdict = await subscriptionStatus(env, record);
  } catch {
    // Stripe briefly unreachable and no cached verdict: fail closed but DON'T
    // cache it. The app keeps its prior state (background revalidation ignores
    // failures) and its offline grace window covers transient outages.
    return json({ valid: false, error: "validator unreachable", degraded: true }, 503);
  }

  await env.LICENSES.put(`status:${normalized}`, JSON.stringify(verdict), {
    expirationTtl: 60 * 60 * 24,
  });
  return json(verdict);
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { headers: CORS_HEADERS });
    }
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/claim") {
      return handleClaim(request, env);
    }
    if (request.method === "POST" && url.pathname === "/validate") {
      return handleValidate(request, env);
    }
    return json({ error: "not found" }, 404);
  },
};
