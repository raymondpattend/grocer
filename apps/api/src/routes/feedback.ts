import { Effect } from "effect";
import { Hono } from "hono";
import { FeedbackRequestSchema } from "@grocer/shared";
import type { Env } from "../env.js";
import { decodeJsonBody } from "../effect/body.js";
import { runHandler } from "../effect/http.js";
import { fromPromise } from "../effect/interop.js";
import { Telemetry } from "../effect/services.js";
import { saveFeedback } from "../db/liveActivityTokens.js";

export const feedbackRoute = new Hono<{ Bindings: Env }>();

feedbackRoute.post("/feedback", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const data = yield* decodeJsonBody(c, FeedbackRequestSchema);

      // A DB failure throws through to `onError` (500), as before.
      yield* fromPromise(() => saveFeedback(c.env.DB, data));

      const telemetry = yield* Telemetry;
      yield* telemetry.capture({
        distinctId: data.email ?? "anonymous",
        event: "feedback submitted",
        properties: {
          has_email: !!data.email,
          app_version: data.appVersion,
          device: data.device,
        },
      });

      return c.json({ ok: true });
    }),
  ),
);
