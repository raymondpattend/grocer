import { Hono } from "hono";
import { SuggestionRequestSchema } from "@grocer/shared";
import type { Env } from "../env.js";
import { parseBody } from "../lib/validate.js";
import { suggestItems } from "../services/categorize.js";

export const suggestionsRoute = new Hono<{ Bindings: Env }>();

suggestionsRoute.post("/suggestions/items", async (c) => {
  const parsed = await parseBody(c, SuggestionRequestSchema);
  if ("error" in parsed) return parsed.error;

  const suggestions = suggestItems(
    parsed.data.query,
    parsed.data.recentItems ?? [],
  );
  return c.json({ suggestions });
});
