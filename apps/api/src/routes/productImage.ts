import { Hono } from "hono";
import { captureException } from "@sentry/cloudflare";
import type { Env } from "../env.js";
import {
  captureAiEmbedding,
  captureAiGeneration,
  createAiSpanId,
  createAiTraceId,
} from "../lib/posthogAi.js";
import {
  acquireGenerationLock,
  awaitGeneratedImage,
  releaseGenerationLock,
} from "../lib/imageLock.js";
import { classifyGroceryName } from "../services/classifyGroceryName.js";
import { aiRateLimit } from "../lib/aiRateLimit.js";

export const productImageRoute = new Hono<{ Bindings: Env }>();

productImageRoute.use("/product-image", aiRateLimit());
productImageRoute.use("/product-image/prewarm", aiRateLimit());

const SIMILARITY_THRESHOLD = 0.92;
const OPENAI_EMBEDDINGS_URL = "https://api.openai.com/v1/embeddings";
const OPENAI_IMAGE_GENERATIONS_URL = "https://api.openai.com/v1/images/generations";
const EMBEDDING_MODEL = "text-embedding-3-small";
const IMAGE_MODEL = "gpt-image-1.5";
const IMAGE_SIZE = "1024x1024";
const IMAGE_QUALITY = "low";
const IMAGE_COUNT = 1;
const IMAGE_GENERATION_PRICES_USD: Record<string, Record<string, number>> = {
  "gpt-image-1.5": {
    "low:1024x1024": 0.009,
    "low:1024x1536": 0.013,
    "low:1536x1024": 0.013,
    "medium:1024x1024": 0.034,
    "medium:1024x1536": 0.05,
    "medium:1536x1024": 0.05,
    "high:1024x1024": 0.133,
    "high:1024x1536": 0.2,
    "high:1536x1024": 0.2,
  },
};

/**
 * How long a background prewarm waits before claiming generation, giving any
 * user-facing streaming view of the same item time to win the generation lock
 * first (so it can show progressive partials instead of a blank wait). Prewarm
 * runs in `waitUntil`, so this pause is invisible to users.
 */
const PREWARM_YIELD_MS = 1_200;

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * In-flight generation promises keyed by normalized item name.
 * Workers run in a single isolate per instance, so concurrent requests
 * within the same isolate coalesce here and share one OpenAI call.
 */
const inFlight = new Map<string, Promise<Uint8Array | null>>();

function normalize(name: string): string {
  return name.trim().toLowerCase().replace(/[^a-z0-9]+/g, "-");
}

function r2Key(itemName: string): string {
  return `product-images/${normalize(itemName)}.png`;
}

async function embed(
  env: Env,
  text: string,
  options: {
    executionCtx?: ExecutionContext;
    traceId?: string;
    parentId?: string;
    spanName?: string;
  } = {},
): Promise<number[]> {
  const input = text.trim().toLowerCase();
  const traceId = options.traceId ?? createAiTraceId("product-image");
  const spanId = createAiSpanId("product-image-embedding");
  const started = performance.now();
  let httpStatus: number | undefined;
  let captured = false;

  try {
    const res = await fetch(OPENAI_EMBEDDINGS_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: EMBEDDING_MODEL,
        input,
      }),
    });
    httpStatus = res.status;
    const latencyMs = performance.now() - started;

    if (!res.ok) {
      const body = await res.text();
      captureAiEmbedding({
        env,
        executionCtx: options.executionCtx,
        traceId,
        parentId: options.parentId,
        spanId,
        spanName: options.spanName ?? "product_image_embedding",
        model: EMBEDDING_MODEL,
        input,
        latencyMs,
        httpStatus,
        isError: true,
        error: body,
      });
      captured = true;
      throw new Error(`Embedding failed (${res.status}): ${body}`);
    }
    const json = (await res.json()) as {
      data: Array<{ embedding: number[] }>;
      usage?: { prompt_tokens?: number; total_tokens?: number };
    };
    captureAiEmbedding({
      env,
      executionCtx: options.executionCtx,
      traceId,
      parentId: options.parentId,
      spanId,
      spanName: options.spanName ?? "product_image_embedding",
      model: EMBEDDING_MODEL,
      input,
      inputTokens: json.usage?.prompt_tokens ?? json.usage?.total_tokens,
      latencyMs,
      httpStatus,
      isError: false,
    });
    captured = true;
    return json.data[0].embedding;
  } catch (err) {
    if (!captured) {
      captureAiEmbedding({
        env,
        executionCtx: options.executionCtx,
        traceId,
        parentId: options.parentId,
        spanId,
        spanName: options.spanName ?? "product_image_embedding",
        model: EMBEDDING_MODEL,
        input,
        latencyMs: performance.now() - started,
        httpStatus,
        isError: true,
        error: err,
      });
    }
    throw err;
  }
}

