import { Hono } from "hono";
import { IdentifyItemRequestSchema } from "@grocer/shared";
import type { Env } from "../env.js";
import { parseBody } from "../lib/validate.js";
import { identifyItemWithAI } from "../services/aiIdentifyItem.js";
import { prewarmProductImages } from "./productImage.js";
import { callerDistinctId, createPostHogClient } from "../lib/posthog.js";

export const identifyItemRoute = new Hono<{ Bindings: Env }>();

identifyItemRoute.post("/identify-item", async (c) => {
  const parsed = await parseBody(c, IdentifyItemRequestSchema);
  if ("error" in parsed) return parsed.error;

  const distinctId = callerDistinctId(c);
  const { item, items } = await identifyItemWithAI(
    c.env,
    parsed.data.image,
    parsed.data.mimeType ?? "image/jpeg",
    { executionCtx: c.executionCtx, distinctId },
  );

  // Warm the AI product image(s) too, so items look right even before any user
  // photo finishes syncing through CloudKit on other devices.
  const namesToWarm = item ? [item.name] : items.map((i) => i.name);
  if (namesToWarm.length > 0) {
    c.executionCtx.waitUntil(
      prewarmProductImages(c.env, namesToWarm, 8, c.executionCtx),
    );
  }

  const posthog = createPostHogClient(c.env);
  posthog.capture({
    distinctId: distinctId ?? "anonymous",
    event: "item identified",
    properties: {
      matched: item !== null || items.length > 0,
      kind: items.length > 0 ? "list" : item ? "item" : "none",
      category: item?.category,
      confidence: item?.confidence,
      list_count: items.length,
      $process_person_profile: distinctId !== undefined,
    },
  });
  c.executionCtx.waitUntil(posthog.shutdown());

  return c.json({ item, items });
});
