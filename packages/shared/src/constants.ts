/**
 * Shared constants for the Grocer app and API.
 *
 * Keep these values in sync with the Swift mirror in
 * apps/ios/Grocer/Models/GroceryModels.swift.
 */

/** Default grocery categories, in display order. */
export const GROCERY_CATEGORIES = [
  "Produce",
  "Meat & Seafood",
  "Dairy",
  "Frozen",
  "Pantry",
  "Bakery",
  "Drinks",
  "Snacks",
  "Household",
  "Personal Care",
  "Pet",
  "Other",
] as const;

export type GroceryCategory = (typeof GROCERY_CATEGORIES)[number];

export const DEFAULT_CATEGORY: GroceryCategory = "Other";

/**
 * Curated palette of grocery quantity units offered in the unit picker. The
 * `unit` field on items/suggestions is free-form (users can type a custom
 * unit), so this list is a convenience palette, not a constraint. Mirrors the
 * Swift `GroceryUnits` list. */
export const GROCERY_UNITS = [
  "each",
  "dozen",
  "pack",
  "bunch",
  "bag",
  "box",
  "can",
  "bottle",
  "jar",
  "loaf",
  "lb",
  "oz",
  "gallon",
  "quart",
  "liter",
  "ml",
  "g",
  "kg",
] as const;
export type GroceryUnit = (typeof GROCERY_UNITS)[number];

/** Grocery item status values. */
export const ITEM_STATUSES = [
  "Needed",
  "Found",
  "Replaced",
  "Out of Stock",
  "Skipped",
  "Removed",
] as const;

export type ItemStatus = (typeof ITEM_STATUSES)[number];

/** Shopping session status values. */
export const SESSION_STATUSES = ["Active", "Completed", "Cancelled"] as const;
export type SessionStatus = (typeof SESSION_STATUSES)[number];

/** Household member roles. */
export const MEMBER_ROLES = ["Owner", "Member"] as const;
export type MemberRole = (typeof MEMBER_ROLES)[number];

/**
 * Default name of the implicit list backing every group. A group *is* the
 * list in the UI; this name is internal. Mirrors Swift `DEFAULT_LIST_NAME`.
 */
export const DEFAULT_LIST_NAME = "Groceries";

/** Preset color themes for a group (mirror of Swift `ListColorTheme`). */
export const GROUP_COLOR_THEMES = [
  "green", "blue", "indigo", "purple", "pink", "red",
  "orange", "yellow", "teal", "mint", "brown", "gray",
] as const;
export type GroupColorTheme = (typeof GROUP_COLOR_THEMES)[number];

/** Curated SF Symbols offered when customizing a group. */
export const GROUP_ICON_CHOICES = [
  "cart.fill", "basket.fill", "bag.fill", "takeoutbag.and.cup.and.straw.fill",
  "fork.knife", "carrot.fill", "fish.fill", "birthday.cake.fill",
  "wineglass.fill", "cup.and.saucer.fill", "house.fill", "pawprint.fill",
  "gift.fill", "leaf.fill", "shippingbox.fill", "heart.fill",
] as const;

/** APNs push type used for ActivityKit Live Activities. */
export const APNS_PUSH_TYPE_LIVE_ACTIVITY = "liveactivity";
