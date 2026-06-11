import {
  GROCERY_CATEGORIES,
  ParseListResponseSchema,
  type ParsedItem,
} from "@grocer/shared";
import type { Env } from "../env.js";
import { titleCase } from "./categorize.js";

const DEFAULT_PARSE_MODEL = "gpt-4.1-mini";

type OpenAIResponse = {
  output_text?: string;
  output?: Array<{
    type?: string;
    content?: Array<{
      type?: string;
      text?: string;
    }>;
  }>;
};

export async function parseListWithAI(
  env: Env,
  text: string,
): Promise<ParsedItem[] | null> {
  const input = text.trim();
  if (!input || !env.OPENAI_API_KEY) return null;

  try {
    const res = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: env.OPENAI_PARSE_MODEL ?? DEFAULT_PARSE_MODEL,
        input: [
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
        ],
        text: {
          format: {
            type: "json_schema",
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
        max_output_tokens: 1400,
      }),
    });

    if (!res.ok) {
      console.warn("OpenAI list parsing failed:", res.status, await res.text());
      return null;
    }

    const json = (await res.json()) as OpenAIResponse;
    const outputText = extractOutputText(json);
    if (!outputText) return null;

    const decoded = JSON.parse(outputText) as unknown;
    const parsed = ParseListResponseSchema.safeParse(decoded);
    if (!parsed.success) {
      console.warn("OpenAI list parsing returned invalid schema:", parsed.error);
      return null;
    }
    return sanitizeParsedItems(parsed.data.items);
  } catch (err) {
    console.warn("OpenAI list parsing skipped:", err);
    return null;
  }
}

function extractOutputText(response: OpenAIResponse): string | null {
  if (response.output_text?.trim()) return response.output_text;

  for (const item of response.output ?? []) {
    for (const part of item.content ?? []) {
      if (part.type === "output_text" && part.text?.trim()) {
        return part.text;
      }
    }
  }
  return null;
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
