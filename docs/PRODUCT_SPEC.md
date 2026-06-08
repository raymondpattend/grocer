# Product Spec

Grocer is a private family grocery app. A household keeps a shared list through
the week; when someone shops, they enter a focused shopping mode (like an
Instacart/DoorDash shopper) to mark items found, replaced, out of stock, or
skipped. Family members can keep adding items mid-trip, and those appear in the
shopper's active session. Active trips surface on the family's Lock Screen /
Dynamic Island via Live Activities.

## Core concepts

- **Household** — the shared family grocery space. One per user for MVP. Has a
  name, owner, members, lists, and sessions.
- **Household Member** — a family member (Owner or Member role).
- **Grocery List** — one default list, "Family Groceries", per household.
- **Grocery Item** — name (required) plus optional quantity, category, notes,
  replacement preference. Tracks who requested it and a status
  (Needed / Found / Replaced / Out of Stock / Skipped / Removed).
- **Shopping Session** — created on "Start Shopping" (Active → Completed/Cancelled),
  with optional store name and shopper.
- **Item Event** — append-only history (item added/edited/found/replaced/…,
  session started/completed/cancelled) for clean sync and audit.

## Screens

1. **Home / Grocery List** — quick add, items grouped by category, who added
   each, item count, active-session banner, Start Shopping CTA.
2. **Add Item** — fast entry; name required, everything else optional; live
   suggestions from the API + on-device category guess.
3. **Item Detail** — full info + edit / delete / mark bought / mark not needed.
4. **Shopping Session** — the key UX: big buttons, grouped pending items,
   "Added During Trip" section, collapsed Completed section, Finish button.
5. **Item Action Sheet** — quick actions (Found / Replace / Out of Stock / Skip /
   Add Note / View Details) and a replacement picker.
6. **Session Summary** — found/replaced/out-of-stock/skipped totals + cleanup.
7. **Settings** — household name, invite family, manage members, Live Activity
   toggle, notifications, API diagnostics, send feedback.

## Categories

Produce · Meat & Seafood · Dairy · Frozen · Pantry · Bakery · Drinks · Snacks ·
Household · Personal Care · Pet · Other. (User can change an item's category.)

## Shopping session behavior

- **Start**: optional store name → create Active session in CloudKit → load
  needed items → enter shopping mode → start local Live Activity → ask backend to
  fan out APNs push-to-start to eligible family devices.
- **During**: mark found / out of stock / replace / skip / add item / edit notes;
  newly added items appear under "Added During Trip"; each change updates CloudKit
  and posts a Live Activity update to the backend.
- **End**: mark Completed → summary → cleanup. Found/replaced items clear when
  chosen; out-of-stock items stay by default; skipped items return to the list;
  Live Activity ends via APNs.
- **Inactive trips**: active sessions automatically cancel after 60 minutes
  without session, item, or audit-event activity.

## Offline & conflicts

- Marking continues offline; changes are stored in a durable local outbox and
  sync when CloudKit returns. A small sync indicator shows "Offline — changes
  will sync later".
- Latest-write-wins on mutable item fields; status changes always create item
  events; removed items are soft-deleted and hidden from the active session; one
  active session per household/list (a second start is blocked with the existing
  session shown).

## Notifications

Tied to the Live Activity system: family member started shopping, item added to
the active trip, shopping completed, item out of stock, replacement chosen.

See [the build prompt mirrored in the repo root README](../README.md) for the
full original specification; this file is the condensed reference.
