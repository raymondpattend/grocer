import { describe, expect, it } from "vitest";
import { parseClassification } from "../src/services/classifyGroceryName.js";

describe("parseClassification", () => {
  it("canonicalizes a valid grocery name", () => {
    expect(parseClassification({ is_grocery: true, canonical_name: "milk" }, "2% Milk")).toEqual({
      isGrocery: true,
      canonicalName: "milk",
    });
  });

  it("rejects a non-grocery name and clears the canonical", () => {
    expect(
      parseClassification({ is_grocery: false, canonical_name: "ignored" }, "benjamin netanyahu"),
    ).toEqual({ isGrocery: false, canonicalName: "" });
  });

  it("falls back to the original name when the model returns an empty canonical", () => {
    expect(parseClassification({ is_grocery: true, canonical_name: "  " }, "Bananas")).toEqual({
      isGrocery: true,
      canonicalName: "Bananas",
    });
  });

  it("fails open (allows + keeps the name) on a malformed response", () => {
    expect(parseClassification({ nope: 1 }, "Eggs")).toEqual({
      isGrocery: true,
      canonicalName: "Eggs",
    });
    expect(parseClassification(null, "Eggs")).toEqual({
      isGrocery: true,
      canonicalName: "Eggs",
    });
  });
});
