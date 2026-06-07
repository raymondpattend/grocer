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
  /** Static attributes for `start` (householdId/sessionId). */
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
  const url = `${APNS_HOST[env.APNS_ENVIRONMENT]}/3/device/${token}`;
  const pushType = opts.pushType ?? "liveactivity";
  const topic = opts.topic ?? `${env.APNS_BUNDLE_ID}.push-type.liveactivity`;

  const res = await fetch(url, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": topic,
      "apns-push-type": pushType,
      "apns-priority": String(opts.priority ?? 10),
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

  const progress =
    args.itemsFound !== undefined && args.totalItems !== undefined
      ? ` ${args.itemsFound}/${args.totalItems} items handled.`
      : "";

  if (args.event === "completed") {
    return {
      title: "Shopping Finished",
      body: `${shopper} finished shopping${store}.${progress}`,
    };
  }

  return {
    title: "Shopping Cancelled",
    body: `${shopper} ended the shopping trip${store}.${progress}`,
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

/** Swift ActivityAttributes type name — must match GroceryActivityAttributes. */
export const ACTIVITY_ATTRIBUTES_TYPE = "GroceryActivityAttributes";
