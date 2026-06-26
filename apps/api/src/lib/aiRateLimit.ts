import { createMiddleware } from "hono/factory";
import type { Env } from "../env.js";

/**
 * Rate-limits AI routes to 10 RPS and 100 per minute per caller identity.
 * Key: x-grocer-distinct-id header (member/device UUID), falling back to the
 * Cloudflare-provided connecting IP so anonymous callers are still bounded.
 */
export function aiRateLimit() {
  return createMiddleware<{ Bindings: Env }>(async (c, next) => {
    const key =
      c.req.header("x-grocer-distinct-id") ??
      c.req.header("cf-connecting-ip") ??
      "anonymous";

    const [perWindow, perMinute] = await Promise.all([
      c.env.AI_RL_PER_10S.limit({ key }),
      c.env.AI_RL_PER_MIN.limit({ key }),
    ]);

    if (!perWindow.success || !perMinute.success) {
      return c.json({ ok: false, error: "rate_limited" }, 429, {
        "Retry-After": "60",
      });
    }

    await next();
  });
}
