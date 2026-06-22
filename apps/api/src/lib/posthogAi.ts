import type { Env } from "../env.js";
import { createPostHogClient } from "./posthog.js";

type AiRole = "system" | "user" | "assistant";

export type AiMessage = {
  role: AiRole;
  content: unknown;
};

type AiUsage = {
  inputTokens?: number;
  outputTokens?: number;
};

type AiCaptureBase = {
  env: Env;
  executionCtx?: ExecutionContext;
  distinctId?: string;
  traceId?: string;
  sessionId?: string;
  spanId?: string;
  spanName: string;
  parentId?: string;
  model: string;
  httpStatus?: number;
  latencyMs?: number;
  isError?: boolean;
  error?: unknown;
  properties?: Record<string, unknown>;
};

export type AiGenerationCapture = AiCaptureBase & AiUsage & {
  input?: AiMessage[];
  outputChoices?: AiMessage[];
  maxTokens?: number;
  stream?: boolean;
  timeToFirstTokenMs?: number;
};

export type AiEmbeddingCapture = AiCaptureBase & {
  input?: string | string[];
  inputTokens?: number;
};

const OPENAI_BASE_URL = "https://api.openai.com/v1";
const MAX_TEXT_LENGTH = 4_000;

export function createAiTraceId(prefix: string): string {
  return `${prefix}:${crypto.randomUUID()}`;
}

export function createAiSpanId(prefix: string): string {
  return `${prefix}:${crypto.randomUUID()}`;
}

/**
 * Whether to create/update a PostHog person profile for this AI event. We do so
 * only when the event is keyed to a real caller (a member/device distinct id),
 * so per-user AI usage attaches to that person's profile — the same identity the
 * iOS client uses for `PostHogSDK.identify`. Shared, background generations
 * (e.g. product-image cache warms) have no caller and stay anonymous, so they
 * don't all collapse onto a single "anonymous" profile.
 */
export function shouldProcessPersonProfile(distinctId: string | undefined): boolean {
  return !!distinctId && distinctId !== "anonymous";
}

export function captureAiGeneration(args: AiGenerationCapture): void {
  void captureAiEvent(args, "$ai_generation", {
    "$ai_trace_id": args.traceId ?? createAiTraceId(args.spanName),
    "$ai_session_id": args.sessionId,
    "$ai_span_id": args.spanId ?? createAiSpanId(args.spanName),
    "$ai_span_name": args.spanName,
    "$ai_parent_id": args.parentId,
    "$ai_model": args.model,
    "$ai_provider": "openai",
    "$ai_input": sanitizeValue(args.input),
    "$ai_input_tokens": args.inputTokens,
    "$ai_output_choices": sanitizeValue(args.outputChoices),
    "$ai_output_tokens": args.outputTokens,
    "$ai_latency": seconds(args.latencyMs),
    "$ai_time_to_first_token": seconds(args.timeToFirstTokenMs),
    "$ai_http_status": args.httpStatus,
    "$ai_base_url": OPENAI_BASE_URL,
    "$ai_is_error": args.isError,
    "$ai_error": sanitizeError(args.error),
    "$ai_max_tokens": args.maxTokens,
    "$ai_stream": args.stream,
    ...args.properties,
  });
}

export function captureAiEmbedding(args: AiEmbeddingCapture): void {
  void captureAiEvent(args, "$ai_embedding", {
    "$ai_trace_id": args.traceId ?? createAiTraceId(args.spanName),
    "$ai_session_id": args.sessionId,
    "$ai_span_id": args.spanId ?? createAiSpanId(args.spanName),
    "$ai_span_name": args.spanName,
    "$ai_parent_id": args.parentId,
    "$ai_model": args.model,
    "$ai_provider": "openai",
    "$ai_input": sanitizeValue(args.input),
    "$ai_input_tokens": args.inputTokens,
    "$ai_latency": seconds(args.latencyMs),
    "$ai_http_status": args.httpStatus,
    "$ai_base_url": OPENAI_BASE_URL,
    "$ai_request_url": `${OPENAI_BASE_URL}/embeddings`,
    "$ai_is_error": args.isError,
    "$ai_error": sanitizeError(args.error),
    ...args.properties,
  });
}

async function captureAiEvent(
  args: AiCaptureBase,
  event: "$ai_generation" | "$ai_embedding",
  properties: Record<string, unknown>,
): Promise<void> {
  if (!args.env.POSTHOG_API_KEY) return;

  const compactProperties = Object.fromEntries(
    Object.entries({
      ...properties,
      "$process_person_profile": shouldProcessPersonProfile(args.distinctId),
    }).filter(([, value]) => value !== undefined),
  );

  try {
    const posthog = createPostHogClient(args.env);
    posthog.capture({
      distinctId: args.distinctId ?? "anonymous",
      event,
      properties: compactProperties,
    });

    const shutdown = posthog.shutdown().catch((err) => {
      console.warn("PostHog AI observability flush failed:", err);
    });
    if (args.executionCtx) {
      args.executionCtx.waitUntil(shutdown);
    } else {
      await shutdown;
    }
  } catch (err) {
    console.warn("PostHog AI observability capture skipped:", err);
  }
}

function seconds(ms: number | undefined): number | undefined {
  return ms === undefined ? undefined : Math.round(ms) / 1_000;
}

function sanitizeError(error: unknown): unknown {
  if (!error) return undefined;
  if (error instanceof Error) {
    return {
      name: error.name,
      message: truncate(error.message),
    };
  }
  return sanitizeValue(error);
}

function sanitizeValue(value: unknown): unknown {
  if (typeof value === "string") return truncate(value);
  if (Array.isArray(value)) return value.map(sanitizeValue);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([key, entry]) => [
        key,
        sanitizeValue(entry),
      ]),
    );
  }
  return value;
}

function truncate(value: string): string {
  if (value.length <= MAX_TEXT_LENGTH) return value;
  return `${value.slice(0, MAX_TEXT_LENGTH)}...`;
}
