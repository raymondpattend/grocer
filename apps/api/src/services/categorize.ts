import {
  DEFAULT_CATEGORY,
  type GroceryCategory,
  type ParsedItem,
  type Suggestion,
} from "@grocer/shared";

/**
 * Lightweight, dependency-free grocery intelligence. Deterministic keyword
 * matching — good enough for the MVP and runs instantly on the edge. The iOS
 * app works without any of this; it's a convenience layer.
 */

interface Known {
  name: string;
  category: GroceryCategory;
  quantity?: string;
  notes?: string;
  /** Extra match keywords beyond the name itself. */
  aliases?: string[];
}

const CATALOG: Known[] = [
  { name: "Milk", category: "Dairy", quantity: "1 gallon", notes: "2%" },
  { name: "Eggs", category: "Dairy", quantity: "1 dozen" },
  { name: "Butter", category: "Dairy" },
  { name: "Cheese", category: "Dairy", aliases: ["cheddar", "mozzarella"] },
  { name: "Yogurt", category: "Dairy" },
  { name: "Greek Yogurt", category: "Dairy" },
  { name: "Bananas", category: "Produce", quantity: "1 bunch" },
  { name: "Apples", category: "Produce" },
  { name: "Lettuce", category: "Produce" },
  { name: "Spinach", category: "Produce" },
  { name: "Tomatoes", category: "Produce" },
  { name: "Strawberries", category: "Produce" },
  { name: "Blueberries", category: "Produce" },
  { name: "Avocado", category: "Produce" },
  { name: "Onions", category: "Produce" },
  { name: "Potatoes", category: "Produce" },
  { name: "Carrots", category: "Produce" },
  { name: "Chicken Breast", category: "Meat & Seafood", aliases: ["chicken"] },
  { name: "Ground Beef", category: "Meat & Seafood", aliases: ["beef"] },
  { name: "Salmon", category: "Meat & Seafood" },
  { name: "Bacon", category: "Meat & Seafood" },
  { name: "Shrimp", category: "Meat & Seafood" },
  { name: "Bread", category: "Bakery" },
  { name: "Bagels", category: "Bakery" },
  { name: "Tortillas", category: "Bakery" },
  { name: "Rice", category: "Pantry" },
  { name: "Pasta", category: "Pantry", aliases: ["spaghetti", "noodles"] },
  { name: "Cereal", category: "Pantry" },
  { name: "Peanut Butter", category: "Pantry" },
  { name: "Olive Oil", category: "Pantry" },
  { name: "Flour", category: "Pantry" },
  { name: "Sugar", category: "Pantry" },
  { name: "Coffee", category: "Drinks" },
  { name: "Orange Juice", category: "Drinks", aliases: ["oj"] },
  { name: "Sparkling Water", category: "Drinks", aliases: ["seltzer"] },
  { name: "Soda", category: "Drinks", aliases: ["pop", "cola"] },
  { name: "Ice Cream", category: "Frozen" },
  { name: "Frozen Pizza", category: "Frozen" },
  { name: "Frozen Vegetables", category: "Frozen" },
  { name: "Chips", category: "Snacks" },
  { name: "Crackers", category: "Snacks" },
  { name: "Cookies", category: "Snacks" },
  { name: "Granola Bars", category: "Snacks" },
  { name: "Paper Towels", category: "Household" },
  { name: "Toilet Paper", category: "Household" },
  { name: "Dish Soap", category: "Household" },
  { name: "Laundry Detergent", category: "Household" },
  { name: "Trash Bags", category: "Household" },
  { name: "Shampoo", category: "Personal Care" },
  { name: "Toothpaste", category: "Personal Care" },
  { name: "Deodorant", category: "Personal Care" },
  { name: "Soap", category: "Personal Care" },
  { name: "Dog Food", category: "Pet" },
  { name: "Cat Food", category: "Pet" },
  { name: "Cat Litter", category: "Pet" },
];

