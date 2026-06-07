# Web API (Cloudflare Worker + Hono)

The API is **optional** — the iOS app works fully without it. It powers
suggestions, list parsing, feedback, remote config, and APNs Live Activity
delivery. CloudKit remains the source of truth for grocery data.

- Runtime: Cloudflare Workers
- Framework: Hono (TypeScript)
- Storage: Cloudflare **D1** (Live Activity tokens, session snapshots, feedback,
  APNs delivery log only)
- Validation: Zod (shared schemas in `packages/shared`)

## Run locally

```bash
corepack enable
pnpm install

# D1 (one-time): create + apply migrations locally
pnpm --filter @grocer/api exec wrangler d1 create grocer   # paste id into wrangler.toml
pnpm --filter @grocer/api exec wrangler d1 migrations apply grocer --local

# APNs secrets for local dev (optional unless testing pushes)
cp apps/api/.dev.vars.example apps/api/.dev.vars

pnpm dev:api            # http://localhost:8787
pnpm test:api           # unit tests (categorize/parse)
```

## Deploy

```bash
# Apply migrations to the remote D1
pnpm --filter @grocer/api exec wrangler d1 migrations apply grocer --remote

# Set APNs secret (private key) and any other secrets
pnpm --filter @grocer/api exec wrangler secret put APNS_PRIVATE_KEY

# Non-secret APNs config lives in wrangler.toml [vars]; edit as needed:
#   APNS_ENVIRONMENT, APNS_TEAM_ID, APNS_KEY_ID, APNS_BUNDLE_ID

pnpm deploy:api
```

Point the iOS app at your deployed Worker by editing the `baseURL` default in
`apps/ios/Grocer/Services/APIClient.swift` (defaults to `http://localhost:8787`).

## Endpoints

All responses are JSON. Invalid bodies return `400` with
`{ ok: false, error, issues: [...] }`.

### `GET /health`
```json
{ "ok": true, "service": "grocery-api", "timestamp": "ISO_DATE" }
```

### `GET /config/ios`
```json
{
  "minimumSupportedBuild": 1,
  "latestBuild": 1,
  "features": { "suggestions": true, "parseList": true, "feedback": true, "liveActivities": true }
}
```

### `POST /feedback`
```json
// request
{ "message": "string", "email": "optional", "appVersion": "optional", "device": "optional" }
// response
{ "ok": true }
```

### `POST /suggestions/items`
```json
// request
{ "query": "milk", "recentItems": ["Milk", "Eggs"], "householdContext": "optional" }
// response
{ "suggestions": [ { "name": "Milk", "quantity": "1 gallon", "category": "Dairy", "notes": "2%" } ] }
```

### `POST /parse-list`
```json
// request
{ "text": "milk\neggs\nbananas\npaper towels" }
// response
{ "items": [ { "name": "Milk", "category": "Dairy" }, { "name": "Bananas", "category": "Produce" } ] }
```

### Live Activity + Shopping Notifications (APNs)

| Method & path | Purpose |
| --- | --- |
| `POST /live-activity/register-token` | Register/refresh a device's push-to-start token, APNs alert token, and local push preferences |
| `POST /live-activity/register-update-token` | Register a running activity's per-activity update token |
| `POST /live-activity/start` | Fan out APNs push-to-start and shopping-start alerts to eligible family devices |
| `POST /live-activity/update` | Send APNs updates to active activities for a session |
| `POST /live-activity/end` | End active activities and send shopping-ended alerts for a session |

`start` / `update` / `end` return `{ ok, sent, failed }`. Start/end can also
include `{ notificationsSent, notificationsFailed }`.

## Code layout

```
apps/api/src/
├── index.ts                 # Hono app, route mounting, error handling
├── env.ts                   # Bindings/vars typing
├── lib/validate.ts          # Zod body parsing → 400s
├── routes/                  # health, config, feedback, suggestions, parseList, liveActivity
├── services/apns.ts         # APNs client (ActivityKit + alert pushes)
├── services/categorize.ts   # keyword categorizer + suggestions + list parser
└── db/                      # schema.ts (docs) + liveActivityTokens.ts (D1 access)
```
