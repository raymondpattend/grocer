<wizard-report>
# PostHog post-wizard report

The wizard has completed a deep integration of PostHog analytics into the Grocer iOS app. Here's what was done:

**SDK installation**: Added `posthog-ios` (≥ 3.58.0) via Swift Package Manager by updating `Grocer.xcodeproj/project.pbxproj` with the required `XCRemoteSwiftPackageReference`, `XCSwiftPackageProductDependency`, and `PBXBuildFile` entries, and linking it to the Grocer target's Frameworks phase.

**Initialization**: Added a `PostHogEnv` enum to `GrocerApp.swift` that reads `POSTHOG_PROJECT_TOKEN` and `POSTHOG_HOST` from the Xcode scheme environment variables (via `ProcessInfo.processInfo.environment`), with a `fatalError` guard if either is missing. PostHog is set up in the `GrocerApp.init()` before Sentry and RevenueCat, with `captureApplicationLifecycleEvents = true`.

**User identification**: After `repository.bootstrap()` in the main scene task, `PostHogSDK.shared.identify()` is called with the user's stable CloudKit/device member ID (`settings.memberIdOrDevice`) and their display name. This links all subsequent events to the correct user.

**Environment variables**: `POSTHOG_PROJECT_TOKEN` and `POSTHOG_HOST` were added to the Xcode scheme's Run environment variables in `Grocer.xcscheme`.

**Events captured** across 8 files:

| Event | Description | File |
|---|---|---|
| `group_created` | User successfully creates a new grocery group | `Grocer/Views/GroupEditorView.swift` |
| `paywall_viewed` | User opens the Grocer Pro paywall | `Grocer/Views/GrocerProPaywallView.swift` |
| `pro_upsell_tapped` | User taps the Pro upsell card on the home screen | `Grocer/Views/HomeView.swift` |
| `subscription_purchased` | User completes a Grocer Pro purchase | `Grocer/Services/SubscriptionStore.swift` |
| `purchases_restored` | User successfully restores previous purchases | `Grocer/Services/SubscriptionStore.swift` |
| `shopping_trip_started` | User starts a shopping session | `Grocer/Views/GroceryListView.swift` |
| `shopping_trip_finished` | User finishes a shopping session | `Grocer/Views/SessionSummaryView.swift` |
| `items_added` | User adds one or more items to a grocery list | `Grocer/Views/AddItemView.swift` |
| `item_marked_found` | Shopper marks an item as found during a trip | `Grocer/Views/ShoppingSessionView.swift` |
| `item_marked_out_of_stock` | Shopper marks an item as out of stock | `Grocer/Views/ShoppingSessionView.swift` |
| `group_member_invited` | User sends an invite to share a grocery group | `Grocer/Views/InviteContactsView.swift` |
| `item_deleted` | User removes an item from a grocery list | `Grocer/Views/GroceryListView.swift` |

## Next steps

We've built some insights and a dashboard for you to keep an eye on user behavior, based on the events we just instrumented:

- [Analytics basics (wizard) — Dashboard](https://us.posthog.com/project/469282/dashboard/1712971)
- [Items Added Over Time](https://us.posthog.com/project/469282/insights/4UWMZb6p)
- [Shopping Trip Funnel](https://us.posthog.com/project/469282/insights/aMoc7K93)
- [Paywall to Purchase Conversion](https://us.posthog.com/project/469282/insights/UHGIQpIA)
- [Pro Upsell & Paywall Views](https://us.posthog.com/project/469282/insights/SEX7vwh4)
- [Group Creation & Invites](https://us.posthog.com/project/469282/insights/6WxX6Zrk)

**Important**: Open Xcode, go to **Product → Scheme → Edit Scheme… → Run → Arguments → Environment Variables**, and confirm `POSTHOG_PROJECT_TOKEN` and `POSTHOG_HOST` are set (they were added to the shared scheme automatically). Build and run the app to verify events appear in [PostHog Live Events](https://us.posthog.com/project/469282/activity/live).

### Agent skill

We've left an agent skill folder in your project at `.claude/skills/integration-swift/`. You can use this context for further agent development when using Claude Code. This will help ensure the model provides the most up-to-date approaches for integrating PostHog.

</wizard-report>