function imageResponse(body: ReadableStream | Uint8Array): Response {
  return new Response(body, {
    headers: {
      "Content-Type": "image/png",
      "Cache-Control": "public, max-age=31536000, immutable",
    },
  });
}

/**
 * Stable cache key for the shared Cloudflare edge cache. Built from the request
 * origin + the *normalized* name so that casing/whitespace/punctuation variants
 * collapse onto a single cached entry shared by every user.
 */
function edgeCacheKey(requestUrl: string, normalizedName: string): Request {
  const url = new URL(requestUrl);
  url.search = `?name=${encodeURIComponent(normalizedName)}`;
  return new Request(url.toString(), { method: "GET" });
}

/**
 * Writes the image response into the edge cache without blocking the response,
 * and returns a clone to send to the caller (a body can only be read once).
 */
function cacheAtEdge(
  c: { executionCtx: ExecutionContext },
  cache: Cache,
  cacheKey: Request,
  response: Response,
): Response {
  // Swallow put errors (e.g. an uncacheable status) so a caching hiccup never
  // surfaces as an unhandled rejection — the response to the caller is unaffected.
  c.executionCtx.waitUntil(cache.put(cacheKey, response.clone()).catch(() => {}));
  return response;
}

/**
 * Response for a name the classifier rejected as a non-product. Non-200 so the
 * iOS client falls back to its placeholder icon, and `public` + `max-age` so the
 * edge negatively-caches it: repeated junk/abuse requests don't re-bill the
 * classifier. Kept short (1h) so the occasional false rejection self-heals
 * quickly rather than sticking for a day — re-classifying junk hourly is ~free.
 */
function rejectionResponse(): Response {
  return new Response(JSON.stringify({ ok: false, error: "Not a recognizable item" }), {
    status: 422,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "public, max-age=3600",
    },
  });
}

/**
 * GET /product-image?name=Bananas
 *
 * Returns a PNG product image. Uses vector similarity (OpenAI embeddings +
 * Cloudflare Vectorize) so that near-duplicate names like "tomato",
 * "tomatoes", and "Tomatoes'" all resolve to the same cached image in R2.
 *
 * Concurrent requests for the same item coalesce into a single generation.
 */
