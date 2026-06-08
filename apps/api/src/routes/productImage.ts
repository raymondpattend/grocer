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

  // 3. Coalesce concurrent generation requests for the same normalized key
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

async function generateAndCache(
  env: Env,
  name: string,
  exactKey: string,
  queryVec: number[] | undefined,
  hasVectorize: boolean,
): Promise<Uint8Array | null> {
  const prompt =
    `A minimalist, modern app icon featuring ${name}, isolated on a fully ` +
    `transparent background with no backdrop, no rounded square, and no ` +
    `surrounding shape or container. The food item is rendered as a clean, ` +
    `stylized flat vector illustration with smooth curves, simple geometric ` +
    `shapes, and subtle layered shading. Use a limited color palette inspired ` +
    `by ${name}'s natural colors, with slightly darker accent tones for depth ` +
    `and dimension. Keep the design playful, polished, and instantly ` +
    `recognizable, with no text, no outlines, no realistic textures, no ` +
    `shadows, and a clean iOS-style aesthetic.`;

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
        prompt,
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

  const raw = Uint8Array.from(atob(b64), (ch) => ch.charCodeAt(0));

  await env.IMAGES.put(exactKey, raw, {
    httpMetadata: { contentType: "image/png" },
  });

  if (hasVectorize && queryVec) {
    const vectorId = normalize(name);
    await env.IMAGE_INDEX.upsert([
      {
        id: vectorId,
        values: queryVec,
        metadata: { r2Key: exactKey, originalName: name },
      },
    ]);
  }

  return raw;
}
