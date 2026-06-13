import { PostHog } from "posthog-node";
import type { Env } from "../env.js";

export function createPostHogClient(env: Env): PostHog {
  return new PostHog(env.POSTHOG_API_KEY, {
    host: env.POSTHOG_HOST,
    flushAt: 1,
    flushInterval: 0,
    enableExceptionAutocapture: true,
  });
}
