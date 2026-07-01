import { Effect } from "effect";
import type { Context } from "hono";
import type { Env } from "../env.js";
import { ResponseError } from "../effect/errors.js";

/**
 * HMAC request signing shared by the app-signed endpoints (Live Activity and
 * retention). The iOS client signs `${timestamp}.${method}.${pathname}.${body}`
 * with `LIVE_ACTIVITY_API_SECRET` and sends the headers below. Also houses the
 * tiny D1-backed rate limiter so both route groups share one implementation.
 *
 * Both public checks are Effects that succeed (request passes) or fail with a
 * {@link ResponseError} the Hono↔Effect bridge renders — so a route guard is
 * just `yield* authenticateSignedRequest(c); yield* enforceRateLimit(c, …)`.
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

/** Verifies the HMAC signature on an app-signed request. Fails with a
 *  {@link ResponseError} (503/401) when invalid; succeeds when authentic. */
export function authenticateSignedRequest(
  c: Context<{ Bindings: Env }>,
): Effect.Effect<void, ResponseError> {
  return Effect.gen(function* () {
    const secret = c.env.LIVE_ACTIVITY_API_SECRET?.trim();
    if (!secret) {
      console.error("[signing] LIVE_ACTIVITY_API_SECRET is not configured");
      return yield* new ResponseError({
        status: 503,
        body: { ok: false, error: "Request auth is not configured" },
      });
    }

    const timestamp = c.req.header(TIMESTAMP_HEADER);
    const signature = c.req.header(SIGNATURE_HEADER);
    if (!timestamp || !signature) {
      return yield* new ResponseError({
        status: 401,
        body: { ok: false, error: "Missing request signature" },
      });
    }

    const timestampSeconds = Number(timestamp);
    const nowSeconds = Math.floor(Date.now() / 1000);
    if (
      !Number.isFinite(timestampSeconds) ||
      Math.abs(nowSeconds - timestampSeconds) > MAX_CLOCK_SKEW_SECONDS
    ) {
      return yield* new ResponseError({
        status: 401,
        body: { ok: false, error: "Stale request signature" },
      });
    }

    const url = new URL(c.req.url);
    const method = c.req.method.toUpperCase();
    const body = method === "GET" ? "" : yield* Effect.promise(() => c.req.raw.clone().text());
    const expected = yield* Effect.promise(() =>
      hmacHex(secret, `${timestamp}.${method}.${url.pathname}.${body}`),
    );
    if (!constantTimeEqualHex(signature, expected)) {
      return yield* new ResponseError({
        status: 401,
        body: { ok: false, error: "Invalid request signature" },
      });
    }
  });
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

/** Per-device token-bucket rate limit, keyed by `${scope}:${deviceId}`. Fails
 *  with a 429 {@link ResponseError} once the bucket is exhausted. */
export function enforceRateLimit(
  c: Context<{ Bindings: Env }>,
  scope: string,
  limit: number,
  windowSeconds: number,
): Effect.Effect<void, ResponseError> {
  return Effect.gen(function* () {
    const deviceId =
      c.req.header(DEVICE_HEADER) ?? c.req.header("CF-Connecting-IP") ?? "unknown";
    const key = `${scope}:${deviceId}`;
    const ok = yield* Effect.promise(() =>
      consumeRateLimit(c.env.DB, key, limit, windowSeconds),
    );
    if (!ok) {
      return yield* new ResponseError({
        status: 429,
        body: { ok: false, error: "Rate limit exceeded" },
      });
    }
  });
}
