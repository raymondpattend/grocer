import { Hono } from "hono";
import { captureException } from "@sentry/cloudflare";
import { ParseListRequestSchema, type ParsedItem } from "@grocer/shared";
import type { Env } from "../env.js";
import { parseBody } from "../lib/validate.js";
import { parseListWithAI } from "../services/aiParseList.js";
import { parseList } from "../services/categorize.js";
import { prewarmProductImages } from "./productImage.js";
import { callerDistinctId, createPostHogClient } from "../lib/posthog.js";
import { aiRateLimit } from "../lib/aiRateLimit.js";

export const parseListRoute = new Hono<{ Bindings: Env }>();

parseListRoute.use("/parse-list", aiRateLimit());

parseListRoute.post("/parse-list", async (c) => {
  const parsed = await parseBody(c, ParseListRequestSchema);
  if ("error" in parsed) return parsed.error;

  const distinctId = callerDistinctId(c);
  let aiItems: ParsedItem[] | null = null;
  try {
    aiItems = await parseListWithAI(c.env, parsed.data.text, {
      executionCtx: c.executionCtx,
      distinctId,
    });
  } catch (err) {
    console.error("AI list parsing failed; using deterministic fallback:", err);
    captureException(err);
  }
  const usedAI = !!(aiItems?.length);
  const items = usedAI ? aiItems! : parseList(parsed.data.text);
  c.executionCtx.waitUntil(
    prewarmProductImages(c.env, items.map((item) => item.name), 8, c.executionCtx),
  );

  const posthog = createPostHogClient(c.env);
  posthog.capture({
    distinctId: distinctId ?? "anonymous",
    event: "list parsed",
    properties: {
      item_count: items.length,
      method: usedAI ? "ai" : "fallback",
      input_length: parsed.data.text.length,
      $process_person_profile: distinctId !== undefined,
    },
  });
  c.executionCtx.waitUntil(posthog.shutdown());

  return c.json({ items });
});
