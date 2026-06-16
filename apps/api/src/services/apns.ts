import type { LiveActivityContent } from "@grocer/shared";
import type { Env } from "../env.js";

/**
 * Minimal APNs client for ActivityKit Live Activity pushes, built on the
 * Workers runtime (WebCrypto + fetch). Token-based (JWT / .p8) auth.
 *
 * Apple lets you START a Live Activity with a push to the device's
 * push-to-start token, and UPDATE/END a running activity with a push to that
 * activity's update token. ActivityKit pushes use the `liveactivity` push type
 * and the `<bundle-id>.push-type.liveactivity` topic.
 *
 * Regular shopping-trip notifications use the same provider token but the
 * standard app bundle topic and the `alert` push type.
 *
 * Docs: "Starting and updating Live Activities with ActivityKit push notifications".
 */

const APNS_HOST: Record<Env["APNS_ENVIRONMENT"], string> = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
};

export type ApnsEvent = "start" | "update" | "end";
export type ShoppingTripNotificationEvent = "started" | "completed" | "cancelled";

export interface ApnsResult {
  ok: boolean;
  statusCode: number;
  apnsId?: string;
  /** Apple error reason, e.g. "BadDeviceToken", "ExpiredToken", "Unregistered". */
  reason?: string;
  /** True when the token should be marked invalid and cleaned up. */
  tokenExpired: boolean;
  detail?: string;
}

// ---------------------------------------------------------------------------
// JWT (ES256) provider token — cached for ~50 min (Apple requires < 60 min).
// ---------------------------------------------------------------------------

let cachedToken: { jwt: string; expiresAt: number } | null = null;

function base64url(input: ArrayBuffer | string): string {
  let bytes: Uint8Array;
  if (typeof input === "string") {
    bytes = new TextEncoder().encode(input);
  } else {
    bytes = new Uint8Array(input);
  }
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const raw = atob(body);
  const buf = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) buf[i] = raw.charCodeAt(i);
  return buf.buffer;
}

async function providerToken(env: Env): Promise<string> {
  const nowSec = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expiresAt > nowSec + 60) {
    return cachedToken.jwt;
  }

  // .dev.vars often stores the key with literal "\n"; normalize to real newlines.
  const pem = env.APNS_PRIVATE_KEY.replace(/\\n/g, "\n");
  const keyData = pemToArrayBuffer(pem);

  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyData,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );

  const header = base64url(
    JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }),
  );
  const payload = base64url(
    JSON.stringify({ iss: env.APNS_TEAM_ID, iat: nowSec }),
  );
  const signingInput = `${header}.${payload}`;

  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );

  const jwt = `${signingInput}.${base64url(signature)}`;
  cachedToken = { jwt, expiresAt: nowSec + 50 * 60 };
  return jwt;
}

// ---------------------------------------------------------------------------
// Payload construction
// ---------------------------------------------------------------------------

/** Map our shared content shape into the ActivityKit `content-state` object. */
function contentState(content: LiveActivityContent) {
  return {
    storeName: content.storeName ?? null,
    shopperName: content.shopperName,
    status: content.status,
    itemsFound: content.itemsFound,
    itemsRemaining: content.itemsRemaining,
    totalItems: content.totalItems,
    outOfStockCount: content.outOfStockCount,
    replacedCount: content.replacedCount,
    lastHandledItemName: content.lastHandledItemName ?? null,
    lastHandledItemStatus: content.lastHandledItemStatus ?? null,
  };
}

interface BuildPayloadArgs {
  event: ApnsEvent;
  content: LiveActivityContent;
  /** Required for a `start` event — must match the Swift ActivityAttributes type name. */
  attributesType?: string;
  /** Static attributes for `start` (householdId/sessionId/startedByMemberId). */
  attributes?: Record<string, unknown>;
  /** "default" | "after" — only used for `end`. */
  dismissalDate?: number;
  alert?: { title: string; body: string };
}

