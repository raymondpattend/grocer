import { Hono } from "hono";
import type { Env } from "../env.js";

export const healthRoute = new Hono<{ Bindings: Env }>();

healthRoute.get("/health", (c) =>
  c.json({
    ok: true,
    service: "grocery-api",
    timestamp: new Date().toISOString(),
  }),
);
