import {
  GROCERY_CATEGORIES,
  type IdentifiedItem,
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

const DEFAULT_VISION_MODEL = "gpt-4.1-mini";
const OPENAI_CHAT_COMPLETIONS_URL = "https://api.openai.com/v1/chat/completions";

const SYSTEM_PROMPT =
  "You look at a photo a grocery shopper took. It is one of three things:\n" +
  "1. A single grocery product (e.g. a banana bunch, a milk carton, a cereal box).\n" +
  "2. A written or printed list of multiple grocery items (e.g. a handwritten shopping " +
  "list, a typed note, a screenshot of a list).\n" +
  "3. Neither (not grocery-related at all).\n\n" +
  "If it's a SINGLE product, set kind to \"item\" and fill `item`: the most useful common " +
  "grocery name in Title Case (e.g. \"Bananas\", \"Whole Milk\", \"Cheerios\"), preferring a " +
  "recognizable brand/product name when it's clearly legible, otherwise the generic item; " +
  "choose exactly one category from the enum; set confidence in [0, 1]. Leave `items` empty.\n\n" +
  "If it's a LIST of multiple grocery items, set kind to \"list\" and fill `items` with one " +
  "entry per item you can read. For each: a concise grocery name in Title Case, exactly one " +
  "category from the enum, ONLY the numeric amount in `quantity` (e.g. \"12\", \"2\"; empty " +
  "string when none is written), and `unit` set to the unit when one is written or the natural " +
  "unit otherwise (eggs -> dozen, milk -> gallon, bananas -> bunch), else an empty string. " +
  "Leave `item` null.\n\n" +
  "If it's NEITHER, set kind to \"none\", `item` to null, and `items` to an empty array.";

/**
 * One photo, resolved: either a single identified product or a multi-item
 * grocery list read off the photo (e.g. a handwritten shopping list). At most
 * one side is populated; both are empty when nothing grocery-related was found.
 */
export interface IdentifyOutcome {
  item: IdentifiedItem | null;
  items: ParsedItem[];
}

const EMPTY_OUTCOME: IdentifyOutcome = { item: null, items: [] };

/**
 * Identifies what a shopper photographed using an OpenAI vision model: either a
 * single grocery product or a written list of grocery items. Emits a
 * `$ai_generation` event (with token usage) so PostHog LLM analytics tracks the
 * cost of each identification. Returns an empty outcome when the photo isn't
 * grocery-related, the model fails, or OpenAI isn't configured.
 *
 * The image is sent to OpenAI only for identification; it is never persisted by
 * the Worker (the photo itself lives in CloudKit alongside the item).
 */
export async function identifyItemWithAI(
  env: Env,
  image: string,
  mimeType: string,
  options: {
    executionCtx?: ExecutionContext;
    distinctId?: string;
    traceId?: string;
    sessionId?: string;
  } = {},
): Promise<IdentifyOutcome> {
  if (!image || !env.OPENAI_API_KEY) return EMPTY_OUTCOME;

  const model = DEFAULT_VISION_MODEL;
  // Enough headroom for a multi-item list read off a photo, not just one product.
  const maxTokens = 1400;
  const traceId = options.traceId ?? createAiTraceId("identify-item");
  const spanId = createAiSpanId("identify-item");
  const dataUrl = `data:${mimeType || "image/jpeg"};base64,${image}`;

  // What we send to OpenAI carries the image; what we record in PostHog elides
  // it (the base64 would bloat and be truncated anyway).
  const requestMessages = [
    { role: "system" as const, content: SYSTEM_PROMPT },
    {
      role: "user" as const,
      content: [
        {
          type: "text" as const,
          text: "Identify this grocery photo — a single product or a list of items.",
        },
        { type: "image_url" as const, image_url: { url: dataUrl, detail: "low" as const } },
      ],
    },
  ];
  const capturedInput: AiMessage[] = [
    { role: "system", content: SYSTEM_PROMPT },
    { role: "user", content: "[item photo]" },
  ];

  const started = performance.now();
  let httpStatus: number | undefined;
  let captured = false;

  try {
    const openai = createOpenAIClient(env);
    const completion = await openai.chat.completions.create({
      model,
      messages: requestMessages,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "identified_photo",
          strict: true,
          schema: {
            type: "object",
            additionalProperties: false,
            properties: {
              kind: { type: "string", enum: ["item", "list", "none"] },
              item: {
                type: ["object", "null"],
                additionalProperties: false,
                properties: {
                  name: { type: "string" },
                  category: { type: "string", enum: GROCERY_CATEGORIES },
                  confidence: { type: "number" },
                },
                required: ["name", "category", "confidence"],
              },
              items: {
                type: "array",
                items: {
                  type: "object",
                  additionalProperties: false,
                  properties: {
                    name: { type: "string" },
                    quantity: { type: "string" },
                    unit: { type: "string" },
                    category: { type: "string", enum: GROCERY_CATEGORIES },
                  },
                  required: ["name", "quantity", "unit", "category"],
                },
              },
            },
            required: ["kind", "item", "items"],
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

    let result: IdentifyOutcome = EMPTY_OUTCOME;
    let parseValid = false;
    if (outputText) {
      try {
        const decoded = JSON.parse(outputText) as {
          kind?: string;
          item?: {
            name?: string;
            category?: string;
            confidence?: number;
          } | null;
          items?: Array<{
            name?: string;
            category?: string;
            quantity?: string;
            unit?: string;
          }>;
        };
        parseValid = true;
        if (decoded.kind === "list") {
          result = { item: null, items: sanitizeListItems(decoded.items) };
        } else if (decoded.kind === "item") {
          result = { item: parseSingleItem(decoded.item), items: [] };
        }
      } catch (err) {
        console.warn("OpenAI identify-item returned invalid JSON:", err);
      }
    }

    const matched = result.item !== null || result.items.length > 0;
    captureAiGeneration({
      env,
      executionCtx: options.executionCtx,
      distinctId: options.distinctId,
      traceId,
      sessionId: options.sessionId,
      spanId,
      spanName: "identify_item",
      model,
      input: capturedInput,
      outputChoices,
      inputTokens: completion.usage?.prompt_tokens,
      outputTokens: completion.usage?.completion_tokens,
      maxTokens,
      latencyMs,
      httpStatus,
      isError: !parseValid,
      error: parseValid ? undefined : "OpenAI returned no/invalid identification",
      properties: {
        "$ai_request_url": OPENAI_CHAT_COMPLETIONS_URL,
        grocer_identify_valid: parseValid,
        grocer_identify_matched: matched,
        grocer_identify_kind: result.items.length > 0 ? "list" : result.item ? "item" : "none",
        grocer_identify_category: result.item?.category,
        grocer_identify_list_count: result.items.length,
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
        sessionId: options.sessionId,
        spanId,
        spanName: "identify_item",
        model,
        input: capturedInput,
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
    console.warn("OpenAI identify-item skipped:", err);
    return EMPTY_OUTCOME;
  }
}

/** Validate and normalize the model's single-product guess, or null if unusable. */
function parseSingleItem(
  raw: { name?: string; category?: string; confidence?: number } | null | undefined,
): IdentifiedItem | null {
  if (!raw) return null;
  const name = titleCase((raw.name ?? "").trim());
  const category = raw.category;
  const isValidCategory =
    typeof category === "string" &&
    (GROCERY_CATEGORIES as readonly string[]).includes(category);
  if (!name || !isValidCategory) return null;
  return {
    name,
    category: category as IdentifiedItem["category"],
    confidence: typeof raw.confidence === "number" ? raw.confidence : undefined,
  };
}

/** Normalize the model's multi-item list read off a photo: Title Case, dedupe,
 *  drop blanks, and cap the count (mirrors `sanitizeParsedItems` in the list
 *  parser). */
function sanitizeListItems(
  raw: Array<{ name?: string; category?: string; quantity?: string; unit?: string }> | undefined,
): ParsedItem[] {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const out: ParsedItem[] = [];
  for (const entry of raw) {
    const name = titleCase((entry.name ?? "").trim());
    const category = entry.category;
    const isValidCategory =
      typeof category === "string" &&
      (GROCERY_CATEGORIES as readonly string[]).includes(category);
    const key = name.toLowerCase();
    if (!name || !isValidCategory || seen.has(key)) continue;
    seen.add(key);
    out.push({
      name,
      category: category as ParsedItem["category"],
      quantity: entry.quantity?.trim() || undefined,
      unit: entry.unit?.trim() || undefined,
    });
  }
  return out.slice(0, 60);
}
