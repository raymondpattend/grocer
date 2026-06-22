import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { sentry } from "@sentry/hono/cloudflare";
import type { Env } from "./env.js";
import {
  capturePostHogException,
  capturePostHogLog,
  posthogApiObservability,
} from "./lib/posthogObservability.js";
import { healthRoute } from "./routes/health.js";
import { configRoute } from "./routes/config.js";
import { feedbackRoute } from "./routes/feedback.js";
import { suggestionsRoute } from "./routes/suggestions.js";
import { parseListRoute } from "./routes/parseList.js";
import { identifyItemRoute } from "./routes/identifyItem.js";
import { liveActivityRoute } from "./routes/liveActivity.js";
import { retentionRoute } from "./routes/retention.js";
import { productImageRoute } from "./routes/productImage.js";
import { billingRoute } from "./routes/billing.js";
import { runRetentionSweep } from "./cron/retention.js";

const app = new Hono<{ Bindings: Env }>();

app.use(
  sentry(app, {
    dsn: "https://144fe19ecb50a13bdf65e6233b07958e@o4510745096749056.ingest.us.sentry.io/4511527563821057",
    sendDefaultPii: true,
  }),
);
app.use("*", logger());
app.use("*", posthogApiObservability());
app.use("*", cors());

app.get("/debug-sentry", () => {
  throw new Error("My first Sentry error!");
});

app.route("/", healthRoute);
app.route("/", configRoute);
app.route("/", feedbackRoute);
app.route("/", suggestionsRoute);
app.route("/", parseListRoute);
app.route("/", identifyItemRoute);
app.route("/", liveActivityRoute);
app.route("/", retentionRoute);
app.route("/", productImageRoute);
app.route("/", billingRoute);

app.notFound((c) => c.json({ ok: false, error: "Not found" }, 404));

app.onError((err, c) => {
  console.error("Unhandled error:", err);
  capturePostHogException(c, err, {
    source: "hono_on_error",
  });
  capturePostHogLog(c.env, c.executionCtx, {
    level: "error",
    body: err instanceof Error ? err.message : String(err),
    attributes: {
      source: "hono_on_error",
      path: new URL(c.req.url).pathname,
      method: c.req.method,
    },
  });
  return c.json({ ok: false, error: "Internal error" }, 500);
});

export default {
  fetch: app.fetch,
  /** Cloudflare Cron Trigger — hourly retention-nudge sweep (see wrangler.toml). */
  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(
      runRetentionSweep(env)
        .then((r) =>
          console.log(
            `[retention] sweep complete: candidates=${r.candidates} ` +
              `sent=${r.sent} failed=${r.failed} skipped=${r.skipped}`,
          ),
        )
        .catch((err) => console.error("[retention] sweep failed:", err)),
    );
  },
};
