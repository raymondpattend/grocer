import { Effect } from "effect";
import { Hono } from "hono";
import type { Env } from "../env.js";
import { runHandler } from "../effect/http.js";

export const healthRoute = new Hono<{ Bindings: Env }>();

healthRoute.get("/health", (c) =>
  runHandler(
    c,
    Effect.sync(() =>
      c.json({
        ok: true,
        service: "grocery-api",
        timestamp: new Date().toISOString(),
      }),
    ),
  ),
);
