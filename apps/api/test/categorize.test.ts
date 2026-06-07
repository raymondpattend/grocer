import { describe, expect, it } from "vitest";
import {
  categorize,
  parseList,
  suggestItems,
} from "../src/services/categorize.js";

describe("categorize", () => {
  it("maps known items to their category", () => {
    expect(categorize("Milk")).toBe("Dairy");
    expect(categorize("bananas")).toBe("Produce");
    expect(categorize("paper towels")).toBe("Household");
  });

  it("uses keyword fallback for unknown items", () => {
    expect(categorize("frozen burritos")).toBe("Frozen");
    expect(categorize("dog treats")).toBe("Pet");
  });

  it("defaults to Other when nothing matches", () => {
    expect(categorize("xyzzy")).toBe("Other");
  });
});

describe("parseList", () => {
  it("parses newline-separated text with categories", () => {
    const items = parseList("milk\neggs\nbananas\npaper towels");
    expect(items.map((i) => i.name)).toEqual([
      "Milk",
      "Eggs",
      "Bananas",
      "Paper Towels",
    ]);
    expect(items[0].category).toBe("Dairy");
    expect(items[3].category).toBe("Household");
  });

  it("extracts leading quantities and dedupes", () => {
    const items = parseList("- 2 lbs chicken breast\n* 1 gallon milk\nmilk");
    expect(items).toHaveLength(2);
    expect(items[0]).toMatchObject({ name: "Chicken Breast", quantity: "2 lbs" });
    expect(items[1]).toMatchObject({ name: "Milk", quantity: "1 gallon" });
  });
});

describe("suggestItems", () => {
  it("suggests catalog matches and always includes the raw query", () => {
    const out = suggestItems("mil");
    expect(out.some((s) => s.name === "Milk")).toBe(true);
  });

  it("prioritizes recent items", () => {
    const out = suggestItems("oat", ["Oat Milk"]);
    expect(out[0].name).toBe("Oat Milk");
  });
});
