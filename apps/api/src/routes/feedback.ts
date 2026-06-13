import { Hono } from "hono";
import { FeedbackRequestSchema } from "@grocer/shared";
import type { Env } from "../env.js";
import { parseBody } from "../lib/validate.js";
import { saveFeedback } from "../db/liveActivityTokens.js";
import { createPostHogClient } from "../lib/posthog.js";

export const feedbackRoute = new Hono<{ Bindings: Env }>();

feedbackRoute.post("/feedback", async (c) => {
  const parsed = await parseBody(c, FeedbackRequestSchema);
  if ("error" in parsed) return parsed.error;

  await saveFeedback(c.env.DB, parsed.data);

  const posthog = createPostHogClient(c.env);
  posthog.capture({
    distinctId: parsed.data.email ?? "anonymous",
    event: "feedback submitted",
    properties: {
      has_email: !!parsed.data.email,
      app_version: parsed.data.appVersion,
      device: parsed.data.device,
    },
  });
  c.executionCtx.waitUntil(posthog.shutdown());

  return c.json({ ok: true });
});
