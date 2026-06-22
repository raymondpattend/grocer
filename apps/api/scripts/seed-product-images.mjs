#!/usr/bin/env node
// Prewarm the product-image cache for common grocery items.
//
// Hits GET /product-image?name=<item> for a curated list of staples. The Worker
// generates each missing image once and stores it in R2 + Vectorize + the edge
// cache, so real user requests for these items (and near-spelling variants)
// become instant cache hits instead of ~10s cold generations.
//
// Usage:
//   node scripts/seed-product-images.mjs                       # → production
//   node scripts/seed-product-images.mjs --base http://127.0.0.1:8787
//   node scripts/seed-product-images.mjs --concurrency 4 --dry-run
//
// Safe to re-run: already-cached items return immediately and cost nothing.

const DEFAULT_BASE = "https://api.grocer.sh";

// Curated staples — broad coverage of a typical grocery list. The Worker now
// canonicalizes names server-side (e.g. "Whole milk"/"Skim milk" → "milk"), and
// its vector similarity collapses plurals/variants ("tomato" ↔ "tomatoes"), so
// overlapping entries here just resolve to the same cached image — no waste.
const ITEMS = [
  // Produce
  "Bananas", "Apples", "Oranges", "Lemons", "Limes", "Strawberries", "Blueberries",
  "Raspberries", "Grapes", "Avocado", "Tomatoes", "Potatoes", "Sweet potatoes",
  "Onions", "Garlic", "Carrots", "Celery", "Broccoli", "Cauliflower", "Spinach",
  "Lettuce", "Kale", "Cucumber", "Bell peppers", "Mushrooms", "Zucchini",
  "Green beans", "Corn", "Peas", "Asparagus", "Ginger", "Cilantro", "Parsley",
  "Basil", "Pineapple", "Mango", "Watermelon", "Peaches", "Pears", "Cherries",
  // Dairy & eggs
  "Whole milk", "Skim milk", "Almond milk", "Oat milk", "Eggs", "Butter",
  "Cheddar cheese", "Mozzarella", "Parmesan", "Cream cheese", "Greek yogurt",
  "Yogurt", "Sour cream", "Heavy cream", "Cottage cheese",
  // Meat & seafood
  "Chicken breast", "Ground beef", "Bacon", "Pork chops", "Sausage", "Turkey",
  "Salmon", "Shrimp", "Tuna", "Steak", "Ham", "Deli turkey",
  // Pantry & dry goods
  "Bread", "Bagels", "Tortillas", "Rice", "Pasta", "Spaghetti", "Flour", "Sugar",
  "Brown sugar", "Salt", "Black pepper", "Olive oil", "Vegetable oil", "Vinegar",
  "Soy sauce", "Ketchup", "Mustard", "Mayonnaise", "Honey", "Peanut butter",
  "Jam", "Maple syrup", "Oatmeal", "Cereal", "Granola", "Crackers", "Chips",
  "Popcorn", "Pretzels", "Cookies", "Canned tomatoes", "Tomato sauce",
  "Canned beans", "Black beans", "Chickpeas", "Lentils", "Chicken broth",
  "Coconut milk", "Salsa", "Pasta sauce",
  // Baking
  "Baking soda", "Baking powder", "Vanilla extract", "Chocolate chips",
  "Yeast", "Cocoa powder",
  // Frozen
  "Frozen pizza", "Frozen vegetables", "Ice cream", "Frozen berries",
  "Frozen waffles", "French fries",
  // Beverages
  "Coffee", "Tea", "Orange juice", "Apple juice", "Sparkling water",
  "Soda", "Beer", "Wine", "Water",
  // Household & misc
  "Paper towels", "Toilet paper", "Dish soap", "Laundry detergent",
  "Trash bags", "Aluminum foil", "Plastic wrap", "Napkins",
  "Hand soap", "Sponges",
];

function parseArgs(argv) {
  const args = { base: DEFAULT_BASE, concurrency: 4, dryRun: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--base") args.base = argv[++i];
    else if (a === "--concurrency") args.concurrency = Number(argv[++i]) || 4;
    else if (a === "--dry-run") args.dryRun = true;
    else console.warn(`Ignoring unknown arg: ${a}`);
  }
  return args;
}

async function warm(base, name) {
  const url = `${base.replace(/\/$/, "")}/product-image?name=${encodeURIComponent(name)}`;
  const started = Date.now();
  const res = await fetch(url);
  const ms = Date.now() - started;
  if (!res.ok) {
    throw new Error(`HTTP ${res.status}`);
  }
  // Drain the body so the connection is freed.
  await res.arrayBuffer();
  return ms;
}

// Simple bounded-concurrency pool.
async function run() {
  const { base, concurrency, dryRun } = parseArgs(process.argv);
  console.log(`Seeding ${ITEMS.length} items → ${base} (concurrency=${concurrency})`);
  if (dryRun) {
    ITEMS.forEach((n) => console.log(`  would warm: ${n}`));
    return;
  }

  let cursor = 0;
  let ok = 0;
  let failed = 0;

  async function worker() {
    while (cursor < ITEMS.length) {
      const name = ITEMS[cursor++];
      try {
        const ms = await warm(base, name);
        ok++;
        console.log(`  ✓ ${name} (${ms}ms)  [${ok + failed}/${ITEMS.length}]`);
      } catch (err) {
        failed++;
        console.warn(`  ✗ ${name}: ${err.message}  [${ok + failed}/${ITEMS.length}]`);
      }
    }
  }

  await Promise.all(
    Array.from({ length: Math.max(1, concurrency) }, () => worker()),
  );

  console.log(`\nDone. ${ok} succeeded, ${failed} failed.`);
  if (failed > 0) process.exitCode = 1;
}

run().catch((err) => {
  console.error("Seed failed:", err);
  process.exit(1);
});
