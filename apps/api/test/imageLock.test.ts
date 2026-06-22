import { describe, expect, it } from "vitest";
import {
  LOCK_TTL_MS,
  acquireGenerationLock,
  awaitGeneratedImage,
  lockKey,
  releaseGenerationLock,
} from "../src/lib/imageLock.js";

/**
 * Minimal in-memory R2 that mimics the one behavior the lock relies on:
 * `put(..., { onlyIf: If-None-Match: * })` is an atomic create-if-absent that
 * returns null when the object already exists.
 */
class FakeR2 {
  store = new Map<string, { body: Uint8Array; uploaded: Date }>();
  putCount = 0;

  async put(key: string, value: string | Uint8Array, opts?: any) {
    this.putCount++;
    const ifNoneMatch =
      opts?.onlyIf instanceof Headers ? opts.onlyIf.get("If-None-Match") : undefined;
    if (ifNoneMatch === "*" && this.store.has(key)) return null;
    const body = typeof value === "string" ? new TextEncoder().encode(value) : value;
    this.store.set(key, { body, uploaded: new Date() });
    return { key };
  }

  async head(key: string) {
    const v = this.store.get(key);
    return v ? { uploaded: v.uploaded } : null;
  }

  async get(key: string) {
    const v = this.store.get(key);
    if (!v) return null;
    return { arrayBuffer: async () => v.body.slice().buffer };
  }

  async delete(key: string) {
    this.store.delete(key);
  }
}

const r2 = () => new FakeR2() as unknown as R2Bucket;
const immediate = async () => {};

describe("acquireGenerationLock", () => {
  it("lets exactly one of many concurrent callers win the lock", async () => {
    const images = r2();
    const results = await Promise.all(
      Array.from({ length: 5 }, () => acquireGenerationLock(images, "milk")),
    );
    expect(results.filter(Boolean)).toHaveLength(1);
  });

  it("frees the lock on release", async () => {
    const images = r2();
    expect(await acquireGenerationLock(images, "eggs")).toBe(true);
    expect(await acquireGenerationLock(images, "eggs")).toBe(false);
    await releaseGenerationLock(images, "eggs");
    expect(await acquireGenerationLock(images, "eggs")).toBe(true);
  });

  it("steals a lock left behind by a crashed generation", async () => {
    const fake = new FakeR2();
    const images = fake as unknown as R2Bucket;
    expect(await acquireGenerationLock(images, "bananas")).toBe(true);

    // A fresh lock is held by someone who's still working — not stealable.
    expect(await acquireGenerationLock(images, "bananas")).toBe(false);

    // Age the lock past the TTL → the next caller treats it as abandoned.
    fake.store.get(lockKey("bananas"))!.uploaded = new Date(Date.now() - LOCK_TTL_MS - 1_000);
    expect(await acquireGenerationLock(images, "bananas")).toBe(true);
  });
});

describe("awaitGeneratedImage", () => {
  it("returns the image once the lock holder persists it", async () => {
    const fake = new FakeR2();
    const images = fake as unknown as R2Bucket;
    await acquireGenerationLock(images, "lox");
    const exactKey = "product-images/lox.png";

    // On the first poll, simulate the holder finishing: image lands in R2.
    let polls = 0;
    const sleep = async () => {
      polls++;
      if (polls === 1) {
        fake.store.set(exactKey, { body: new TextEncoder().encode("PNG"), uploaded: new Date() });
      }
    };

    const bytes = await awaitGeneratedImage(images, "lox", exactKey, {
      sleep,
      pollIntervalMs: 1,
      timeoutMs: 100,
    });
    expect(bytes && new TextDecoder().decode(bytes)).toBe("PNG");
  });

  it("returns null when the holder releases the lock without producing an image", async () => {
    const fake = new FakeR2();
    const images = fake as unknown as R2Bucket;
    await acquireGenerationLock(images, "shout");
    const exactKey = "product-images/shout.png";

    // The holder's generation failed: it releases the lock, no image persisted.
    let polls = 0;
    const sleep = async () => {
      polls++;
      if (polls === 1) await releaseGenerationLock(images, "shout");
    };

    const bytes = await awaitGeneratedImage(images, "shout", exactKey, {
      sleep,
      pollIntervalMs: 1,
      timeoutMs: 100,
    });
    expect(bytes).toBeNull();
  });

  it("times out to null when nothing ever appears", async () => {
    const fake = new FakeR2();
    const images = fake as unknown as R2Bucket;
    await acquireGenerationLock(images, "stuck");
    const bytes = await awaitGeneratedImage(images, "stuck", "product-images/stuck.png", {
      sleep: immediate,
      pollIntervalMs: 10,
      timeoutMs: 30,
    });
    expect(bytes).toBeNull();
  });
});
