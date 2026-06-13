# RevenueCat Setup

Grocer integrates RevenueCat through Swift Package Manager and uses the hosted RevenueCat Paywall plus Customer Center.

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

Configuration lives in `Grocer/Services/SubscriptionStore.swift`:

```swift
enum RevenueCatConfig {
    static let apiKey = "test_tSaSOTwPRseDzLdzjuGNqrnTOSb"
    static let grocerProEntitlementID = "grocer_pro"

    static func configure() {
        #if DEBUG
        Purchases.logLevel = .debug
        #endif

        Purchases.configure(withAPIKey: apiKey)
    }
}
```

`GrocerApp` calls `RevenueCatConfig.configure()` once during startup and injects `SubscriptionStore.shared` into SwiftUI.

The current key is a RevenueCat Test Store key. Before App Store release, replace it with the public Apple app SDK key from RevenueCat.

## 3. Dashboard Product Setup

Create one entitlement:

| Display name | Identifier |
| --- | --- |
| Grocer Pro | `grocer_pro` |

Configure products:

| Product | Identifier | Type | Entitlement |
| --- | --- | --- | --- |
| Lifetime | `lifetime` | Non-consumable | `grocer_pro` |
| Yearly | `yearly` | Auto-renewable subscription | `grocer_pro` |
| Monthly | `monthly` | Auto-renewable subscription | `grocer_pro` |

Create an offering, make it the default/current offering, and add packages:

| Package | Product |
| --- | --- |
| Lifetime | `lifetime` |
| Annual | `yearly` |
| Monthly | `monthly` |

Then create and attach a RevenueCat Paywall to that offering. Grocer presents `PaywallView`, so the dashboard paywall controls the product order, copy, trials, experiments, and styling.

## 4. Entitlement Checking

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

## 5. Purchases, Restores, And Customer Info

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

The Settings screen already exposes hosted paywall purchase, restore, and Customer Center actions.

## 6. Customer Center

Customer Center makes sense once the app needs purchase management, cancellation guidance, refunds, win-back/promotional flows, or support actions inside the app. Grocer presents it from Settings using `CustomerCenterView`.

Configure Customer Center in the RevenueCat dashboard before release so the hosted screen knows which support and management options to show.

## 7. Best Practices

- Keep all products attached to the `grocer_pro` entitlement so Lifetime, Yearly, and Monthly unlock the same app access.
- Use RevenueCat offerings and paywalls instead of hardcoding price strings or package order.
- Show a restore purchases action; Apple expects users to have a way to recover access.
- Call `customerInfo()` when entering premium areas; RevenueCat caches it, so repeated checks are safe.
- Leave debug logs enabled only in debug builds.
- Do not ship a Test Store API key to production.
- Test the full flow with RevenueCat Test Store first, then App Store sandbox/TestFlight, then production products.