/** Coarse keyword → category fallback when a term isn't in the catalog. */
const CATEGORY_KEYWORDS: Array<[GroceryCategory, string[]]> = [
  ["Produce", ["fruit", "veggie", "vegetable", "berry", "pepper", "kale", "broccoli", "cucumber", "lime", "lemon", "grapes", "celery"]],
  ["Meat & Seafood", ["meat", "steak", "pork", "turkey", "sausage", "fish", "tuna", "cod", "crab"]],
  ["Dairy", ["cream", "creamer", "cottage", "sour cream"]],
  ["Frozen", ["frozen", "popsicle"]],
  ["Bakery", ["roll", "bun", "muffin", "croissant", "baguette", "donut"]],
  ["Drinks", ["juice", "tea", "water", "drink", "beer", "wine", "lemonade", "kombucha"]],
  ["Snacks", ["snack", "candy", "chocolate", "popcorn", "pretzel", "nuts"]],
  ["Household", ["cleaner", "sponge", "foil", "wrap", "bag", "battery", "bleach"]],
  ["Personal Care", ["lotion", "razor", "floss", "mouthwash", "sunscreen", "vitamin"]],
  ["Pet", ["dog", "cat", "pet", "litter", "treats"]],
  ["Pantry", ["sauce", "soup", "bean", "canned", "spice", "oil", "vinegar", "honey", "syrup", "oats"]],
];

function normalize(s: string): string {
  return s.trim().toLowerCase();
}

function titleCase(s: string): string {
  return s
    .trim()
    .split(/\s+/)
    .map((w) => (w.length ? w[0].toUpperCase() + w.slice(1) : w))
    .join(" ");
}

/** Best-guess category for an arbitrary item name. */
export function categorize(name: string): GroceryCategory {
  const n = normalize(name);

  for (const item of CATALOG) {
    if (normalize(item.name) === n) return item.category;
  }
  for (const item of CATALOG) {
    const hay = [item.name, ...(item.aliases ?? [])].map(normalize);
    if (hay.some((h) => n.includes(h) || h.includes(n))) return item.category;
  }
  for (const [category, keywords] of CATEGORY_KEYWORDS) {
    if (keywords.some((k) => n.includes(k))) return category;
  }
  return DEFAULT_CATEGORY;
}

/** Autocomplete-style suggestions for a partial query. */
export function suggestItems(query: string, recentItems: string[] = []): Suggestion[] {
  const q = normalize(query);
  if (!q) return [];

  const results: Suggestion[] = [];
  const seen = new Set<string>();

  const push = (s: Suggestion) => {
    const key = normalize(s.name);
    if (!seen.has(key)) {
      seen.add(key);
      results.push(s);
    }
  };

  // 1) Recently used items the user has typed before take priority.
  for (const recent of recentItems) {
    if (normalize(recent).includes(q)) {
      push({ name: titleCase(recent), category: categorize(recent) });
    }
  }

  // 2) Catalog matches: prefix first, then substring.
  const prefix = CATALOG.filter((c) => normalize(c.name).startsWith(q));
  const contains = CATALOG.filter(
    (c) => !normalize(c.name).startsWith(q) && normalize(c.name).includes(q),
  );
  for (const c of [...prefix, ...contains]) {
    push({ name: c.name, quantity: c.quantity, category: c.category, notes: c.notes });
  }

  // 3) Always offer the raw query so the user can add anything.
  push({ name: titleCase(query), category: categorize(query) });

  return results.slice(0, 8);
}

/** Parse pasted multi-line text into items with inferred categories. */
export function parseList(text: string): ParsedItem[] {
  const items: ParsedItem[] = [];
  const seen = new Set<string>();

  // Split on newlines and commas. Strip leading list markers only — bullets
  // ("- ", "* ", "• ") and numbered markers ("1.", "2)") — without eating a
  // real leading quantity like "2 lbs".
  const lines = text
    .split(/[\n,]+/)
    .map((l) => l.replace(/^\s*(?:[-*•]\s+|\d+[.)]\s+)/, "").trim())
    .filter(Boolean);

  for (const raw of lines) {
    // Pull a leading quantity like "2 lbs" / "1 gallon" / "3x" if present.
    const qtyMatch = raw.match(
      /^(\d+(?:\.\d+)?\s*(?:x|lbs?|oz|gallons?|gal|dozen|count|ct|pack|packs|bunch|cans?|bottles?|boxes?|bags?)?)\s+(.*)$/i,
    );
    let quantity: string | undefined;
    let name = raw;
    if (qtyMatch && qtyMatch[2]) {
      quantity = qtyMatch[1].trim();
      name = qtyMatch[2].trim();
    }

    name = titleCase(name);
    const key = normalize(name);
    if (!name || seen.has(key)) continue;
    seen.add(key);

    items.push({ name, category: categorize(name), quantity });
  }

  return items;
}
