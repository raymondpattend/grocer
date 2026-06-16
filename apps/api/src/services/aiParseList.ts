import {
  GROCERY_CATEGORIES,
  ParseListResponseSchema,
  type ParsedItem,
} from "@grocer/shared";
import type { Env } from "../env.js";
import { createOpenAIClient } from "../lib/grafanaOpenAi.js";
import {
  captureAiGeneration,
  createAiSpanId,
  createAiTraceId,
  type AiMessage,
} from "../lib/posthogAi.js";
import { titleCase } from "./categorize.js";

const DEFAULT_PARSE_MODEL = "gpt-4.1-mini";
const OPENAI_CHAT_COMPLETIONS_URL = "https://api.openai.com/v1/chat/completions";

export async function parseListWithAI(
  env: Env,
  text: string,
  options: {
    executionCtx?: ExecutionContext;
    distinctId?: string;
    traceId?: string;
    sessionId?: string;
  } = {},
): Promise<ParsedItem[] | null> {
  const input = text.trim();
  if (!input || !env.OPENAI_API_KEY) return null;

  const model = env.OPENAI_PARSE_MODEL ?? DEFAULT_PARSE_MODEL;
  const maxTokens = 1400;
  const traceId = options.traceId ?? createAiTraceId("parse-list");
  const spanId = createAiSpanId("parse-list");
  const aiInput: AiMessage[] = [
    {
      role: "system",
      content:
        "Extract a grocery list from free-form text. Infer reasonable grocery items and quantities from the user's words. " +
        "Use concise grocery item names in Title Case (e.g. \"eggs\" -> \"Eggs\", \"chicken breast\" -> \"Chicken Breast\"), merge duplicates, and choose exactly one category from the enum. " +
        "Put ONLY the numeric amount in `quantity` (e.g. \"12\", \"2\", \"1.5\"); leave it an empty string when no amount is stated. " +
        "Set `unit` to the unit the item is measured in. If the user explicitly states a unit or count style, USE THAT (it overrides the natural default), normalizing to a short form: \"individual\"/\"single\"/\"whole\" -> \"each\", \"loaves\" -> \"loaf\", \"cans\" -> \"can\", \"lbs\"/\"pounds\" -> \"lb\". " +
        "Example: \"12 individual bananas\" -> quantity \"12\", unit \"each\" (NOT \"bunch\"). " +
        "When the user does not state a unit, propose the natural unit the item is typically bought in (eggs -> dozen, milk -> gallon, bananas -> bunch, deli meat -> lb, soda -> pack). " +
        "Use an empty string for the unit only when the item has no sensible unit.",
    },
    {
      role: "user",
      content: input,
    },
  ];
  const started = performance.now();
  let httpStatus: number | undefined;
  let captured = false;

  try {
    const openai = createOpenAIClient(env);
    const completion = await openai.chat.completions.create({
      model,
      messages: aiInput.map((message) => ({
        role: message.role,
        content: String(message.content),
      })),
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "grocery_list",
          strict: true,
          schema: {
            type: "object",
            additionalProperties: false,
            properties: {
              items: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    name: { type: "string" },
                    quantity: { type: "string" },
                    unit: { type: "string" },
                    category: {
                      type: "string",
                      enum: GROCERY_CATEGORIES,
                    },
                  },
                  required: ["name", "quantity", "unit", "category"],
                },
              },
            },
            required: ["items"],
          },
        },
      },
      max_completion_tokens: maxTokens,
    });
    httpStatus = 200;
    const latencyMs = performance.now() - started;
    const outputText = completion.choices[0]?.message.content ?? null;
    const outputChoices = outputText
      ? [{ role: "assistant" as const, content: outputText }]
      : [];
    if (!outputText) {
      captureAiGeneration({
        env,
        executionCtx: options.executionCtx,
        distinctId: options.distinctId,
        traceId,
        sessionId: options.sessionId,
        spanId,
        spanName: "parse_list",
        model,
        input: aiInput,
        outputChoices,
        inputTokens: completion.usage?.prompt_tokens,
        outputTokens: completion.usage?.completion_tokens,
        maxTokens,
        latencyMs,
        httpStatus,
        isError: true,
        error: "OpenAI returned no message content",
        properties: {
          "$ai_request_url": OPENAI_CHAT_COMPLETIONS_URL,
        },
      });
      captured = true;
      return null;
    }

    let decoded: unknown;
    try {
      decoded = JSON.parse(outputText) as unknown;
    } catch (err) {
      captureAiGeneration({
        env,
        executionCtx: options.executionCtx,
        distinctId: options.distinctId,
        traceId,
        sessionId: options.sessionId,
        spanId,
        spanName: "parse_list",
        model,
        input: aiInput,
        outputChoices,
        inputTokens: completion.usage?.prompt_tokens,
        outputTokens: completion.usage?.completion_tokens,
        maxTokens,
        latencyMs,
        httpStatus,
        isError: true,
        error: err,
        properties: {
          "$ai_request_url": OPENAI_CHAT_COMPLETIONS_URL,
          grocer_parse_valid: false,
        },
      });
      captured = true;
      throw err;
    }
    const parsed = ParseListResponseSchema.safeParse(decoded);
    captureAiGeneration({
      env,
      executionCtx: options.executionCtx,
      distinctId: options.distinctId,
      traceId,
      sessionId: options.sessionId,
      spanId,
      spanName: "parse_list",
      model,
      input: aiInput,
      outputChoices,
      inputTokens: completion.usage?.prompt_tokens,
      outputTokens: completion.usage?.completion_tokens,
      maxTokens,
      latencyMs,
      httpStatus,
      isError: !parsed.success,
      error: parsed.success ? undefined : parsed.error,
      properties: {
        "$ai_request_url": OPENAI_CHAT_COMPLETIONS_URL,
        grocer_parse_valid: parsed.success,
        grocer_item_count: parsed.success ? parsed.data.items.length : undefined,
      },
    });
    captured = true;
    if (!parsed.success) {
      console.warn("OpenAI list parsing returned invalid schema:", parsed.error);
      return null;
    }
    return sanitizeParsedItems(parsed.data.items);
  } catch (err) {
    if (!captured) {
      captureAiGeneration({
        env,
        executionCtx: options.executionCtx,
        distinctId: options.distinctId,
        traceId,
        sessionId: options.sessionId,
        spanId,
        spanName: "parse_list",
        model,
        input: aiInput,
        maxTokens,
        latencyMs: performance.now() - started,
        httpStatus,
        isError: true,
        error: err,
        properties: {
          "$ai_request_url": OPENAI_CHAT_COMPLETIONS_URL,
        },
      });
    }
    console.warn("OpenAI list parsing skipped:", err);
    return null;
  }
}

function sanitizeParsedItems(items: ParsedItem[]): ParsedItem[] {
  const seen = new Set<string>();
  const out: ParsedItem[] = [];

  for (const item of items) {
    // Normalize to Title Case so names read consistently regardless of how the
    // model (or the user) cased them.
    const name = titleCase(item.name.trim());
    const key = name.toLowerCase();
    if (!name || seen.has(key)) continue;
    seen.add(key);

    out.push({
      name,
      category: item.category,
      quantity: item.quantity?.trim() || undefined,
      unit: item.unit?.trim() || undefined,
    });
  }

  return out.slice(0, 60);
}
