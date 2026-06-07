import { Hono } from "hono";
import { ParseListRequestSchema } from "@grocer/shared";
import type { Env } from "../env.js";
import { parseBody } from "../lib/validate.js";
import { parseList } from "../services/categorize.js";

export const parseListRoute = new Hono<{ Bindings: Env }>();

parseListRoute.post("/parse-list", async (c) => {
  const parsed = await parseBody(c, ParseListRequestSchema);
  if ("error" in parsed) return parsed.error;

  const items = parseList(parsed.data.text);
  return c.json({ items });
});
