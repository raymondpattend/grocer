<wizard-report>
# PostHog post-wizard report

The wizard has completed a deep integration of PostHog analytics into the Grocer API — a Cloudflare Workers app built on the Hono framework. A shared `createPostHogClient` factory was added in `src/lib/posthog.ts`, configured for short-lived serverless execution (`flushAt: 1`, `flushInterval: 0`, `enableExceptionAutocapture: true`). Each route creates a per-request client and uses `c.executionCtx.waitUntil(posthog.shutdown())` to flush events in the background without blocking the response. Error tracking via `captureException` was wired into the global `app.onError` handler. PostHog credentials are stored in environment variables (`POSTHOG_API_KEY`, `POSTHOG_HOST`) and referenced from `src/env.ts`.

| Event | Description | File |
|---|---|---|
| `device registered` | A device registers or refreshes its push tokens for live activity notifications | `src/routes/liveActivity.ts` |
| `shopping trip started` | A shopper begins a trip; fan-out push-to-start sent to household members | `src/routes/liveActivity.ts` |
| `shopping trip updated` | Progress update sent for an active shopping trip | `src/routes/liveActivity.ts` |
| `shopping trip ended` | A trip completes or is cancelled, with final item counts and completion rate | `src/routes/liveActivity.ts` |
| `list parsed` | A grocery list text is parsed into structured items (AI or deterministic fallback) | `src/routes/parseList.ts` |
| `feedback submitted` | A user submits in-app feedback | `src/routes/feedback.ts` |

## Next steps

Run `pnpm install` from the monorepo root to update the lockfile with the `posthog-node` dependency. Then add `POSTHOG_API_KEY` as a Cloudflare Workers secret for production:

```
wrangler secret put POSTHOG_API_KEY
```

We've built some insights and a dashboard for you to keep an eye on user behavior, based on the events we just instrumented:

- [Analytics basics (wizard) — Dashboard](https://us.posthog.com/project/469282/dashboard/1709583)
- [Shopping Trips Started](https://us.posthog.com/project/469282/insights/JpLwteWf)
- [Shopping Trip Outcomes (completed vs cancelled)](https://us.posthog.com/project/469282/insights/hDydYeNg)
- [List Parsing: AI vs Fallback](https://us.posthog.com/project/469282/insights/oiTLe6ag)
- [Feedback Submitted](https://us.posthog.com/project/469282/insights/XUhorZdD)
- [Shopping Journey Funnel](https://us.posthog.com/project/469282/insights/4ysS5HvM)

### Agent skill

We've left an agent skill folder in your project at `.claude/skills/integration-javascript_node/`. You can use this context for further agent development when using Claude Code. This will help ensure the model provides the most up-to-date approaches for integrating PostHog.

</wizard-report>