productImageRoute.get("/product-image", async (c) => {
  const name = c.req.query("name")?.trim();
  if (!name) {
    return c.json({ ok: false, error: "Missing query parameter: name" }, 400);
  }

  const key = normalize(name);
  const exactKey = r2Key(name);

  // 0. Shared Cloudflare edge cache. The cache key is the *normalized* name, so
  // every device — and every spelling/casing variant ("Carrots", "carrots",
  // "Carrots ") — resolves to one globally-cached entry served straight from the
  // colo without touching R2 or Vectorize. This is what makes a cached image
  // load fast on a device that didn't generate it.
  const cache = caches.default;
  const cacheKey = edgeCacheKey(c.req.url, key);
  const edgeHit = await cache.match(cacheKey);
  if (edgeHit) {
    return edgeHit;
  }

  // 1. Exact R2 cache hit (fastest origin path)
  const exactHit = await c.env.IMAGES.get(exactKey);
  if (exactHit) {
    return cacheAtEdge(c, cache, cacheKey, imageResponse(exactHit.body));
  }

  // 2. Embed the query and search Vectorize for a near-match
  const hasVectorize = typeof c.env.IMAGE_INDEX?.query === "function";
  let queryVec: number[] | undefined;
  const traceId = createAiTraceId("product-image");

  if (hasVectorize) {
    try {
      queryVec = await embed(c.env, name, {
        executionCtx: c.executionCtx,
        traceId,
        spanName: "product_image_lookup_embedding",
      });

      const matches = await c.env.IMAGE_INDEX.query(queryVec, {
        topK: 1,
        returnMetadata: "all",
      });

      const best = matches.matches?.[0];
      if (best && best.score >= SIMILARITY_THRESHOLD) {
        const cachedKey = (best.metadata as Record<string, string>)?.r2Key;
        if (cachedKey) {
          const cached = await c.env.IMAGES.get(cachedKey);
          if (cached) {
            console.log(
              `Vector hit: "${name}" → "${best.id}" (score=${best.score.toFixed(3)})`,
            );
            return cacheAtEdge(c, cache, cacheKey, imageResponse(cached.body));
          }
        }
      }
    } catch (err) {
      console.warn("Vector search skipped:", err);
    }
  }

  // 3. Cold path. Before paying for an image, run ONE cheap text call that both
  // (a) rejects non-product/abuse names (people, places, jokes, gibberish) while
  // allowing any real shopping-list item, and (b) canonicalizes the name so
  // variants ("Whole Milk", "2% milk", "Organic Milk") collapse onto a single
  // generated image. This only runs on a full cache miss.
  const classification = await classifyGroceryName(c.env, name, {
    executionCtx: c.executionCtx,
    traceId,
  });
  if (!classification.isGrocery) {
    console.log(`Rejected non-grocery image request: "${name}"`);
    return cacheAtEdge(c, cache, cacheKey, rejectionResponse());
  }

  // Key the generation on the canonical name. Fall back to the raw name if the
  // canonical normalizes to nothing.
  const canonicalName = normalize(classification.canonicalName) ? classification.canonicalName : name;
  const canonical = normalize(canonicalName);
  const canonicalKey = r2Key(canonicalName);

  // The canonical image may already exist even though the raw name missed every
  // cache above (e.g. "2% milk" canonicalizes to an already-generated "milk").
  if (canonical !== key) {
    const canonicalHit = await c.env.IMAGES.get(canonicalKey);
    if (canonicalHit) {
      return cacheAtEdge(c, cache, cacheKey, imageResponse(canonicalHit.body));
    }
  }

  // Reuse the raw query vector when the name didn't change; otherwise leave it
  // undefined so persistImage embeds the canonical name off the critical path
  // (keeps the cold streaming path fast — no second embed before generation).
  const canonicalVec = canonical === key ? queryVec : undefined;

  // Clients can opt into a Server-Sent Events stream (`?stream=1`) that relays
  // OpenAI's partial images so the UI renders a progressively-sharpening preview
  // instead of waiting ~10s for the finished PNG. Cache/R2/vector hits above
  // always return a plain `image/png`, so a streaming client must branch on the
  // response Content-Type.
  if (c.req.query("stream") === "1") {
    return generateAndStream(c, c.env, canonicalName, canonicalKey, cacheKey, canonicalVec, hasVectorize, traceId, name);
  }

  // Non-stream path: coalesce concurrent generation requests for the same
  // canonical key within this isolate (the R2 lock handles cross-isolate).
  const existing = inFlight.get(canonical);
  if (existing) {
    console.log(`Coalescing duplicate request for "${canonicalName}"`);
    // The in-flight generation already captures its own failures; a rejection
    // here is a transient generation error, not a server fault, so degrade to a
    // 502 instead of letting it bubble to the global handler as a 500.
    let bytes: Uint8Array | null = null;
    try {
      bytes = await existing;
    } catch {
      return c.json({ ok: false, error: "Image generation failed" }, 502);
    }
    if (bytes) {
      return cacheAtEdge(c, cache, cacheKey, imageResponse(new Uint8Array(bytes)));
    }
    return c.json({ ok: false, error: "Image generation failed" }, 502);
  }

  const generation = generateAndCache(
    c.env,
    canonicalName,
    canonicalKey,
    canonicalVec,
    hasVectorize,
    {
      executionCtx: c.executionCtx,
      traceId,
      requestedName: name,
    },
  );
  inFlight.set(canonical, generation);

  try {
    const bytes = await generation;
    if (!bytes) {
      return c.json({ ok: false, error: "Image generation failed" }, 502);
    }
    return cacheAtEdge(c, cache, cacheKey, imageResponse(bytes));
  } catch (err) {
    // generateAndCache already captured this failure before re-throwing. A
    // thrown error here is a transient subrequest fault (e.g. a Cloudflare
    // "internal error; reference = …" on the OpenAI/R2 call), so degrade to a
    // 502 rather than letting it surface as an unhandled 500. (GROCER-API-4)
    console.error("Image generation threw:", err);
    return c.json({ ok: false, error: "Image generation failed" }, 502);
  } finally {
    inFlight.delete(canonical);
  }
});

