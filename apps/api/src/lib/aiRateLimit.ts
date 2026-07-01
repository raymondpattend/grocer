import { Effect } from "effect";
import { createMiddleware } from "hono/factory";
import type { Context } from "hono";
import type { Env } from "../env.js";
import { ResponseError } from "../effect/errors.js";
import { runGuard } from "../effect/http.js";

/** Options controlling how an AI route is rate limited. */
export interface AiRateLimitOptions {
  /**
   * Bucket namespace so each route family gets an independent per-IP budget
   * (e.g. heavy product-image traffic can't exhaust a caller's parse budget).
   */
  scope: string;
  /**
   * Set for routes that can trigger paid OpenAI image generation
   * (`/product-image` and its prewarm). They get an extra, tighter per-IP
   * ceiling so a caller feeding novel item names — which miss every cache and
   * force a fresh paid generation — can't drive unbounded spend.
   */
  costly?: boolean;
}

/**
 * The rate-limit decision as an Effect: succeeds (request passes) or fails with
 * a 429 {@link ResponseError}. Every applicable dimension must pass. The per-IP
 * checks are the hard ceiling — keyed on the trustworthy `CF-Connecting-IP` — so
 * the caller-supplied `x-grocer-distinct-id` can only ever *narrow* the budget.
 */
function rateLimitGuard(
  c: Context<{ Bindings: Env }>,
  options: AiRateLimitOptions,
): Effect.Effect<void, ResponseError> {
  return Effect.gen(function* () {
    const ip = c.req.header("cf-connecting-ip")?.trim() || "unknown";
    const distinctId = c.req.header("x-grocer-distinct-id")?.trim();

    const checks = [
      c.env.AI_RL_PER_10S.limit({ key: `${options.scope}:ip:${ip}` }),
      c.env.AI_RL_PER_MIN.limit({ key: `${options.scope}:ip:${ip}` }),
    ];
    if (distinctId) {
      checks.push(
        c.env.AI_RL_ID_PER_MIN.limit({ key: `${options.scope}:id:${distinctId}` }),
      );
    }
    if (options.costly) {
      checks.push(c.env.AI_RL_IMAGE_PER_MIN.limit({ key: `ip:${ip}` }));
    }

    const results = yield* Effect.promise(() => Promise.all(checks));
    if (results.some((result) => !result.success)) {
      return yield* new ResponseError({
        status: 429,
        body: { ok: false, error: "rate_limited" },
        headers: { "Retry-After": "60" },
      });
    }
  });
}

/**
 * Rate-limits the AI (OpenAI-billed) routes. A Hono middleware wrapper around
 * {@link rateLimitGuard}: the guard's 429 short-circuits the request, otherwise
 * `next()` runs.
 */
export function aiRateLimit(options: AiRateLimitOptions) {
  return createMiddleware<{ Bindings: Env }>(async (c, next) => {
    const response = await runGuard(c, rateLimitGuard(c, options));
    if (response) return response;
    await next();
  });
}
