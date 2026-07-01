import { Hono } from "hono";
import { describe, expect, it } from "vitest";
import { aiRateLimit, type AiRateLimitOptions } from "../src/lib/aiRateLimit.js";

/**
 * A stand-in for a Cloudflare native `ratelimit` binding: an in-memory
 * fixed counter per key that fails once the limit is exceeded.
 */
function fakeLimiter(limit: number) {
  const counts = new Map<string, number>();
  return {
    limit: async ({ key }: { key: string }) => {
      const next = (counts.get(key) ?? 0) + 1;
      counts.set(key, next);
      return { success: next <= limit };
    },
  };
}

interface Limits {
  per10s?: number;
  perMin?: number;
  perId?: number;
  image?: number;
}

function makeEnv(limits: Limits = {}) {
  return {
    AI_RL_PER_10S: fakeLimiter(limits.per10s ?? 10_000),
    AI_RL_PER_MIN: fakeLimiter(limits.perMin ?? 10_000),
    AI_RL_ID_PER_MIN: fakeLimiter(limits.perId ?? 10_000),
    AI_RL_IMAGE_PER_MIN: fakeLimiter(limits.image ?? 10_000),
  };
}

function makeApp(options: AiRateLimitOptions) {
  const app = new Hono();
  app.use("/ai", aiRateLimit(options));
  app.get("/ai", (c) => c.json({ ok: true }));
  return app;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function hit(app: Hono, env: any, headers: Record<string, string>) {
  const res = await app.request("/ai", { headers }, env);
  return res.status;
}

describe("aiRateLimit", () => {
  it("does not let a rotated distinct-id bypass the per-IP ceiling", async () => {
    // This is the core regression: previously distinct-id was the primary key,
    // so a fresh header per request meant a fresh bucket = unbounded.
    const app = makeApp({ scope: "parse" });
    const env = makeEnv({ perMin: 3 });
    const ip = "203.0.113.9";

    const statuses: number[] = [];
    for (let i = 0; i < 5; i++) {
      statuses.push(
        await hit(app, env, {
          "cf-connecting-ip": ip,
          "x-grocer-distinct-id": `spoof-${i}`, // rotated every request
        }),
      );
    }

    expect(statuses).toEqual([200, 200, 200, 429, 429]);
  });

  it("still enforces the per-IP ceiling when no distinct-id header is sent", async () => {
    const app = makeApp({ scope: "parse" });
    const env = makeEnv({ perMin: 2 });
    const ip = "203.0.113.10";

    const statuses: number[] = [];
    for (let i = 0; i < 3; i++) {
      statuses.push(await hit(app, env, { "cf-connecting-ip": ip }));
    }

    expect(statuses).toEqual([200, 200, 429]);
  });

  it("gives each IP an independent budget", async () => {
    const app = makeApp({ scope: "parse" });
    const env = makeEnv({ perMin: 1 });

    expect(await hit(app, env, { "cf-connecting-ip": "198.51.100.1" })).toBe(200);
    expect(await hit(app, env, { "cf-connecting-ip": "198.51.100.1" })).toBe(429);
    // A different IP is unaffected by the first IP exhausting its budget.
    expect(await hit(app, env, { "cf-connecting-ip": "198.51.100.2" })).toBe(200);
  });

  it("caps a single distinct-id below the per-IP ceiling (fair share)", async () => {
    const app = makeApp({ scope: "parse" });
    const env = makeEnv({ perMin: 100, perId: 2 });
    const ip = "203.0.113.11";
    const id = "stable-user";

    const statuses: number[] = [];
    for (let i = 0; i < 3; i++) {
      statuses.push(
        await hit(app, env, { "cf-connecting-ip": ip, "x-grocer-distinct-id": id }),
      );
    }

    // per-id limit (2) binds before the generous per-IP ceiling (100).
    expect(statuses).toEqual([200, 200, 429]);
  });

  it("applies the tighter image cap to costly routes", async () => {
    const app = makeApp({ scope: "image", costly: true });
    const env = makeEnv({ perMin: 100, image: 2 });
    const ip = "203.0.113.12";

    const statuses: number[] = [];
    for (let i = 0; i < 3; i++) {
      statuses.push(await hit(app, env, { "cf-connecting-ip": ip }));
    }

    // image cap (2) binds before the general per-IP ceiling (100).
    expect(statuses).toEqual([200, 200, 429]);
  });

  it("does not consult the image cap for non-costly routes", async () => {
    const app = makeApp({ scope: "parse" }); // not costly
    const env = makeEnv({ perMin: 100, image: 1 });
    const ip = "203.0.113.13";

    const statuses: number[] = [];
    for (let i = 0; i < 3; i++) {
      statuses.push(await hit(app, env, { "cf-connecting-ip": ip }));
    }

    expect(statuses).toEqual([200, 200, 200]);
  });
});
