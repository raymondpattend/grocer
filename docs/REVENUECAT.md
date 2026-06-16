# RevenueCat + Web Billing Setup

Grocer integrates RevenueCat through Swift Package Manager and uses a custom
SwiftUI paywall. Native App Store purchases go through RevenueCat's iOS SDK.
Web purchases go through Stripe checkout hosted by the Grocer Worker, then sync
back into RevenueCat through RevenueCat's Stripe server-notification integration.

RevenueCat is the entitlement source in the app. The Worker never unlocks
features directly.

## 1. Swift Package

The iOS project is generated from `apps/ios/project.yml`. RevenueCat is configured there with the fast SPM mirror:

```yaml
packages:
  RevenueCat:
    url: https://github.com/RevenueCat/purchases-ios-spm.git
    from: 5.43.0
```

The app target links both products:

```yaml
dependencies:
  - package: RevenueCat
    product: RevenueCat
  - package: RevenueCat
    product: RevenueCatUI
```

Regenerate after changing packages:

```sh
cd apps/ios
xcodegen generate
```

If you add it manually in Xcode, choose `File > Add Package Dependencies...`, enter `https://github.com/RevenueCat/purchases-ios-spm.git`, use an up-to-next-major 5.x rule, and select `RevenueCat` and `RevenueCatUI`.

## 2. App Configuration

Configuration lives in `Grocer/Services/SubscriptionStore.swift`. The app first
creates or loads a stable purchase UID from Keychain / iCloud KVS, then uses it
as RevenueCat's `appUserID`:

```swift
enum RevenueCatConfig {
    static let apiKey = "test_tSaSOTwPRseDzLdzjuGNqrnTOSb"
    static let grocerProEntitlementID = "Grocer Pro"

    static func configure(appUserID: String) {
        #if DEBUG
        Purchases.logLevel = .debug
        #endif

        Purchases.configure(withAPIKey: apiKey, appUserID: appUserID)
    }
}
```

`GrocerApp` injects `SubscriptionStore.shared` into SwiftUI and calls
`await subscriptions.start()` during startup. Do not call `Purchases.shared`
before that async startup has configured RevenueCat.

The current key is a RevenueCat Test Store key. Before App Store release, replace it with the public Apple app SDK key from RevenueCat.

## 3. Dashboard Product Setup

Create one entitlement:

| Display name | Identifier |
| --- | --- |
| Grocer Pro | `Grocer Pro` |

Configure products:

| Product | Identifier | Type | Entitlement |
| --- | --- | --- | --- |
| Annual | `grocer_pro_subscription_annual_1` | Auto-renewable subscription | `Grocer Pro` |
| Quarterly | `grocer_pro_subscription_quarterly_1` | Auto-renewable subscription | `Grocer Pro` |
| Monthly | `grocer_pro_subscription_monthly_1` | Auto-renewable subscription | `Grocer Pro` |

Create an offering, make it the default/current offering, and add packages:

| Package | Product |
| --- | --- |
| Annual | `grocer_pro_subscription_annual_1` |
| Three month | `grocer_pro_subscription_quarterly_1` |
| Monthly | `grocer_pro_subscription_monthly_1` |

Grocer renders its own paywall, but pricing, trial text, package order, and
paywall copy metadata still come from the current RevenueCat offering.

## 4. Web Checkout / Stripe Sync

The iOS app builds web checkout URLs like:

```text
https://api.trygrocer.com/checkout?packageId=$rc_monthly&uid=<purchase_uid>
```

The Worker creates or reuses a Stripe customer, then redirects to hosted Stripe
Checkout. Checkout creates subscriptions with
`metadata.user_id = <purchase_uid>` for RevenueCat webhook identification. The
Worker also writes `metadata.app_user_id` for compatibility, but RevenueCat
should be configured to read the `user_id` metadata field. This exact match is
what grants the Stripe subscription to the same RevenueCat customer used by the
iOS SDK.

Required Worker secrets:

| Variable | Purpose |
| --- | --- |
| `STRIPE_SECRET_KEY` | Stripe server API key |
| `STRIPE_PRICE_ANNUAL` | Stripe annual recurring Price ID |
| `STRIPE_PRICE_QUARTERLY` | Stripe quarterly recurring Price ID |
| `STRIPE_PRICE_MONTHLY` | Stripe monthly recurring Price ID |
| `REVENUECAT_SECRET_KEY` | RevenueCat secret key for server-side trial eligibility |

## 5. Entitlement Checking

Use `SubscriptionStore.hasGrocerPro` anywhere in SwiftUI:

```swift
@Environment(SubscriptionStore.self) private var subscriptions

if subscriptions.hasGrocerPro {
    ProFeatureView()
} else {
    Button("Upgrade") {
        showProPaywall = true
    }
}
```

The store keeps `CustomerInfo` current by fetching it on startup and listening to `Purchases.shared.customerInfoStream`.

## 6. Purchases, Restores, And Customer Info

Manual purchase support is available when you need a custom paywall:

```swift
if let package = subscriptions.availablePackages.first {
    Task {
        await subscriptions.purchase(package)
    }
}
```

Restore support:

```swift
Task {
    await subscriptions.restorePurchases()
}
```

Direct customer info refresh:

```swift
Task {
    await subscriptions.refresh()
}
```

The Settings screen exposes purchase, restore, and management actions through
the custom paywall and store-aware management routing below.

## 7. Subscription Management

Settings routes management based on the active RevenueCat entitlement store:

- App Store/Test Store subscriptions open Apple's subscription management URL
  or RevenueCat's `managementURL` when provided.
- Stripe/web subscriptions open `/api/billing/portal?uid=<purchase_uid>`, which
  redirects to Stripe Billing Portal.

## 8. Best Practices

- Keep all products attached to the `Grocer Pro` entitlement so Annual,
  Quarterly, and Monthly unlock the same app access.
- Keep the purchase UID stable. Do not use the CloudKit member ID or device ID
  as the RevenueCat `appUserID`.
- Use RevenueCat offerings instead of hardcoding price strings or package order.
- Show a restore purchases action; Apple expects users to have a way to recover access.
- Call `customerInfo()` when entering premium areas; RevenueCat caches it, so repeated checks are safe.
- Leave debug logs enabled only in debug builds.
- Do not ship a Test Store API key to production.
- Configure RevenueCat ↔ Stripe dashboard integration before testing web
  checkout entitlement sync.
- Test the full flow with RevenueCat Test Store first, then App Store
  sandbox/TestFlight, Stripe test mode, and production products.