/**
 * POST /product-image/prewarm  { "names": ["Bananas", "Whole milk", ...] }
 *
 * Best-effort: kicks off generation for any names not already cached and returns
 * immediately (202). By the time the user scrolls to the item, the image is a
 * cache hit. Used for add-time prewarming and bulk parse-list imports.
 */
productImageRoute.post("/product-image/prewarm", async (c) => {
  let body: { names?: unknown };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ ok: false, error: "Invalid JSON body" }, 400);
  }

  const names = Array.isArray(body.names)
    ? body.names.filter((n): n is string => typeof n === "string")
    : [];
  if (names.length === 0) {
    return c.json({ ok: false, error: "Missing or empty 'names' array" }, 400);
  }

  c.executionCtx.waitUntil(prewarmProductImages(c.env, names, 8, c.executionCtx));
  return c.json({ ok: true, queued: names.length }, 202);
});

export async function prewarmProductImages(
  env: Env,
  itemNames: string[],
  limit = 8,
  executionCtx?: ExecutionContext,
): Promise<void> {
  if (!env.OPENAI_API_KEY) return;

  const seen = new Set<string>();
  const names = itemNames
    .map((name) => name.trim())
    .filter((name) => {
      const key = normalize(name);
      if (!key || seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .slice(0, limit);

  await Promise.all(
    names.map(async (name) => {
      try {
        await ensureProductImage(env, name, executionCtx);
      } catch (err) {
        console.warn(`Image prewarm skipped for "${name}":`, err);
      }
    }),
  );
}

async function ensureProductImage(
  env: Env,
  name: string,
  executionCtx?: ExecutionContext,
): Promise<void> {
  const key = normalize(name);
  if (!key) return;
  const traceId = createAiTraceId("product-image-prewarm");

  const exactKey = r2Key(name);
  const exactHit = await env.IMAGES.get(exactKey);
  if (exactHit) return;

  // Yield to user-facing streams. Prewarm is background (waitUntil), but a
  // *visible* item is also fetched by a streaming ProductImageView that shows
  // progressive partials — but only if it wins the generation lock. Pause
  // briefly so an imminent stream claims generation first; if it produces the
  // image during the pause we're done, and otherwise we'll lose the lock below
  // and simply await the stream's result instead of generating a duplicate.
  await sleep(PREWARM_YIELD_MS);
  if (await env.IMAGES.get(exactKey)) return;

  const hasVectorize = typeof env.IMAGE_INDEX?.query === "function";
  let queryVec: number[] | undefined;

  if (hasVectorize) {
    try {
      queryVec = await embed(env, name, {
        executionCtx,
        traceId,
        spanName: "product_image_prewarm_embedding",
      });
      const matches = await env.IMAGE_INDEX.query(queryVec, {
        topK: 1,
        returnMetadata: "all",
      });

      const best = matches.matches?.[0];
      const cachedKey = best && best.score >= SIMILARITY_THRESHOLD
        ? (best.metadata as Record<string, string>)?.r2Key
        : undefined;
      if (cachedKey && await env.IMAGES.get(cachedKey)) return;
    } catch (err) {
      console.warn("Vector prewarm search skipped:", err);
    }
  }

  // Canonicalize so prewarm/seed shares cached images with the live path. This
  // is a trusted path (names come from the seed list or vision identify), so we
  // ignore the grocery gate and only use the canonical name.
  const classification = await classifyGroceryName(env, name, { executionCtx, traceId });
  const canonicalName = normalize(classification.canonicalName) ? classification.canonicalName : name;
  const canonical = normalize(canonicalName);
  const canonicalKey = r2Key(canonicalName);
  if (canonical !== key && (await env.IMAGES.get(canonicalKey))) return;

  // Reuse the raw query vector when unchanged; otherwise persistImage embeds the
  // canonical name itself (off the critical path).
  const canonicalVec = canonical === key ? queryVec : undefined;

  const existing = inFlight.get(canonical);
  if (existing) {
    await existing;
    return;
  }

  const generation = generateAndCache(env, canonicalName, canonicalKey, canonicalVec, hasVectorize, {
    executionCtx,
    traceId,
    requestedName: name,
  });
  inFlight.set(canonical, generation);
  try {
    await generation;
  } finally {
    inFlight.delete(canonical);
  }
}

/** The product-image generation prompt, shared by the streaming + buffered paths. */
function buildPrompt(name: string): string {
  return (
    `A minimalist, modern app icon featuring ${name}, isolated on a fully ` +
    `transparent background with no backdrop, no rounded square, and no ` +
    `surrounding shape or container. The food item is rendered as a clean, ` +
    `stylized flat vector illustration with smooth curves, simple geometric ` +
    `shapes, and subtle layered shading. Use a limited color palette inspired ` +
    `by ${name}'s natural colors, with slightly darker accent tones for depth ` +
    `and dimension. Keep the design playful, polished, and instantly ` +
    `recognizable, with no text, no outlines, no realistic textures, no ` +
    `shadows, and a clean iOS-style aesthetic.`
  );
}

function b64ToBytes(b64: string): Uint8Array {
  return Uint8Array.from(atob(b64), (ch) => ch.charCodeAt(0));
}

/** Encodes raw PNG bytes back to base64 for the SSE `complete` payload (used when
 *  a streaming request loses the generation lock and relays another isolate's
 *  finished image). Chunked to avoid blowing the call stack on large images. */
function bytesToB64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

export function imageGenerationCostProperties(
  model: string,
  quality: string,
  size: string,
  count: number,
  generated: boolean,
): Record<string, unknown> {
  const price = IMAGE_GENERATION_PRICES_USD[model]?.[`${quality}:${size}`];
  const requestCost = generated && price !== undefined ? price * count : undefined;

  return {
    "$ai_request_cost_usd": requestCost,
    "$ai_total_cost_usd": requestCost,
    grocer_image_model: model,
    grocer_image_quality: quality,
    grocer_image_size: size,
    grocer_image_count: count,
    grocer_image_unit_price_usd: price,
  };
}

type OpenAIImageStreamEvent = {
  type?: string;
  b64_json?: string;
  partial_image_index?: number;
};

export function parseOpenAIImageStreamFrame(
  frame: string,
): OpenAIImageStreamEvent | null {
  const data = frame
    .replace(/\r/g, "")
    .split("\n")
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).trim())
    .join("\n")
    .trim();
  if (!data || data === "[DONE]") return null;

  try {
    return JSON.parse(data) as OpenAIImageStreamEvent;
  } catch {
    return null;
  }
}

function takeSSEFrame(buffer: string): [frame: string, rest: string] | null {
  const match = /\r?\n\r?\n/.exec(buffer);
  if (!match) return null;
  return [
    buffer.slice(0, match.index),
    buffer.slice(match.index + match[0].length),
  ];
}

export function parseOpenAIImageStreamFrames(
  buffer: string,
): { events: OpenAIImageStreamEvent[]; rest: string } {
  const events: OpenAIImageStreamEvent[] = [];
  let rest = buffer;
  let next: [frame: string, rest: string] | null;

  while ((next = takeSSEFrame(rest))) {
    const [frame, nextRest] = next;
    rest = nextRest;
    const event = parseOpenAIImageStreamFrame(frame);
    if (event) events.push(event);
  }

  return { events, rest };
}

/** Persists a finished image to R2 + Vectorize so future requests are cache hits.
 *  Computes the embedding here (off the generation critical path) when the caller
 *  doesn't supply one — e.g. for a canonicalized name whose vector we deliberately
 *  didn't embed before generating, to keep the cold path fast. */
async function persistImage(
  env: Env,
  name: string,
  exactKey: string,
  raw: Uint8Array,
  queryVec: number[] | undefined,
  hasVectorize: boolean,
  executionCtx?: ExecutionContext,
): Promise<void> {
  await env.IMAGES.put(exactKey, raw, {
    httpMetadata: { contentType: "image/png" },
  });

  if (!hasVectorize) return;

  let vec = queryVec;
  if (!vec) {
    try {
      vec = await embed(env, name, {
        executionCtx,
        spanName: "product_image_persist_embedding",
      });
    } catch (err) {
      console.warn("Persist embedding skipped:", err);
    }
  }
  if (vec) {
    await env.IMAGE_INDEX.upsert([
      {
        id: normalize(name),
        values: vec,
        metadata: { r2Key: exactKey, originalName: name },
      },
    ]);
  }
}

async function generateAndCache(
  env: Env,
  name: string,
  exactKey: string,
  queryVec: number[] | undefined,
  hasVectorize: boolean,
  options: {
    executionCtx?: ExecutionContext;
    traceId?: string;
    /** Original requested name, when it differs from the canonical `name`. */
    requestedName?: string;
  } = {},
): Promise<Uint8Array | null> {
  // Cross-isolate single-flight: if another isolate is already generating this
  // canonical item, wait for its result instead of paying for a duplicate.
  const canonical = normalize(name);
  const won = await acquireGenerationLock(env.IMAGES, canonical);
  if (!won) {
    const shared = await awaitGeneratedImage(env.IMAGES, canonical, exactKey);
    if (shared) return shared;
    // The holder failed or we timed out — fall through and generate ourselves.
  }

  const prompt = buildPrompt(name);
  const traceId = options.traceId ?? createAiTraceId("product-image");
  const spanId = createAiSpanId("product-image-generation");
  const started = performance.now();
  let httpStatus: number | undefined;
  let captured = false;

  try {
    const openaiRes = await fetch(OPENAI_IMAGE_GENERATIONS_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: IMAGE_MODEL,
        prompt,
        n: IMAGE_COUNT,
        size: IMAGE_SIZE,
        quality: IMAGE_QUALITY,
        background: "transparent",
      }),
    });
    httpStatus = openaiRes.status;
    const latencyMs = performance.now() - started;

    if (!openaiRes.ok) {
      const text = await openaiRes.text();
      captureAiGeneration({
        env,
        executionCtx: options.executionCtx,
        traceId,
        spanId,
        spanName: "product_image_generation",
        model: IMAGE_MODEL,
        input: [{ role: "user", content: prompt }],
        latencyMs,
        httpStatus,
        isError: true,
        error: text,
        properties: {
          "$ai_request_url": OPENAI_IMAGE_GENERATIONS_URL,
          ...imageGenerationCostProperties(
            IMAGE_MODEL,
            IMAGE_QUALITY,
            IMAGE_SIZE,
            IMAGE_COUNT,
            false,
          ),
          grocer_item_name: name,
          grocer_requested_name: options.requestedName,
          grocer_image_key: exactKey,
        },
      });
      captured = true;
      console.error("OpenAI image generation failed:", openaiRes.status, text);
      captureException(new Error(`OpenAI image generation failed (${openaiRes.status}): ${text}`));
      return null;
    }

    const result = (await openaiRes.json()) as {
      data: Array<{ b64_json: string }>;
      usage?: {
        input_tokens?: number;
        output_tokens?: number;
      };
    };

    const b64 = result.data?.[0]?.b64_json;
    captureAiGeneration({
      env,
      executionCtx: options.executionCtx,
      traceId,
      spanId,
      spanName: "product_image_generation",
      model: IMAGE_MODEL,
      input: [{ role: "user", content: prompt }],
      outputChoices: b64
        ? [{
          role: "assistant",
          content: [{ type: "image", image: exactKey }],
        }]
        : [],
      inputTokens: result.usage?.input_tokens,
      outputTokens: result.usage?.output_tokens,
      latencyMs,
      httpStatus,
      isError: !b64,
      error: b64 ? undefined : "OpenAI returned no image data",
      properties: {
        "$ai_request_url": OPENAI_IMAGE_GENERATIONS_URL,
        ...imageGenerationCostProperties(
          IMAGE_MODEL,
          IMAGE_QUALITY,
          IMAGE_SIZE,
          IMAGE_COUNT,
          Boolean(b64),
        ),
        grocer_item_name: name,
        grocer_requested_name: options.requestedName,
        grocer_image_key: exactKey,
      },
    });
    captured = true;
    if (!b64) {
      console.error("OpenAI returned no image data");
      captureException(new Error("OpenAI image generation returned no image data"));
      return null;
    }

    const raw = b64ToBytes(b64);
    // Persist before the finally-block releases the lock, so waiters in other
    // isolates find the finished image the moment the lock disappears.
    await persistImage(env, name, exactKey, raw, queryVec, hasVectorize, options.executionCtx);
    return raw;
  } catch (err) {
    if (!captured) {
      captureAiGeneration({
        env,
        executionCtx: options.executionCtx,
        traceId,
        spanId,
        spanName: "product_image_generation",
        model: IMAGE_MODEL,
        input: [{ role: "user", content: prompt }],
        latencyMs: performance.now() - started,
        httpStatus,
        isError: true,
        error: err,
        properties: {
          "$ai_request_url": OPENAI_IMAGE_GENERATIONS_URL,
          ...imageGenerationCostProperties(
            IMAGE_MODEL,
            IMAGE_QUALITY,
            IMAGE_SIZE,
            IMAGE_COUNT,
            false,
          ),
          grocer_item_name: name,
          grocer_requested_name: options.requestedName,
          grocer_image_key: exactKey,
        },
      });
    }
    throw err;
  } finally {
    if (won) await releaseGenerationLock(env.IMAGES, canonical);
  }
}

