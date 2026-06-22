import type { Context } from "hono";
import { PostHog } from "posthog-node";
import type { Env } from "../env.js";

/**
 * Header carrying the caller's PostHog distinct id — the same identity the iOS
 * client passes to `PostHogSDK.identify` (`memberIdOrDevice`). Sent on every API
 * request so server-side events (notably AI usage) attach to the same person
 * profile the client maintains, rather than an "anonymous" bucket.
 */
export const DISTINCT_ID_HEADER = "x-grocer-distinct-id";

export function createPostHogClient(env: Env): PostHog {
  return new PostHog(env.POSTHOG_API_KEY, {
    host: env.POSTHOG_HOST,
    flushAt: 1,
    flushInterval: 0,
    enableExceptionAutocapture: true,
  });
}

/** The caller's PostHog distinct id from the request, or undefined when absent. */
export function callerDistinctId(c: Context<{ Bindings: Env }>): string | undefined {
  const id = c.req.header(DISTINCT_ID_HEADER)?.trim();
  return id ? id : undefined;
}
