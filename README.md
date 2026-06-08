# Grocer

A private family grocery app. Keep a shared list through the week, then tap
**Start Shopping** to drop into a focused, Instacart-style shopping mode where
items are marked found / replaced / out of stock / skipped with big one-handed
buttons. Active trips show up on the whole family's Lock Screen and Dynamic
Island via Live Activities.

- **iOS app** — native SwiftUI, iPhone-first.
- **Sync** — Apple-native via **CloudKit** (private + shared databases). CloudKit
  is the source of truth for all grocery data.
- **Family access** — **CloudKit Sharing** (the owner invites family members).
- **Live Activities** — **ActivityKit**, started/updated/ended family-wide via
  **APNs push notifications** coordinated by the backend.
- **Web API** — **Cloudflare Workers + Hono** (TypeScript). Powers suggestions,
  list parsing, feedback, remote config, and APNs Live Activity delivery. The
  app works fully without it.

> No React Native / Expo, no Firebase / Supabase, no traditional server, no web
> frontend. Native SwiftUI + Cloudflare Workers only.

---

## Monorepo structure

```
grocer/
├── apps/
│   ├── ios/                  # Native SwiftUI iOS app (+ widget extension)
│   │   ├── project.yml       # XcodeGen project definition
│   │   ├── Grocer/           # App target
│   │   │   ├── Models/       # Domain models + CloudKit schema constants
│   │   │   ├── Services/     # CloudKit, API client, Live Activity, repository
│   │   │   ├── Shared/       # ActivityAttributes shared with the widget
│   │   │   └── Views/        # SwiftUI screens
│   │   └── GrocerWidget/     # Live Activity (ActivityKit) widget extension
│   └── api/                  # Cloudflare Worker (Hono + D1)
│       ├── src/routes/       # health, config, feedback, suggestions, parse, liveActivity
│       ├── src/services/     # apns.ts (ActivityKit push), categorize.ts
│       ├── src/db/           # D1 schema + token data access
│       ├── migrations/       # D1 SQL migrations
│       └── scripts/          # APNs / endpoint smoke-test script
├── packages/
│   └── shared/               # Shared TS types, Zod schemas, constants
└── docs/                     # Spec, setup, CloudKit, API, Live Activities, entitlements
```

## What lives where (source of truth)

| Data                         | Stored in                          |
| ---------------------------- | ---------------------------------- |
| Households, lists, items, sessions, item events | **CloudKit** (shared DB) |
| Personal settings, recent items, device id      | **CloudKit private DB** / UserDefaults |
| Live Activity push tokens + session snapshots    | **Cloudflare D1** (delivery only) |
| Suggestions / parsing / remote config / feedback | **Cloudflare Worker** |

The backend never becomes the grocery database — it only holds what's needed to
deliver ActivityKit pushes plus lightweight diagnostics.

---

## Quick start

### 1. Web API (Cloudflare Worker)

```bash
corepack enable                 # provides pnpm
pnpm install                    # installs the JS/TS workspace

# Create the D1 database and paste the id into apps/api/wrangler.toml
pnpm --filter @grocer/api exec wrangler d1 create grocer
pnpm --filter @grocer/api exec wrangler d1 migrations apply grocer --local

cp apps/api/.dev.vars.example apps/api/.dev.vars   # add your APNs key for pushes
pnpm dev:api                    # http://localhost:8787

# Smoke-test
curl https://grocer-75.localcan.dev/health
apps/api/scripts/test-live-activity.sh
pnpm test:api
```

See [docs/API.md](docs/API.md) and [docs/LIVE_ACTIVITIES.md](docs/LIVE_ACTIVITIES.md).

### 2. iOS app

```bash
brew install xcodegen           # once
cd apps/ios
xcodegen generate
open Grocer.xcodeproj
```

Then in Xcode:

1. Select both targets → **Signing & Capabilities** → set your **Team**.
2. Replace the placeholder bundle ids `com.example.grocer` /
   `com.example.grocer.GrocerWidget` and the iCloud container
   `iCloud.com.example.grocer` (see [docs/ENTITLEMENTS.md](docs/ENTITLEMENTS.md)).
