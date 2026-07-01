import { Effect } from "effect";
import type { Context } from "hono";
import type { ZodSchema } from "zod";
import { JsonBodyError, ValidationError } from "./errors.js";

/**
 * Reads and validates a JSON request body against a Zod schema, in the typed
 * error channel. Fails with {@link JsonBodyError} when the body isn't JSON and
 * {@link ValidationError} (carrying per-field issues) when the schema rejects
 * it — the bridge renders both as the same 400 payloads the old `parseBody`
 * returned.
 */
export function decodeJsonBody<T>(
  c: Context,
  schema: ZodSchema<T>,
): Effect.Effect<T, JsonBodyError | ValidationError> {
  return Effect.gen(function* () {
    const json = yield* Effect.tryPromise({
      try: () => c.req.json(),
      catch: (cause) => new JsonBodyError({ cause }),
    });

    const result = schema.safeParse(json);
    if (!result.success) {
      return yield* new ValidationError({
        issues: result.error.issues.map((issue) => ({
          path: issue.path.join("."),
          message: issue.message,
        })),
      });
    }
    return result.data;
  });
}
