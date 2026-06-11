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
  /** Natural unit this product is usually bought in (e.g. "dozen"). */
  unit?: string;
  notes?: string;
  /** Extra match keywords beyond the name itself. */
  aliases?: string[];
}

const CATALOG: Known[] = [
  { name: "Milk", category: "Dairy", quantity: "1 gallon", unit: "gallon", notes: "2%" },
  { name: "Eggs", category: "Dairy", quantity: "1 dozen", unit: "dozen" },
  { name: "Butter", category: "Dairy", unit: "pack" },
  { name: "Cheese", category: "Dairy", unit: "lb", aliases: ["cheddar", "mozzarella"] },
  { name: "Yogurt", category: "Dairy" },
  { name: "Greek Yogurt", category: "Dairy" },
  { name: "Bananas", category: "Produce", quantity: "1 bunch", unit: "bunch" },
  { name: "Apples", category: "Produce", unit: "lb" },
  { name: "Lettuce", category: "Produce" },
  { name: "Spinach", category: "Produce", unit: "bag" },
  { name: "Tomatoes", category: "Produce", unit: "lb" },
  { name: "Strawberries", category: "Produce" },
  { name: "Blueberries", category: "Produce" },
  { name: "Avocado", category: "Produce" },
  { name: "Onions", category: "Produce" },
  { name: "Potatoes", category: "Produce", unit: "lb" },
  { name: "Carrots", category: "Produce", unit: "bag" },
  { name: "Chicken Breast", category: "Meat & Seafood", unit: "lb", aliases: ["chicken"] },
  { name: "Ground Beef", category: "Meat & Seafood", unit: "lb", aliases: ["beef"] },
  { name: "Salmon", category: "Meat & Seafood", unit: "lb" },
  { name: "Bacon", category: "Meat & Seafood", unit: "pack" },
  { name: "Shrimp", category: "Meat & Seafood", unit: "lb" },
  { name: "Bread", category: "Bakery", unit: "loaf" },
  { name: "Bagels", category: "Bakery", unit: "pack" },
  { name: "Tortillas", category: "Bakery", unit: "pack" },
  { name: "Rice", category: "Pantry", unit: "bag" },
  { name: "Pasta", category: "Pantry", unit: "box", aliases: ["spaghetti", "noodles"] },
  { name: "Cereal", category: "Pantry", unit: "box" },
  { name: "Peanut Butter", category: "Pantry", unit: "jar" },
  { name: "Olive Oil", category: "Pantry", unit: "bottle" },
  { name: "Flour", category: "Pantry", unit: "bag" },
  { name: "Sugar", category: "Pantry", unit: "bag" },
  { name: "Coffee", category: "Drinks", unit: "bag" },
  { name: "Orange Juice", category: "Drinks", unit: "bottle", aliases: ["oj"] },
  { name: "Sparkling Water", category: "Drinks", unit: "pack", aliases: ["seltzer"] },
  { name: "Soda", category: "Drinks", unit: "pack", aliases: ["pop", "cola"] },
  { name: "Ice Cream", category: "Frozen" },
  { name: "Frozen Pizza", category: "Frozen" },
  { name: "Frozen Vegetables", category: "Frozen", unit: "bag" },
  { name: "Chips", category: "Snacks", unit: "bag" },
  { name: "Crackers", category: "Snacks", unit: "box" },
  { name: "Cookies", category: "Snacks" },
  { name: "Granola Bars", category: "Snacks", unit: "box" },
  { name: "Paper Towels", category: "Household", unit: "pack" },
  { name: "Toilet Paper", category: "Household", unit: "pack" },
  { name: "Dish Soap", category: "Household", unit: "bottle" },
  { name: "Laundry Detergent", category: "Household", unit: "bottle" },
  { name: "Trash Bags", category: "Household", unit: "box" },
  { name: "Shampoo", category: "Personal Care", unit: "bottle" },
  { name: "Toothpaste", category: "Personal Care" },
  { name: "Deodorant", category: "Personal Care" },
  { name: "Soap", category: "Personal Care", unit: "pack" },
  { name: "Dog Food", category: "Pet", unit: "bag" },
  { name: "Cat Food", category: "Pet", unit: "bag" },
  { name: "Cat Litter", category: "Pet", unit: "box" },
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

/** Coarse keyword → natural unit fallback when a term isn't in the catalog. */
const UNIT_KEYWORDS: Array<[string, string[]]> = [
  ["dozen", ["egg"]],
  ["gallon", ["milk", "juice", "lemonade", "water jug"]],
  ["bunch", ["banana", "grape", "kale", "cilantro", "parsley", "herb", "scallion", "asparagus"]],
  ["loaf", ["bread", "baguette", "sourdough"]],
  ["lb", ["beef", "steak", "pork", "chicken", "turkey", "fish", "salmon", "tuna", "shrimp", "meat", "cheese", "deli"]],
  ["bottle", ["oil", "vinegar", "soda bottle", "wine", "ketchup", "syrup", "shampoo", "conditioner", "soda water"]],
  ["jar", ["jam", "jelly", "sauce", "salsa", "honey", "pickle", "spread", "butter"]],
  ["can", ["soup", "canned", "bean"]],
  ["box", ["cereal", "pasta", "cracker", "tissue", "cake mix"]],
  ["bag", ["chip", "rice", "flour", "sugar", "frozen", "coffee", "litter", "dog food", "cat food", "salad"]],
  ["pack", ["soda", "beer", "yogurt", "bacon", "paper towel", "toilet paper", "bagel", "tortilla", "battery", "gum"]],
];

function normalize(s: string): string {
  return s.trim().toLowerCase();
}

export function titleCase(s: string): string {
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

/**
 * Best-guess natural unit for an arbitrary item name (e.g. eggs → "dozen").
 * Returns "" when the item is most naturally counted individually.
 */
export function guessUnit(name: string): string {
  const n = normalize(name);

  for (const item of CATALOG) {
    if (normalize(item.name) === n) return item.unit ?? "";
  }
  for (const item of CATALOG) {
    if (!item.unit) continue;
    const hay = [item.name, ...(item.aliases ?? [])].map(normalize);
    if (hay.some((h) => n.includes(h) || h.includes(n))) return item.unit;
  }
  for (const [unit, keywords] of UNIT_KEYWORDS) {
    if (keywords.some((k) => n.includes(k))) return unit;
  }
  return "";
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
      push({ name: titleCase(recent), category: categorize(recent), unit: guessUnit(recent) || undefined });
    }
  }

  // 2) Catalog matches: prefix first, then substring.
  const prefix = CATALOG.filter((c) => normalize(c.name).startsWith(q));
  const contains = CATALOG.filter(
    (c) => !normalize(c.name).startsWith(q) && normalize(c.name).includes(q),
  );
  for (const c of [...prefix, ...contains]) {
    push({ name: c.name, quantity: c.quantity, unit: c.unit, category: c.category, notes: c.notes });
  }

  // 3) Always offer the raw query so the user can add anything.
  push({ name: titleCase(query), category: categorize(query), unit: guessUnit(query) || undefined });

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

    items.push({ name, category: categorize(name), quantity, unit: guessUnit(name) || undefined });
  }

  return items;
}
