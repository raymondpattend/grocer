import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { sentry } from "@sentry/hono/cloudflare";
import type { Env } from "./env.js";
import { healthRoute } from "./routes/health.js";
import { configRoute } from "./routes/config.js";
import { feedbackRoute } from "./routes/feedback.js";
import { suggestionsRoute } from "./routes/suggestions.js";
import { parseListRoute } from "./routes/parseList.js";
import { liveActivityRoute } from "./routes/liveActivity.js";
import { productImageRoute } from "./routes/productImage.js";

const app = new Hono<{ Bindings: Env }>();

app.use(
  sentry(app, {
    dsn: "https://144fe19ecb50a13bdf65e6233b07958e@o4510745096749056.ingest.us.sentry.io/4511527563821057",
    sendDefaultPii: true,
  }),
);
app.use("*", logger());
app.use("*", cors());

app.get("/debug-sentry", () => {
  throw new Error("My first Sentry error!");
});

app.route("/", healthRoute);
app.route("/", configRoute);
app.route("/", feedbackRoute);
app.route("/", suggestionsRoute);
app.route("/", parseListRoute);
app.route("/", liveActivityRoute);
app.route("/", productImageRoute);

app.notFound((c) => c.json({ ok: false, error: "Not found" }, 404));

app.onError((err, c) => {
  console.error("Unhandled error:", err);
  return c.json({ ok: false, error: "Internal error" }, 500);
});

export default app;
