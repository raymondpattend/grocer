import type { Context } from "hono";
import type { ZodSchema } from "zod";

/**
 * Parse + validate a JSON body against a Zod schema. Throws a Response with a
 * useful 400 payload on failure (caught by Hono's onError or returned directly).
 */
export async function parseBody<T>(
  c: Context,
  schema: ZodSchema<T>,
): Promise<{ data: T } | { error: Response }> {
  let json: unknown;
  try {
    json = await c.req.json();
  } catch {
    return {
      error: c.json({ ok: false, error: "Invalid JSON body" }, 400),
    };
  }

  const result = schema.safeParse(json);
  if (!result.success) {
    return {
      error: c.json(
        {
          ok: false,
          error: "Validation failed",
          issues: result.error.issues.map((i) => ({
            path: i.path.join("."),
            message: i.message,
          })),
        },
        400,
      ),
    };
  }
  return { data: result.data };
}
