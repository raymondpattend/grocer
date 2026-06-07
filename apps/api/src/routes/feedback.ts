import { Hono } from "hono";
import { FeedbackRequestSchema } from "@grocer/shared";
import type { Env } from "../env.js";
import { parseBody } from "../lib/validate.js";
import { saveFeedback } from "../db/liveActivityTokens.js";

export const feedbackRoute = new Hono<{ Bindings: Env }>();

feedbackRoute.post("/feedback", async (c) => {
  const parsed = await parseBody(c, FeedbackRequestSchema);
  if ("error" in parsed) return parsed.error;

  await saveFeedback(c.env.DB, parsed.data);
  return c.json({ ok: true });
});
