import { Effect } from "effect";
import { Hono } from "hono";
import { SuggestionRequestSchema } from "@grocer/shared";
import type { Env } from "../env.js";
import { decodeJsonBody } from "../effect/body.js";
import { runHandler } from "../effect/http.js";
import { suggestItems } from "../services/categorize.js";

export const suggestionsRoute = new Hono<{ Bindings: Env }>();

suggestionsRoute.post("/suggestions/items", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const data = yield* decodeJsonBody(c, SuggestionRequestSchema);
      const suggestions = suggestItems(data.query, data.recentItems ?? []);
      return c.json({ suggestions });
    }),
  ),
);
