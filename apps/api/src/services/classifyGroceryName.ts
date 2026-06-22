import type { Env } from "../env.js";
import { createOpenAIClient } from "../lib/grafanaOpenAi.js";
import {
  captureAiGeneration,
  createAiSpanId,
  createAiTraceId,
  type AiMessage,
} from "../lib/posthogAi.js";

/**
 * One cheap text call that does two jobs before we ever pay ~$0.009 for an
 * image generation on the cold path:
 *
 *   1. Gate (#2) — reject names that aren't real grocery products, so abuse /
 *      junk inputs ("benjamin netanyahu", "fat person", which we saw being
 *      generated in production) never reach the image model.
 *   2. Canonicalize (#3) — collapse trivial variants ("Whole Milk", "2% milk",
 *      "Organic Milk", "milks") onto one canonical name so they share a single
 *      cached image instead of each generating their own.
 *
 * Runs only on a full cache miss, so the per-call cost (a few hundred tokens of
 * gpt-4.1-mini, ~$0.0002) is dwarfed by the image it gates.
 */

const CLASSIFY_MODEL = "gpt-4.1-mini";
const OPENAI_CHAT_COMPLETIONS_URL = "https://api.openai.com/v1/chat/completions";

const SYSTEM_PROMPT =
  "You normalize grocery item names for an image cache. Given a name a user " +
  "typed or that was read off a shopping list, return JSON with two fields.\n\n" +
  "is_grocery: true only if this is a real product someone buys at a grocery " +
  "store — food, drink, produce, pantry, frozen, household, personal care, baby, " +
  "or pet supplies. false for people, places, companies, jokes, insults, " +
  "profanity, or anything you would not find on a store shelf.\n\n" +
  "canonical_name: the simplest common grocery name for the SAME product, in " +
  "lowercase. Remove brand names, quantities, sizes, and decorative qualifiers " +
  "(organic, fresh, large, free-range), and singularize plurals. But PRESERVE " +
  "genuinely different products — do not over-collapse. Examples: \"Organic " +
  "Bananas\" -> \"bananas\"; \"loxs\" -> \"lox\"; \"2% Milk\" -> \"milk\"; " +
  "\"Almond Milk\" -> \"almond milk\" (a different product, keep it); \"Honeycrisp " +
  "Apples\" -> \"apples\". When is_grocery is false, set canonical_name to \"\".";

export interface GroceryClassification {
  /** Whether the name is a real grocery product worth generating an image for. */
  isGrocery: boolean;
  /**
   * Canonical product name to key the image cache on. Raw model string (caller
   * applies its own key normalization). Empty when the name isn't a grocery item.
   */
  canonicalName: string;
}

/**
 * Validates the model's JSON. Fails *open* (allow the original name) on anything
 * unexpected so a malformed response never blocks a legitimate image — the gate
 * is a cost optimization, not a hard security boundary.
 */
export function parseClassification(
  raw: unknown,
  fallbackName: string,
): GroceryClassification {
  if (raw && typeof raw === "object") {
    const obj = raw as { is_grocery?: unknown; canonical_name?: unknown };
    if (typeof obj.is_grocery === "boolean") {
      const canonical =
        typeof obj.canonical_name === "string" ? obj.canonical_name.trim() : "";
      return {
        isGrocery: obj.is_grocery,
        canonicalName: obj.is_grocery ? canonical || fallbackName : "",
      };
    }
  }
  return { isGrocery: true, canonicalName: fallbackName };
}

/**
 * Classifies + canonicalizes a product name via gpt-4.1-mini. Emits an
 * `$ai_generation` span so PostHog tracks the (small) classification cost
 * alongside the image generations it gates. Fails open — if OpenAI isn't
 * configured or the call errors, returns the name unchanged and allowed, so
 * image generation degrades to its pre-gate behavior rather than breaking.
 */
export async function classifyGroceryName(
  env: Env,
  name: string,
  options: {
    executionCtx?: ExecutionContext;
    distinctId?: string;
    traceId?: string;
    parentId?: string;
  } = {},
): Promise<GroceryClassification> {
  const fallback: GroceryClassification = { isGrocery: true, canonicalName: name };
  if (!name.trim() || !env.OPENAI_API_KEY) return fallback;

  const traceId = options.traceId ?? createAiTraceId("product-image");
  const spanId = createAiSpanId("product-image-classification");
  const maxTokens = 60;
  const input: AiMessage[] = [
    { role: "system", content: SYSTEM_PROMPT },
    { role: "user", content: name },
  ];
  const started = performance.now();
  let captured = false;

  try {
    const openai = createOpenAIClient(env);
    const completion = await openai.chat.completions.create({
      model: CLASSIFY_MODEL,
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: name },
      ],
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "grocery_classification",
          strict: true,
          schema: {
            type: "object",
            additionalProperties: false,
            properties: {
              is_grocery: { type: "boolean" },
              canonical_name: { type: "string" },
            },
            required: ["is_grocery", "canonical_name"],
          },
        },
      },
      max_completion_tokens: maxTokens,
    });

    const latencyMs = performance.now() - started;
    const outputText = completion.choices[0]?.message.content ?? null;

    let result = fallback;
    let parseValid = false;
    if (outputText) {
      try {
        result = parseClassification(JSON.parse(outputText), name);
        parseValid = true;
      } catch (err) {
        console.warn("classifyGroceryName: invalid JSON:", err);
      }
    }

    captureAiGeneration({
      env,
      executionCtx: options.executionCtx,
      distinctId: options.distinctId,
      traceId,
      parentId: options.parentId,
      spanId,
      spanName: "product_image_classification",
      model: CLASSIFY_MODEL,
      input,
      outputChoices: outputText ? [{ role: "assistant", content: outputText }] : [],
      inputTokens: completion.usage?.prompt_tokens,
      outputTokens: completion.usage?.completion_tokens,
      maxTokens,
      latencyMs,
      httpStatus: 200,
      isError: !parseValid,
      error: parseValid ? undefined : "classify returned no/invalid JSON",
      properties: {
        "$ai_request_url": OPENAI_CHAT_COMPLETIONS_URL,
        grocer_requested_name: name,
        grocer_canonical_name: result.canonicalName,
        grocer_is_grocery: result.isGrocery,
      },
    });
    captured = true;
    return result;
  } catch (err) {
    if (!captured) {
      captureAiGeneration({
        env,
        executionCtx: options.executionCtx,
        distinctId: options.distinctId,
        traceId,
        parentId: options.parentId,
        spanId,
        spanName: "product_image_classification",
        model: CLASSIFY_MODEL,
        input,
        maxTokens,
        latencyMs: performance.now() - started,
        isError: true,
        error: err,
        properties: {
          "$ai_request_url": OPENAI_CHAT_COMPLETIONS_URL,
          grocer_requested_name: name,
        },
      });
    }
    console.warn("classifyGroceryName skipped:", err);
    return fallback;
  }
}