/**
 * Cold-path generation that relays OpenAI's `partial_images` stream to the
 * client as Server-Sent Events. Three event types are emitted:
 *
 *   event: partial   data: {"index":0,"b64_json":"..."}   (progressive preview)
 *   event: complete  data: {"b64_json":"..."}             (final image)
 *   event: error     data: {"message":"..."}
 *
 * The finished image is persisted to R2/Vectorize and warmed into the edge
 * cache via `waitUntil`, so the next request for this name is an instant hit.
 *
 * Streaming requests deliberately bypass the `inFlight` coalescing map: the SSE
 * body can only be consumed once, so it cannot be shared between callers.
 * Concurrent cold streams for the same name are rare (one per uncached view).
 */
function generateAndStream(
  c: { executionCtx: ExecutionContext },
  env: Env,
  name: string,
  exactKey: string,
  cacheKey: Request,
  queryVec: number[] | undefined,
  hasVectorize: boolean,
  traceId: string = createAiTraceId("product-image"),
  requestedName?: string,
): Response {
  const sse = (event: string, data: unknown) =>
    new TextEncoder().encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      // Cross-isolate single-flight. If another isolate is already generating
      // this canonical item, relay its finished image instead of paying for a
      // duplicate — we just can't show progressive partials in that case.
      const canonical = normalize(name);
      const won = await acquireGenerationLock(env.IMAGES, canonical);
      if (!won) {
        const shared = await awaitGeneratedImage(env.IMAGES, canonical, exactKey);
        if (shared) {
          controller.enqueue(sse("complete", { b64_json: bytesToB64(shared) }));
          controller.close();
          c.executionCtx.waitUntil(
            caches.default.put(cacheKey, imageResponse(shared)).catch(() => {}),
          );
          return;
        }
        // The holder failed or we timed out — generate ourselves below.
      }

      const prompt = buildPrompt(name);
      const spanId = createAiSpanId("product-image-stream");
      const started = performance.now();
      let httpStatus: number | undefined;
      let firstImageMs: number | undefined;
      let captured = false;
      let finalB64: string | null = null;
      try {
        const openaiRes = await fetch(OPENAI_IMAGE_GENERATIONS_URL, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${env.OPENAI_API_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            model: IMAGE_MODEL,
            prompt,
            n: IMAGE_COUNT,
            size: IMAGE_SIZE,
            quality: IMAGE_QUALITY,
            background: "transparent",
            stream: true,
            partial_images: 2,
          }),
        });
        httpStatus = openaiRes.status;

        if (!openaiRes.ok || !openaiRes.body) {
          const text = openaiRes.body ? await openaiRes.text() : "(no body)";
          captureAiGeneration({
            env,
            executionCtx: c.executionCtx,
            traceId,
            spanId,
            spanName: "product_image_generation_stream",
            model: IMAGE_MODEL,
            input: [{ role: "user", content: prompt }],
            latencyMs: performance.now() - started,
            httpStatus,
            stream: true,
            isError: true,
            error: text,
            properties: {
              "$ai_request_url": OPENAI_IMAGE_GENERATIONS_URL,
              ...imageGenerationCostProperties(
                IMAGE_MODEL,
                IMAGE_QUALITY,
                IMAGE_SIZE,
                IMAGE_COUNT,
                false,
              ),
              grocer_item_name: name,
              grocer_requested_name: requestedName,
              grocer_image_key: exactKey,
            },
          });
          captured = true;
          console.error("OpenAI stream failed:", openaiRes.status, text);
          captureException(new Error(`OpenAI image stream failed (${openaiRes.status}): ${text}`));
          controller.enqueue(sse("error", { message: "Image generation failed" }));
          return;
        }

        const reader = openaiRes.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";
        const emitImageEvent = (evt: OpenAIImageStreamEvent | null) => {
          if (!evt) return;
          if (evt.type === "image_generation.partial_image" && evt.b64_json) {
            firstImageMs ??= performance.now() - started;
            controller.enqueue(
              sse("partial", {
                index: evt.partial_image_index ?? 0,
                b64_json: evt.b64_json,
              }),
            );
          } else if (evt.type === "image_generation.completed" && evt.b64_json) {
            firstImageMs ??= performance.now() - started;
            finalB64 = evt.b64_json;
            controller.enqueue(sse("complete", { b64_json: evt.b64_json }));
          }
        };

        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });

          // OpenAI delimits SSE frames with a blank line.
          const parsed = parseOpenAIImageStreamFrames(buffer);
          buffer = parsed.rest;
          for (const event of parsed.events) {
            emitImageEvent(event);
          }
        }
        buffer += decoder.decode();
        if (buffer.trim()) {
          emitImageEvent(parseOpenAIImageStreamFrame(buffer));
        }

        if (!finalB64) {
          controller.enqueue(sse("error", { message: "No image produced" }));
        }
        captureAiGeneration({
          env,
          executionCtx: c.executionCtx,
          traceId,
          spanId,
          spanName: "product_image_generation_stream",
          model: IMAGE_MODEL,
          input: [{ role: "user", content: prompt }],
          outputChoices: finalB64
            ? [{
              role: "assistant",
              content: [{ type: "image", image: exactKey }],
            }]
            : [],
          latencyMs: performance.now() - started,
          httpStatus,
          stream: true,
          isError: !finalB64,
          error: finalB64 ? undefined : "OpenAI returned no streamed image data",
          properties: {
            "$ai_request_url": OPENAI_IMAGE_GENERATIONS_URL,
            ...imageGenerationCostProperties(
              IMAGE_MODEL,
              IMAGE_QUALITY,
              IMAGE_SIZE,
              IMAGE_COUNT,
              Boolean(finalB64),
            ),
            grocer_item_name: name,
            grocer_requested_name: requestedName,
            grocer_image_key: exactKey,
            grocer_time_to_first_image_seconds: firstImageMs === undefined
              ? undefined
              : Math.round(firstImageMs) / 1_000,
          },
        });
        captured = true;
      } catch (err) {
        if (!captured) {
          captureAiGeneration({
            env,
            executionCtx: c.executionCtx,
            traceId,
            spanId,
            spanName: "product_image_generation_stream",
            model: IMAGE_MODEL,
            input: [{ role: "user", content: prompt }],
            latencyMs: performance.now() - started,
            httpStatus,
            stream: true,
            isError: true,
            error: err,
            properties: {
              "$ai_request_url": OPENAI_IMAGE_GENERATIONS_URL,
              ...imageGenerationCostProperties(
                IMAGE_MODEL,
                IMAGE_QUALITY,
                IMAGE_SIZE,
                IMAGE_COUNT,
                false,
              ),
              grocer_item_name: name,
              grocer_requested_name: requestedName,
              grocer_image_key: exactKey,
            },
          });
        }
        console.error("Streaming generation error:", err);
        captureException(err);
        controller.enqueue(sse("error", { message: "Image generation failed" }));
      } finally {
        controller.close();
      }

      // Persist + warm the edge cache off the critical path, then release the
      // lock — ordering matters so cross-isolate waiters find the image the
      // moment the lock disappears.
      if (finalB64) {
        const raw = b64ToBytes(finalB64);
        c.executionCtx.waitUntil(
          (async () => {
            await persistImage(env, name, exactKey, raw, queryVec, hasVectorize, c.executionCtx);
            await caches.default.put(cacheKey, imageResponse(raw)).catch(() => {});
            if (won) await releaseGenerationLock(env.IMAGES, canonical);
          })(),
        );
      } else if (won) {
        c.executionCtx.waitUntil(releaseGenerationLock(env.IMAGES, canonical));
      }
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "X-Accel-Buffering": "no",
    },
  });
}
