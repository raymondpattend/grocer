import { Effect } from "effect";
import { Hono } from "hono";
import { ParseListRequestSchema } from "@grocer/shared";
import type { Env } from "../env.js";
import { decodeJsonBody } from "../effect/body.js";
import { runHandler } from "../effect/http.js";
import { Exec, Telemetry } from "../effect/services.js";
import { parseListWithAI } from "../services/aiParseList.js";
import { parseList } from "../services/categorize.js";
import { prewarmProductImages } from "./productImage.js";
import { callerDistinctId } from "../lib/posthog.js";
import { aiRateLimit } from "../lib/aiRateLimit.js";

export const parseListRoute = new Hono<{ Bindings: Env }>();

parseListRoute.use("/parse-list", aiRateLimit({ scope: "parse" }));

parseListRoute.post("/parse-list", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const data = yield* decodeJsonBody(c, ParseListRequestSchema);
      const distinctId = callerDistinctId(c);

      // `parseListWithAI` fails open (never throws), degrading to the
      // deterministic parser when OpenAI is unavailable or returns garbage.
      const aiItems = yield* parseListWithAI(data.text, { distinctId });
      const usedAI = !!aiItems?.length;
      const items = usedAI ? aiItems! : parseList(data.text);

      const exec = yield* Exec;
      exec.waitUntil(
        prewarmProductImages(
          c.env,
          items.map((item) => item.name),
          8,
          exec.executionCtx,
        ),
      );

      const telemetry = yield* Telemetry;
      yield* telemetry.capture({
        distinctId: distinctId ?? "anonymous",
        event: "list parsed",
        properties: {
          item_count: items.length,
          method: usedAI ? "ai" : "fallback",
          input_length: data.text.length,
          $process_person_profile: distinctId !== undefined,
        },
      });

      return c.json({ items });
    }),
  ),
);
