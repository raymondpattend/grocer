import OpenAI from "openai";
import { Context, Effect, Layer } from "effect";
import type { Env } from "../env.js";
import { createOpenAIClient } from "../lib/grafanaOpenAi.js";
import { createPostHogClient } from "../lib/posthog.js";
import { OpenAiError } from "./errors.js";

/**
 * Request-scoped services wired per invocation from the Worker's bindings.
 *
 * Each is a plain `Context.Tag` (rather than a static `Effect.Service` with a
 * `.Default`) because their values come from `c.env` / `c.executionCtx`, which
 * only exist once a request is in flight. `makeAppLayer` assembles them at the
 * Hono boundary; handlers just `yield*` the tags.
 */

export interface AppConfigService {
  readonly env: Env;
}
export class AppConfig extends Context.Tag("AppConfig")<AppConfig, AppConfigService>() {}

/**
 * The Worker's `ExecutionContext`, wrapped so `waitUntil` is always safe to call
 * — including in unit tests where Hono has no execution context (the promise is
 * simply detached and its rejection swallowed, matching best-effort telemetry).
 */
export interface ExecService {
  readonly executionCtx: ExecutionContext | undefined;
  readonly waitUntil: (promise: Promise<unknown>) => void;
}
export class Exec extends Context.Tag("Exec")<Exec, ExecService>() {}

/**
 * OpenAI access as an effect. `run` lifts one SDK call into the typed channel,
 * turning any throw/non-2xx into an {@link OpenAiError}; `apiKey` lets callers
 * short-circuit (return their fallback) when OpenAI isn't configured. A fresh
 * Grafana-monitored client is built per call, matching the pre-Effect code.
 */
export interface OpenAiService {
  readonly apiKey: string | undefined;
  readonly run: <A>(f: (client: OpenAI) => Promise<A>) => Effect.Effect<A, OpenAiError>;
}
export class OpenAi extends Context.Tag("OpenAi")<OpenAi, OpenAiService>() {}

/** Best-effort PostHog product analytics: capture an event and flush it off the
 *  response path via `waitUntil`. Centralises the create/capture/shutdown dance
 *  that every route previously repeated inline. */
export interface TelemetryService {
  readonly capture: (input: {
    distinctId: string;
    event: string;
    properties: Record<string, unknown>;
  }) => Effect.Effect<void>;
}
export class Telemetry extends Context.Tag("Telemetry")<Telemetry, TelemetryService>() {}

const OpenAiLive = Layer.effect(
  OpenAi,
  Effect.gen(function* () {
    const { env } = yield* AppConfig;
    return OpenAi.of({
      apiKey: env.OPENAI_API_KEY,
      run: (f) =>
        Effect.tryPromise({
          try: () => f(createOpenAIClient(env)),
          catch: (cause) =>
            new OpenAiError({
              message: cause instanceof Error ? cause.message : String(cause),
              cause,
            }),
        }),
    });
  }),
);

const TelemetryLive = Layer.effect(
  Telemetry,
  Effect.gen(function* () {
    const { env } = yield* AppConfig;
    const exec = yield* Exec;
    return Telemetry.of({
      capture: (input) =>
        Effect.sync(() => {
          const posthog = createPostHogClient(env);
          posthog.capture(input);
          exec.waitUntil(posthog.shutdown());
        }),
    });
  }),
);

/**
 * Builds the full service layer for a single request from its bindings and
 * execution context. Constructed per request (bindings are request-scoped); the
 * layer bodies above only read `env`, so assembly is cheap.
 */
export function makeAppLayer(env: Env, executionCtx: ExecutionContext | undefined) {
  const base = Layer.mergeAll(
    Layer.succeed(AppConfig, { env }),
    Layer.succeed(Exec, {
      executionCtx,
      waitUntil: (promise: Promise<unknown>) => {
        if (executionCtx) executionCtx.waitUntil(promise);
        else void Promise.resolve(promise).catch(() => {});
      },
    }),
  );
  return Layer.mergeAll(OpenAiLive, TelemetryLive).pipe(Layer.provideMerge(base));
}
