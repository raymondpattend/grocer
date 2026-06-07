import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import type { Env } from "./env.js";
import { healthRoute } from "./routes/health.js";
import { configRoute } from "./routes/config.js";
import { feedbackRoute } from "./routes/feedback.js";
import { suggestionsRoute } from "./routes/suggestions.js";
import { parseListRoute } from "./routes/parseList.js";
import { liveActivityRoute } from "./routes/liveActivity.js";

const app = new Hono<{ Bindings: Env }>();

app.use("*", logger());
app.use("*", cors());

app.route("/", healthRoute);
app.route("/", configRoute);
app.route("/", feedbackRoute);
app.route("/", suggestionsRoute);
app.route("/", parseListRoute);
app.route("/", liveActivityRoute);

app.notFound((c) => c.json({ ok: false, error: "Not found" }, 404));

app.onError((err, c) => {
  console.error("Unhandled error:", err);
  return c.json({ ok: false, error: "Internal error" }, 500);
});

export default app;
