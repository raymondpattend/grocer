import { Hono } from "hono";
import type { Env } from "../env.js";

export const productImageRoute = new Hono<{ Bindings: Env }>();

const SIMILARITY_THRESHOLD = 0.92;

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

async function embed(apiKey: string, text: string): Promise<number[]> {
  const res = await fetch("https://api.openai.com/v1/embeddings", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "text-embedding-3-small",
      input: text.trim().toLowerCase(),
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Embedding failed (${res.status}): ${body}`);
  }
  const json = (await res.json()) as {
    data: Array<{ embedding: number[] }>;
  };
  return json.data[0].embedding;
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
  c.executionCtx.waitUntil(cache.put(cacheKey, response.clone()));
  return response;
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

  if (hasVectorize) {
    try {
      queryVec = await embed(c.env.OPENAI_API_KEY, name);

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

  // 3. Cold path — the image must be generated. Clients can opt into a
  // Server-Sent Events stream (`?stream=1`) that relays OpenAI's partial images
  // so the UI renders a progressively-sharpening preview instead of waiting
  // ~10s for the finished PNG. Cache/R2/vector hits above always return a plain
  // `image/png`, so a streaming client must branch on the response Content-Type.
  if (c.req.query("stream") === "1") {
    return generateAndStream(c, c.env, name, exactKey, cacheKey, queryVec, hasVectorize);
  }

  // Non-stream path: coalesce concurrent generation requests for the same key.
  const existing = inFlight.get(key);
  if (existing) {
    console.log(`Coalescing duplicate request for "${name}"`);
    const bytes = await existing;
    if (bytes) {
      return cacheAtEdge(c, cache, cacheKey, imageResponse(new Uint8Array(bytes)));
    }
    return c.json({ ok: false, error: "Image generation failed" }, 502);
  }

  const generation = generateAndCache(c.env, name, exactKey, queryVec, hasVectorize);
  inFlight.set(key, generation);

  try {
    const bytes = await generation;
    if (!bytes) {
      return c.json({ ok: false, error: "Image generation failed" }, 502);
    }
    return cacheAtEdge(c, cache, cacheKey, imageResponse(bytes));
  } finally {
    inFlight.delete(key);
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

  c.executionCtx.waitUntil(prewarmProductImages(c.env, names));
  return c.json({ ok: true, queued: names.length }, 202);
});

export async function prewarmProductImages(
  env: Env,
  itemNames: string[],
  limit = 8,
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
        await ensureProductImage(env, name);
      } catch (err) {
        console.warn(`Image prewarm skipped for "${name}":`, err);
      }
    }),
  );
}

async function ensureProductImage(env: Env, name: string): Promise<void> {
  const key = normalize(name);
  if (!key) return;

  const exactKey = r2Key(name);
  const exactHit = await env.IMAGES.get(exactKey);
  if (exactHit) return;

  const hasVectorize = typeof env.IMAGE_INDEX?.query === "function";
  let queryVec: number[] | undefined;

  if (hasVectorize) {
    try {
      queryVec = await embed(env.OPENAI_API_KEY, name);
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

  const existing = inFlight.get(key);
  if (existing) {
    await existing;
    return;
  }

  const generation = generateAndCache(env, name, exactKey, queryVec, hasVectorize);
  inFlight.set(key, generation);
  try {
    await generation;
  } finally {
    inFlight.delete(key);
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

/** Persists a finished image to R2 + Vectorize so future requests are cache hits. */
async function persistImage(
  env: Env,
  name: string,
  exactKey: string,
  raw: Uint8Array,
  queryVec: number[] | undefined,
  hasVectorize: boolean,
): Promise<void> {
  await env.IMAGES.put(exactKey, raw, {
    httpMetadata: { contentType: "image/png" },
  });

  if (hasVectorize && queryVec) {
    await env.IMAGE_INDEX.upsert([
      {
        id: normalize(name),
        values: queryVec,
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
): Promise<Uint8Array | null> {
  const openaiRes = await fetch(
    "https://api.openai.com/v1/images/generations",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "gpt-image-1.5",
        prompt: buildPrompt(name),
        n: 1,
        size: "1024x1024",
        quality: "low",
        background: "transparent",
      }),
    },
  );

  if (!openaiRes.ok) {
    const text = await openaiRes.text();
    console.error("OpenAI image generation failed:", openaiRes.status, text);
    return null;
  }

  const result = (await openaiRes.json()) as {
    data: Array<{ b64_json: string }>;
  };

  const b64 = result.data?.[0]?.b64_json;
  if (!b64) {
    console.error("OpenAI returned no image data");
    return null;
  }

  const raw = b64ToBytes(b64);
  await persistImage(env, name, exactKey, raw, queryVec, hasVectorize);
  return raw;
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
): Response {
  const sse = (event: string, data: unknown) =>
    new TextEncoder().encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);

  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      let finalB64: string | null = null;
      try {
        const openaiRes = await fetch(
          "https://api.openai.com/v1/images/generations",
          {
            method: "POST",
            headers: {
              Authorization: `Bearer ${env.OPENAI_API_KEY}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              model: "gpt-image-1.5",
              prompt: buildPrompt(name),
              n: 1,
              size: "1024x1024",
              quality: "low",
              background: "transparent",
              stream: true,
              partial_images: 2,
            }),
          },
        );

        if (!openaiRes.ok || !openaiRes.body) {
          const text = openaiRes.body ? await openaiRes.text() : "(no body)";
          console.error("OpenAI stream failed:", openaiRes.status, text);
          controller.enqueue(sse("error", { message: "Image generation failed" }));
          return;
        }

        const reader = openaiRes.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";
        const emitImageEvent = (evt: OpenAIImageStreamEvent | null) => {
          if (!evt) return;
          if (evt.type === "image_generation.partial_image" && evt.b64_json) {
            controller.enqueue(
              sse("partial", {
                index: evt.partial_image_index ?? 0,
                b64_json: evt.b64_json,
              }),
            );
          } else if (evt.type === "image_generation.completed" && evt.b64_json) {
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
      } catch (err) {
        console.error("Streaming generation error:", err);
        controller.enqueue(sse("error", { message: "Image generation failed" }));
      } finally {
        controller.close();
      }

      // Persist + warm the edge cache off the critical path.
      if (finalB64) {
        const raw = b64ToBytes(finalB64);
        c.executionCtx.waitUntil(
          (async () => {
            await persistImage(env, name, exactKey, raw, queryVec, hasVectorize);
            await caches.default.put(cacheKey, imageResponse(raw));
          })(),
        );
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
