import { describe, expect, it } from "vitest";
import { shouldProcessPersonProfile } from "../src/lib/posthogAi.js";

describe("shouldProcessPersonProfile", () => {
  it("creates a person profile for a real caller distinct id", () => {
    expect(shouldProcessPersonProfile("member-123")).toBe(true);
    expect(shouldProcessPersonProfile("device-abc")).toBe(true);
  });

  it("stays profile-less for anonymous or missing callers", () => {
    expect(shouldProcessPersonProfile(undefined)).toBe(false);
    expect(shouldProcessPersonProfile("anonymous")).toBe(false);
  });
});