function buildPayload(args: BuildPayloadArgs): Record<string, unknown> {
  const nowSec = Math.floor(Date.now() / 1000);
  const aps: Record<string, unknown> = {
    timestamp: nowSec,
    event: args.event,
    "content-state": contentState(args.content),
  };

  if (args.event === "start") {
    aps["attributes-type"] = args.attributesType;
    aps["attributes"] = args.attributes ?? {};
  }

  if (args.event === "end" && args.dismissalDate !== undefined) {
    aps["dismissal-date"] = args.dismissalDate;
  }

  if (args.alert) {
    aps["alert"] = { title: args.alert.title, body: args.alert.body };
  }

  return { aps };
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

async function sendToHost(
  env: Env,
  host: string,
  jwt: string,
  token: string,
  payload: Record<string, unknown>,
  opts: { priority: 5 | 10; pushType: "alert" | "liveactivity"; topic: string },
): Promise<ApnsResult> {
  const bridgeUrl = env.APNS_HTTP2_BRIDGE_URL?.trim();
  if (bridgeUrl) {
    return sendViaHttp2Bridge(bridgeUrl, host, jwt, token, payload, opts);
  }

  const res = await fetch(`${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": opts.topic,
      "apns-push-type": opts.pushType,
      "apns-priority": String(opts.priority),
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  const apnsId = res.headers.get("apns-id") ?? undefined;

  if (res.status === 200) {
    return { ok: true, statusCode: 200, apnsId, tokenExpired: false };
  }

  let reason: string | undefined;
  let detail: string | undefined;
  try {
    const body = (await res.json()) as { reason?: string };
    reason = body.reason;
    detail = JSON.stringify(body);
  } catch {
    detail = await res.text().catch(() => undefined);
  }

  // Tokens Apple says are dead → caller should clean them up.
  const tokenExpired =
    res.status === 410 ||
    reason === "ExpiredToken" ||
    reason === "BadDeviceToken" ||
    reason === "Unregistered";

  return { ok: false, statusCode: res.status, apnsId, reason, tokenExpired, detail };
}

async function sendViaHttp2Bridge(
  bridgeUrl: string,
  host: string,
  jwt: string,
  token: string,
  payload: Record<string, unknown>,
  opts: { priority: 5 | 10; pushType: "alert" | "liveactivity"; topic: string },
): Promise<ApnsResult> {
  try {
    const res = await fetch(`${bridgeUrl.replace(/\/+$/, "")}/send`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        host,
        token,
        payload,
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": opts.topic,
          "apns-push-type": opts.pushType,
          "apns-priority": String(opts.priority),
          "content-type": "application/json",
        },
      }),
    });

    const body = (await res.json().catch(() => null)) as Partial<ApnsResult> | null;
    if (!res.ok || !body) {
      return {
        ok: false,
        statusCode: res.status,
        tokenExpired: false,
        detail: body?.detail ?? `APNs HTTP/2 bridge returned HTTP ${res.status}`,
      };
    }

    const reason = typeof body.reason === "string" ? body.reason : undefined;
    return {
      ok: body.ok === true,
      statusCode: typeof body.statusCode === "number" ? body.statusCode : 0,
      apnsId: typeof body.apnsId === "string" ? body.apnsId : undefined,
      reason,
      tokenExpired:
        body.tokenExpired === true ||
        body.statusCode === 410 ||
        reason === "ExpiredToken" ||
        reason === "BadDeviceToken" ||
        reason === "Unregistered",
      detail: typeof body.detail === "string" ? body.detail : undefined,
    };
  } catch (err) {
    return {
      ok: false,
      statusCode: 0,
      tokenExpired: false,
      detail: `APNs HTTP/2 bridge request failed: ${String(err)}`,
    };
  }
}

async function postToApns(
  env: Env,
  token: string,
  payload: Record<string, unknown>,
  opts: {
    priority?: 5 | 10;
    pushType?: "alert" | "liveactivity";
    topic?: string;
  } = {},
): Promise<ApnsResult> {
  const jwt = await providerToken(env);
  const resolved = {
    priority: opts.priority ?? (10 as const),
    pushType: opts.pushType ?? ("liveactivity" as const),
    topic: opts.topic ?? `${env.APNS_BUNDLE_ID}.push-type.liveactivity`,
  };

  const primary = env.APNS_ENVIRONMENT;
  const fallback = primary === "production" ? "sandbox" : "production";

  let result = await sendToHost(env, APNS_HOST[primary], jwt, token, payload, resolved);

  // `BadDeviceToken` means the token is well-formed but was minted for the OTHER
  // APNs environment — e.g. a TestFlight/App Store (production) token hitting the
  // sandbox host, or an Xcode-debug (sandbox) token hitting production. Retry the
  // opposite host before giving up so a single backend serves both dev and
  // distribution builds without permanently invalidating good tokens.
  if (!result.ok && result.reason === "BadDeviceToken") {
    result = await sendToHost(env, APNS_HOST[fallback], jwt, token, payload, resolved);
  }

  return result;
}

/** Send a push-to-START to a device's push-to-start token. */
export function sendStart(
  env: Env,
  pushToStartToken: string,
  args: {
    content: LiveActivityContent;
    attributesType: string;
    attributes: Record<string, unknown>;
  },
): Promise<ApnsResult> {
  const payload = buildPayload({
    event: "start",
    content: args.content,
    attributesType: args.attributesType,
    attributes: args.attributes,
    // Apple recommends a start push carry an alert so the system reliably
    // presents/starts the activity even when the app isn't running.
    alert: shoppingTripNotificationCopy({
      event: "started",
      shopperName: args.content.shopperName,
      storeName: args.content.storeName,
    }),
  });
  return postToApns(env, pushToStartToken, payload);
}

/** Send an UPDATE to a running activity's update token. */
export function sendUpdate(
  env: Env,
  updateToken: string,
  content: LiveActivityContent,
): Promise<ApnsResult> {
  const payload = buildPayload({ event: "update", content });
  return postToApns(env, updateToken, payload);
}

/** Send an END to a running activity's update token. */
export function sendEnd(
  env: Env,
  updateToken: string,
  content: LiveActivityContent,
): Promise<ApnsResult> {
  const payload = buildPayload({
    event: "end",
    content,
    // Dismiss shortly after showing the completed/cancelled state.
    dismissalDate: Math.floor(Date.now() / 1000) + 60 * 5,
  });
  return postToApns(env, updateToken, payload, { priority: 10 });
}

function shoppingTripNotificationCopy(args: {
  event: ShoppingTripNotificationEvent;
  shopperName?: string | null;
  storeName?: string | null;
  itemsFound?: number;
  totalItems?: number;
}): { title: string; body: string } {
  const shopper = args.shopperName?.trim() || "Someone";
  const store = args.storeName?.trim() ? ` at ${args.storeName.trim()}` : "";

  if (args.event === "started") {
    return {
      title: "Shopping Started",
      body: `${shopper} started shopping${store}.`,
    };
  }

  if (args.event === "completed") {
    return {
      title: "Shopping Finished",
      body: `${shopper} finished shopping${store}.`,
    };
  }

  return {
    title: "Shopping Cancelled",
    body: `${shopper} ended the shopping trip${store}.`,
  };
}

/** Send a normal APNs alert notification for shopping trip lifecycle events. */
export function sendShoppingTripNotification(
  env: Env,
  deviceToken: string,
  args: {
    event: ShoppingTripNotificationEvent;
    householdId: string;
    sessionId: string;
    shopperName?: string | null;
    storeName?: string | null;
    itemsFound?: number;
    totalItems?: number;
  },
): Promise<ApnsResult> {
  const copy = shoppingTripNotificationCopy(args);
  const payload = {
    aps: {
      alert: copy,
      sound: "default",
      "thread-id": `shopping-trip-${args.householdId}`,
    },
    event: `shopping_trip_${args.event}`,
    householdId: args.householdId,
    sessionId: args.sessionId,
  };

  return postToApns(env, deviceToken, payload, {
    priority: 10,
    pushType: "alert",
    topic: env.APNS_BUNDLE_ID,
  });
}

/**
 * Send a Time Sensitive "heads up, I'm about to shop" alert. Unlike the trip
 * lifecycle notifications this carries `interruption-level: time-sensitive` so
 * it breaks through Focus/scheduled summaries — the recipient's last chance to
 * add to the list before someone heads to the store.
 */
export function sendHeadsUpNotification(
  env: Env,
  deviceToken: string,
  args: {
    householdId: string;
    shopperName?: string | null;
    storeName?: string | null;
  },
): Promise<ApnsResult> {
  const shopper = args.shopperName?.trim() || "Someone";
  const store = args.storeName?.trim() ? ` to ${args.storeName.trim()}` : "";
  const payload = {
    aps: {
      alert: {
        title: "Heads up — shopping soon",
        body: `${shopper} is about to head${store ? store : " out"} shopping. Add anything you need now.`,
      },
      sound: "default",
      "interruption-level": "time-sensitive",
      "thread-id": `heads-up-${args.householdId}`,
    },
    event: "shopping_heads_up",
    householdId: args.householdId,
  };

  return postToApns(env, deviceToken, payload, {
    priority: 10,
    pushType: "alert",
    topic: env.APNS_BUNDLE_ID,
  });
}

/**
 * Send a retention re-engagement nudge — "items were added to your shared list
 * while you were away". A standard (not time-sensitive) alert so it respects
 * Focus/quiet hours; the cron already gates sends to daytime-local. The custom
 * keys let the app log `retention_notification_opened` and deep-link to the
 * household when the user taps it.
 */
export function sendRetentionNotification(
  env: Env,
  deviceToken: string,
  args: {
    householdId: string;
    newItemCount: number;
    actorName?: string | null;
    notifId: string;
  },
): Promise<ApnsResult> {
  const n = args.newItemCount;
  const itemWord = n === 1 ? "item" : "items";
  const actor = args.actorName?.trim();
  const body = actor
    ? `${actor} added ${n} ${itemWord} to your shared list.`
    : `${n} new ${itemWord} were added to your shared list.`;

  const payload = {
    aps: {
      alert: { title: "New on your list", body },
      sound: "default",
      "thread-id": `retention-${args.householdId}`,
    },
    kind: "retention",
    notifId: args.notifId,
    householdId: args.householdId,
    newItemCount: n,
  };

  return postToApns(env, deviceToken, payload, {
    priority: 10,
    pushType: "alert",
    topic: env.APNS_BUNDLE_ID,
  });
}

/** Swift ActivityAttributes type name — must match GroceryActivityAttributes. */
export const ACTIVITY_ATTRIBUTES_TYPE = "GroceryActivityAttributes";
