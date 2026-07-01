import { Effect } from "effect";
import type { Context as HonoContext } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import type { Env } from "../env.js";
import { JsonBodyError, ResponseError, ValidationError } from "./errors.js";
import {
  AppConfig,
  Exec,
  OpenAi,
  Telemetry,
  makeAppLayer,
} from "./services.js";

type HC = HonoContext<{ Bindings: Env }>;

/** Every service a route or guard Effect may require. */
export type AppServices = AppConfig | Exec | OpenAi | Telemetry;

/** `c.executionCtx` throws when absent (e.g. in unit tests); treat that as "no
 *  context" so `waitUntil` degrades to a detached best-effort flush. */
function safeExecutionCtx(c: HC): ExecutionContext | undefined {
  try {
    return c.executionCtx;
  } catch {
    return undefined;
  }
}

/**
 * Maps an anticipated (tagged) failure to the exact HTTP response the pre-Effect
 * code produced. Anything unrecognised is re-thrown so it becomes a defect and
 * flows to Hono's `onError` — the same path a raw `throw` took before.
 */
function errorToResponse(c: HC, error: unknown): Response {
  if (error instanceof ResponseError) {
    const status = error.status as ContentfulStatusCode;
    return error.html
      ? c.html(String(error.body), status, error.headers)
      : c.json(error.body as never, status, error.headers);
  }
  if (error instanceof JsonBodyError) {
    return c.json({ ok: false, error: "Invalid JSON body" }, 400);
  }
  if (error instanceof ValidationError) {
    return c.json(
      { ok: false, error: "Validation failed", issues: error.issues },
      400,
    );
  }
  throw error;
}

/**
 * Runs a route handler Effect and returns its `Response`. Typed failures become
 * their mapped responses; defects reject the promise and surface at Hono's
 * `onError` (Sentry + PostHog + 500), preserving the original error handling.
 */
export function runHandler<E>(
  c: HC,
  effect: Effect.Effect<Response, E, AppServices>,
): Promise<Response> {
  const runnable = effect.pipe(
    Effect.catchAll((e) => Effect.sync(() => errorToResponse(c, e))),
    Effect.provide(makeAppLayer(c.env, safeExecutionCtx(c))),
  );
  return Effect.runPromise(runnable);
}

/**
 * Runs a middleware guard Effect. Success means "let the request through"
 * (resolves `undefined`); a tagged failure — typically a {@link ResponseError}
 * for a 401/429 — resolves to the response the caller should return instead of
 * calling `next()`.
 */
export function runGuard<E>(
  c: HC,
  effect: Effect.Effect<unknown, E, AppServices>,
): Promise<Response | undefined> {
  const runnable = effect.pipe(
    Effect.as<Response | undefined>(undefined),
    Effect.catchAll((e) =>
      Effect.sync((): Response | undefined => errorToResponse(c, e)),
    ),
    Effect.provide(makeAppLayer(c.env, safeExecutionCtx(c))),
  );
  return Effect.runPromise(runnable);
}
