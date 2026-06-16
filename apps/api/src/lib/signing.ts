import type { Context } from "hono";
import type { Env } from "../env.js";

/**
 * HMAC request signing shared by the app-signed endpoints (Live Activity and
 * retention). The iOS client signs `${timestamp}.${method}.${pathname}.${body}`
 * with `LIVE_ACTIVITY_API_SECRET` and sends the headers below. Also houses the
 * tiny D1-backed rate limiter so both route groups share one implementation.
 */

export const SIGNATURE_HEADER = "x-grocer-signature";
export const TIMESTAMP_HEADER = "x-grocer-timestamp";
export const DEVICE_HEADER = "x-grocer-device-id";
const MAX_CLOCK_SKEW_SECONDS = 5 * 60;

const encoder = new TextEncoder();

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return [...new Uint8Array(signature)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function constantTimeEqualHex(a: string, b: string): boolean {
  if (!/^[0-9a-f]+$/i.test(a) || !/^[0-9a-f]+$/i.test(b)) return false;
  const left = a.toLowerCase();
  const right = b.toLowerCase();
  let diff = left.length ^ right.length;
  const maxLength = Math.max(left.length, right.length);
  for (let i = 0; i < maxLength; i++) {
    diff |= (left.charCodeAt(i) || 0) ^ (right.charCodeAt(i) || 0);
  }
  return diff === 0;
}

/** Verifies the HMAC signature on an app-signed request. Returns an error
 *  Response when invalid, or null when the request is authentic. */
export async function authenticateSignedRequest(
  c: Context<{ Bindings: Env }>,
): Promise<Response | null> {
  const secret = c.env.LIVE_ACTIVITY_API_SECRET?.trim();
  if (!secret) {
    console.error("[signing] LIVE_ACTIVITY_API_SECRET is not configured");
    return c.json({ ok: false, error: "Request auth is not configured" }, 503);
  }

  const timestamp = c.req.header(TIMESTAMP_HEADER);
  const signature = c.req.header(SIGNATURE_HEADER);
  if (!timestamp || !signature) {
    return c.json({ ok: false, error: "Missing request signature" }, 401);
  }

  const timestampSeconds = Number(timestamp);
  const nowSeconds = Math.floor(Date.now() / 1000);
  if (!Number.isFinite(timestampSeconds)
      || Math.abs(nowSeconds - timestampSeconds) > MAX_CLOCK_SKEW_SECONDS) {
    return c.json({ ok: false, error: "Stale request signature" }, 401);
  }

  const url = new URL(c.req.url);
  const method = c.req.method.toUpperCase();
  const body = method === "GET" ? "" : await c.req.raw.clone().text();
  const expected = await hmacHex(secret, `${timestamp}.${method}.${url.pathname}.${body}`);
  if (!constantTimeEqualHex(signature, expected)) {
    return c.json({ ok: false, error: "Invalid request signature" }, 401);
  }
  return null;
}

async function consumeRateLimit(
  db: D1Database,
  key: string,
  limit: number,
  windowSeconds: number,
): Promise<boolean> {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const windowStart = Math.floor(nowSeconds / windowSeconds) * windowSeconds;
  const ts = new Date().toISOString();
  const row = await db
    .prepare("SELECT window_start, count FROM live_activity_rate_limits WHERE key = ?1")
    .bind(key)
    .first<{ window_start: number; count: number }>();

  if (!row || row.window_start !== windowStart) {
    await db
      .prepare(
        `INSERT INTO live_activity_rate_limits (key, window_start, count, updated_at)
         VALUES (?1, ?2, 1, ?3)
         ON CONFLICT(key) DO UPDATE SET window_start = ?2, count = 1, updated_at = ?3`,
      )
      .bind(key, windowStart, ts)
      .run();
    return true;
  }

  if (row.count >= limit) return false;
  await db
    .prepare("UPDATE live_activity_rate_limits SET count = count + 1, updated_at = ?2 WHERE key = ?1")
    .bind(key, ts)
    .run();
  return true;
}

/** Per-device token-bucket rate limit, keyed by `${scope}:${deviceId}`. */
export async function enforceRateLimit(
  c: Context<{ Bindings: Env }>,
  scope: string,
  limit: number,
  windowSeconds: number,
): Promise<Response | null> {
  const deviceId = c.req.header(DEVICE_HEADER)
    ?? c.req.header("CF-Connecting-IP")
    ?? "unknown";
  const key = `${scope}:${deviceId}`;
  const ok = await consumeRateLimit(c.env.DB, key, limit, windowSeconds);
  if (!ok) {
    return c.json({ ok: false, error: "Rate limit exceeded" }, 429);
  }
  return null;
}