3. Run on a device or simulator. Without an iCloud account the app falls back to
   local sample data so you can explore the full flow immediately.

The app **builds and runs without any CloudKit/Apple Developer setup** (sample
data, no pushes). CloudKit sync, Sharing, and family-wide Live Activities turn
on once the capabilities and container are configured.

---

## Required Apple capabilities

Configured in the entitlements + Info.plist (see [docs/ENTITLEMENTS.md](docs/ENTITLEMENTS.md)):

- **iCloud → CloudKit** (with a container, e.g. `iCloud.com.example.grocer`)
- **Push Notifications** (for ActivityKit pushes and trip start/end alerts)
- **Live Activities** (`NSSupportsLiveActivities` in Info.plist)
- A **Widget Extension** target (ships the Live Activity UI)

And in the Apple Developer portal, for APNs:

- An **APNs Auth Key** (`.p8`) + its **Key ID**
- Your **Team ID**
- The app **Bundle ID** (the APNs topic base)

These become Cloudflare secrets/vars — see [docs/LIVE_ACTIVITIES.md](docs/LIVE_ACTIVITIES.md).

---

## How Live Activities work (family-wide)

```
Shopper taps "Start Shopping"
      → app writes ShoppingSession to CloudKit (source of truth)
      → app starts a local Live Activity (shopper's own device)
      → app calls POST /live-activity/start
      → Worker looks up eligible family devices (setting ON, valid token)
      → Worker sends ActivityKit push-to-start via APNs
      → family devices display the Live Activity
      → Worker sends standard APNs alerts to notification-enabled family devices
Progress changes → POST /live-activity/update → APNs update pushes
Finish/cancel    → POST /live-activity/end    → APNs end pushes + alert notifications
```

A device can't start a Live Activity directly on another device — that's why the
backend fans out **push-to-start** tokens through APNs. Each device registers its
push-to-start token (when the family setting is ON), its regular APNs device
token (when notifications are ON), and its per-activity update token, so the
backend can target start/update/end events. Full detail in
[docs/LIVE_ACTIVITIES.md](docs/LIVE_ACTIVITIES.md).

---

## Documentation

- [docs/PRODUCT_SPEC.md](docs/PRODUCT_SPEC.md) — product overview & concepts
- [docs/SETUP.md](docs/SETUP.md) — end-to-end setup
- [docs/CLOUDKIT.md](docs/CLOUDKIT.md) — containers, record types, indexes, sharing
- [docs/API.md](docs/API.md) — endpoint reference + deploy guide
- [docs/LIVE_ACTIVITIES.md](docs/LIVE_ACTIVITIES.md) — APNs / ActivityKit setup & testing
- [docs/ENTITLEMENTS.md](docs/ENTITLEMENTS.md) — Apple capabilities & entitlements
- [apps/ios/README.md](apps/ios/README.md) — iOS-specific notes

---

## Known MVP limitations

- **CloudKit schema** must be created (the app creates record types on first
  write in the development environment; promote to production manually). See
  [docs/CLOUDKIT.md](docs/CLOUDKIT.md).
- Participant (non-owner) writes target the owner's shared zone; deep multi-
  writer conflict resolution is intentionally simple (latest-write-wins on text,
  item events preserved). See *Conflict Handling* in the spec.
- The on-device categorizer and the API categorizer are keyword-based (no ML).
- CloudKit subscriptions wake the app for grocery changes, then the app refreshes
  its CloudKit snapshot. Silent pushes can be delayed by iOS, so the app also
  refreshes on launch, foreground activation, and pull-to-refresh.
- APNs requires a paid Apple Developer account; the local in-app Live Activity
  works in the simulator without it.
- The CloudKit share controller uses the iOS 16 preparation-handler API (works,
  deprecation warning on iOS 17+).

## License

Private / unpublished MVP.
