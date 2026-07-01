import { Effect } from "effect";
import { Hono } from "hono";
import { IdentifyItemRequestSchema } from "@grocer/shared";
import type { Env } from "../env.js";
import { decodeJsonBody } from "../effect/body.js";
import { runHandler } from "../effect/http.js";
import { Exec, Telemetry } from "../effect/services.js";
import { identifyItemWithAI } from "../services/aiIdentifyItem.js";
import { prewarmProductImages } from "./productImage.js";
import { callerDistinctId } from "../lib/posthog.js";
import { aiRateLimit } from "../lib/aiRateLimit.js";

export const identifyItemRoute = new Hono<{ Bindings: Env }>();

identifyItemRoute.use("/identify-item", aiRateLimit({ scope: "identify" }));

identifyItemRoute.post("/identify-item", (c) =>
  runHandler(
    c,
    Effect.gen(function* () {
      const data = yield* decodeJsonBody(c, IdentifyItemRequestSchema);
      const distinctId = callerDistinctId(c);

      const { item, items } = yield* identifyItemWithAI(
        data.image,
        data.mimeType ?? "image/jpeg",
        { distinctId },
      );

      // Warm the AI product image(s) too, so items look right even before any
      // user photo finishes syncing through CloudKit on other devices.
      const namesToWarm = item ? [item.name] : items.map((i) => i.name);
      const exec = yield* Exec;
      if (namesToWarm.length > 0) {
        exec.waitUntil(
          prewarmProductImages(c.env, namesToWarm, 8, exec.executionCtx),
        );
      }

      const telemetry = yield* Telemetry;
      yield* telemetry.capture({
        distinctId: distinctId ?? "anonymous",
        event: "item identified",
        properties: {
          matched: item !== null || items.length > 0,
          kind: items.length > 0 ? "list" : item ? "item" : "none",
          category: item?.category,
          confidence: item?.confidence,
          list_count: items.length,
          $process_person_profile: distinctId !== undefined,
        },
      });

      return c.json({ item, items });
    }),
  ),
);
