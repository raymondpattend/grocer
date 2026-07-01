import { Data } from "effect";

/**
 * The typed failure channel for the API's Effect pipelines.
 *
 * Every failure a request handler can *anticipate* is one of these tagged
 * errors, so the Hono↔Effect bridge (see `http.ts`) can map it to a stable HTTP
 * response without a stack of `try/catch`. Anything that escapes as a defect
 * (an unexpected throw) is left to bubble to Hono's `onError`, preserving the
 * existing "log + Sentry/PostHog + 500" behaviour.
 */

/** The request body was not valid JSON. Renders the same 400 as before. */
export class JsonBodyError extends Data.TaggedError("JsonBodyError")<{
  readonly cause?: unknown;
}> {}

/** A Zod schema rejected the (otherwise valid JSON) request body. */
export class ValidationError extends Data.TaggedError("ValidationError")<{
  readonly issues: ReadonlyArray<{ path: string; message: string }>;
}> {}

/**
 * A handler wants to short-circuit with a specific HTTP response it chose
 * itself (a 400 for a missing query param, a 401 for a bad signature, a 429 for
 * rate limiting, a billing error page, …). Carrying the status/body through the
 * typed channel keeps the "validate, then act" flow linear instead of threading
 * `{ error: Response }` unions by hand.
 */
export class ResponseError extends Data.TaggedError("ResponseError")<{
  readonly status: number;
  readonly body: unknown;
  readonly headers?: Record<string, string>;
  /** When true the body is sent as `text/html` rather than JSON. */
  readonly html?: boolean;
}> {}

/**
 * An OpenAI call failed (non-2xx, network error, or an SDK throw). Services that
 * degrade gracefully (`parseList`, `identify-item`, the grocery gate) catch this
 * and fall back; the product-image cold path surfaces it as a 502.
 */
export class OpenAiError extends Data.TaggedError("OpenAiError")<{
  readonly message: string;
  readonly status?: number;
  readonly cause?: unknown;
}> {}
