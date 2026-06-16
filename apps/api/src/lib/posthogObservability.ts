import type { Context, MiddlewareHandler } from "hono";
import type { Env } from "../env.js";
import { createPostHogClient } from "./posthog.js";

type AppContext = Context<{ Bindings: Env }>;

type LogLevel = "trace" | "debug" | "info" | "warn" | "error" | "fatal";

type OTelValue =
  | { stringValue: string }
  | { boolValue: boolean }
  | { intValue: string }
  | { doubleValue: number }
  | { arrayValue: { values: OTelValue[] } }
  | { kvlistValue: { values: Array<{ key: string; value: OTelValue }> } };

type RequestTelemetry = {
  traceId: string;
  spanId: string;
  parentSpanId?: string;
  startUnixNano: string;
  startedAt: number;
};

const SERVICE_NAME = "grocer-api";
const SCOPE_NAME = "grocer-api-worker";
const MAX_ATTRIBUTE_LENGTH = 2_000;

const severityNumberByLevel: Record<LogLevel, number> = {
  trace: 1,
  debug: 5,
  info: 9,
  warn: 13,
  error: 17,
  fatal: 21,
};

export function posthogApiObservability(): MiddlewareHandler<{ Bindings: Env }> {
  return async (c, next) => {
    const telemetry = createRequestTelemetry(c.req.header("traceparent"));

    try {
      await next();
    } catch (err) {
      captureApiRequest(c, telemetry, 500, err);
      throw err;
    }

    captureApiRequest(c, telemetry, c.res.status);
  };
}

export function capturePostHogException(
  c: AppContext,
  err: unknown,
  properties: Record<string, unknown> = {},
): void {
  if (!c.env.POSTHOG_API_KEY) return;

  try {
    const posthog = createPostHogClient(c.env);
    posthog.captureException(err, distinctIdFromRequest(c), {
      ...requestProperties(c),
      ...properties,
      "$process_person_profile": false,
    });
    c.executionCtx.waitUntil(
      posthog.shutdown().catch((posthogErr) => {
        console.warn("PostHog exception flush failed:", posthogErr);
      }),
    );
  } catch (posthogErr) {
    console.warn("PostHog exception capture skipped:", posthogErr);
  }
}

export function capturePostHogLog(
  env: Env,
  ctx: ExecutionContext,
  args: {
    level: LogLevel;
    body: string;
    traceId?: string;
    spanId?: string;
    attributes?: Record<string, unknown>;
  },
): void {
  if (!env.POSTHOG_API_KEY) return;

  ctx.waitUntil(
    postOtlp(env, "logs", {
      resourceLogs: [
        {
          resource: { attributes: resourceAttributes() },
          scopeLogs: [
            {
              scope: { name: SCOPE_NAME },
              logRecords: [
                {
                  timeUnixNano: unixNanoNow(),
                  observedTimeUnixNano: unixNanoNow(),
                  severityNumber: severityNumberByLevel[args.level],
                  severityText: args.level.toUpperCase(),
                  body: { stringValue: args.body },
                  traceId: args.traceId,
                  spanId: args.spanId,
                  attributes: attributes(args.attributes ?? {}),
                },
              ],
            },
          ],
        },
      ],
    }),
  );
}

function captureApiRequest(
  c: AppContext,
  telemetry: RequestTelemetry,
  status: number,
  err?: unknown,
): void {
  const durationMs = performance.now() - telemetry.startedAt;
  const props = {
    ...requestProperties(c),
    status,
    duration_ms: Math.round(durationMs),
    trace_id: telemetry.traceId,
    span_id: telemetry.spanId,
    error: err ? errorMessage(err) : undefined,
  };

  capturePostHogEvent(c.env, c.executionCtx, {
    distinctId: distinctIdFromRequest(c),
    event: "api request completed",
    properties: props,
  });

  capturePostHogLog(c.env, c.executionCtx, {
    level: err || status >= 500 ? "error" : status >= 400 ? "warn" : "info",
    body: `${c.req.method} ${requestPath(c)} ${status} ${Math.round(durationMs)}ms`,
    traceId: telemetry.traceId,
    spanId: telemetry.spanId,
    attributes: props,
  });

  capturePostHogTraceSpan(c.env, c.executionCtx, {
    traceId: telemetry.traceId,
    spanId: telemetry.spanId,
    parentSpanId: telemetry.parentSpanId,
    name: `${c.req.method} ${requestPath(c)}`,
    startUnixNano: telemetry.startUnixNano,
    endUnixNano: unixNanoNow(),
    statusCode: err || status >= 500 ? 2 : 1,
    statusMessage: err ? errorMessage(err) : undefined,
    attributes: {
      ...props,
      "http.request.method": c.req.method,
      "http.response.status_code": status,
      "url.path": requestPath(c),
    },
  });
}

function capturePostHogEvent(
  env: Env,
  ctx: ExecutionContext,
  args: {
    distinctId: string;
    event: string;
    properties: Record<string, unknown>;
  },
): void {
  if (!env.POSTHOG_API_KEY) return;

  try {
    const posthog = createPostHogClient(env);
    posthog.capture({
      distinctId: args.distinctId,
      event: args.event,
      properties: compactProperties({
        ...args.properties,
        "$process_person_profile": false,
      }),
    });
    ctx.waitUntil(
      posthog.shutdown().catch((posthogErr) => {
        console.warn("PostHog request flush failed:", posthogErr);
      }),
    );
  } catch (err) {
    console.warn("PostHog request capture skipped:", err);
  }
}

