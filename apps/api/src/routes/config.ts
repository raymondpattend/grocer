import { Hono } from "hono";
import type { Env } from "../env.js";

export const configRoute = new Hono<{ Bindings: Env }>();

configRoute.get("/config/ios", (c) =>
  c.json({
    minimumSupportedBuild: Number(c.env.IOS_MIN_BUILD ?? "1"),
    latestBuild: Number(c.env.IOS_LATEST_BUILD ?? "1"),
    features: {
      suggestions: true,
      parseList: true,
      feedback: true,
      liveActivities: true,
    },
  }),
);