function capturePostHogTraceSpan(
  env: Env,
  ctx: ExecutionContext,
  args: {
    traceId: string;
    spanId: string;
    parentSpanId?: string;
    name: string;
    startUnixNano: string;
    endUnixNano: string;
    statusCode: 1 | 2;
    statusMessage?: string;
    attributes: Record<string, unknown>;
  },
): void {
  if (!env.POSTHOG_API_KEY) return;

  ctx.waitUntil(
    postOtlp(env, "traces", {
      resourceSpans: [
        {
          resource: { attributes: resourceAttributes() },
          scopeSpans: [
            {
              scope: { name: SCOPE_NAME },
              spans: [
                {
                  traceId: args.traceId,
                  spanId: args.spanId,
                  parentSpanId: args.parentSpanId,
                  name: args.name,
                  kind: 2,
                  startTimeUnixNano: args.startUnixNano,
                  endTimeUnixNano: args.endUnixNano,
                  attributes: attributes(args.attributes),
                  status: {
                    code: args.statusCode,
                    message: args.statusMessage,
                  },
                },
              ],
            },
          ],
        },
      ],
    }),
  );
}

async function postOtlp(
  env: Env,
  signal: "logs" | "traces",
  body: unknown,
): Promise<void> {
  try {
    const res = await fetch(posthogOtlpUrl(env, signal), {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.POSTHOG_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });

    if (!res.ok) {
      console.warn(
        `PostHog ${signal} export failed:`,
        res.status,
        await res.text(),
      );
    }
  } catch (err) {
    console.warn(`PostHog ${signal} export skipped:`, err);
  }
}

function createRequestTelemetry(traceparent: string | undefined): RequestTelemetry {
  const parsed = parseTraceparent(traceparent);
  return {
    traceId: parsed?.traceId ?? randomHex(16),
    spanId: randomHex(8),
    parentSpanId: parsed?.spanId,
    startUnixNano: unixNanoNow(),
    startedAt: performance.now(),
  };
}

function parseTraceparent(
  traceparent: string | undefined,
): { traceId: string; spanId: string } | null {
  const match = traceparent?.match(
    /^[\da-f]{2}-([\da-f]{32})-([\da-f]{16})-[\da-f]{2}$/i,
  );
  if (!match) return null;
  return {
    traceId: match[1].toLowerCase(),
    spanId: match[2].toLowerCase(),
  };
}

function randomHex(byteLength: number): string {
  const bytes = new Uint8Array(byteLength);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function unixNanoNow(): string {
  return `${BigInt(Date.now()) * 1_000_000n}`;
}

function posthogOtlpUrl(env: Env, signal: "logs" | "traces"): string {
  return `${env.POSTHOG_HOST.replace(/\/+$/, "")}/i/v1/${signal}`;
}

function requestProperties(c: AppContext): Record<string, unknown> {
  const url = new URL(c.req.url);
  return {
    method: c.req.method,
    path: url.pathname,
    route: c.req.routePath,
    user_agent: c.req.header("user-agent"),
    ip: c.req.header("cf-connecting-ip"),
    cf_ray: c.req.header("cf-ray"),
    device_id: c.req.header("x-grocer-device-id"),
  };
}

function requestPath(c: AppContext): string {
  return new URL(c.req.url).pathname;
}

function distinctIdFromRequest(c: AppContext): string {
  return c.req.header("x-grocer-device-id") ?? "anonymous";
}

function errorMessage(err: unknown): string {
  if (err instanceof Error) return err.message;
  return String(err);
}

function resourceAttributes(): Array<{ key: string; value: OTelValue }> {
  return attributes({
    "service.name": SERVICE_NAME,
    "service.namespace": "grocer",
    "deployment.environment": "cloudflare-workers",
  });
}

function attributes(values: Record<string, unknown>): Array<{ key: string; value: OTelValue }> {
  return Object.entries(compactProperties(values)).map(([key, value]) => ({
    key,
    value: otelValue(value),
  }));
}

function otelValue(value: unknown): OTelValue {
  if (typeof value === "boolean") return { boolValue: value };
  if (typeof value === "number") {
    return Number.isInteger(value)
      ? { intValue: String(value) }
      : { doubleValue: value };
  }
  if (typeof value === "bigint") return { intValue: String(value) };
  if (Array.isArray(value)) {
    return { arrayValue: { values: value.map(otelValue) } };
  }
  if (value && typeof value === "object") {
    return {
      kvlistValue: {
        values: Object.entries(value as Record<string, unknown>).map(([key, entry]) => ({
          key,
          value: otelValue(entry),
        })),
      },
    };
  }
  return { stringValue: truncate(String(value)) };
}

function compactProperties(values: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(values).filter(([, value]) => value !== undefined && value !== null),
  );
}

function truncate(value: string): string {
  if (value.length <= MAX_ATTRIBUTE_LENGTH) return value;
  return `${value.slice(0, MAX_ATTRIBUTE_LENGTH)}...`;
}
