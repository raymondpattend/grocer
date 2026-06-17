import PostHog
import Sentry
import SwiftUI

/// PostHog client config baked into the app at build time (Info.plist) so
/// TestFlight / App Store builds don't depend on Xcode scheme env vars.
enum PostHogConfiguration {
    static var projectToken: String? { bundledOrEnvironmentValue(infoKey: "GRPostHogProjectToken", envKey: "POSTHOG_PROJECT_TOKEN") }
    static var host: String? { bundledOrEnvironmentValue(infoKey: "GRPostHogHost", envKey: "POSTHOG_HOST") }
    static var isConfigured: Bool { projectToken != nil && host != nil }

    static func configureIfAvailable() {
        guard let projectToken, let host else {
            #if DEBUG
            print("[PostHog] skipped — set GRPostHogProjectToken / GRPostHogHost in build settings")
            #endif
            return
        }

        let posthogConfig = PostHogConfig(apiKey: projectToken, host: host)
        posthogConfig.captureApplicationLifecycleEvents = true
        #if DEBUG
        posthogConfig.debug = true
        #endif
        PostHogSDK.shared.setup(posthogConfig)
    }

    private static func bundledOrEnvironmentValue(infoKey: String, envKey: String) -> String? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)
            ?? ProcessInfo.processInfo.environment[envKey]
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

@main
struct GrocerApp: App {
    init() {
        // Capture stdout/stderr first so the [CK]/[RevenueCat]/etc. launch
        // traces are available in the shake-to-debug screen.
        LogStore.shared.startCapturing()

        PostHogConfiguration.configureIfAvailable()

        SentrySDK.start { options in
            options.dsn = "https://3444d42645e3a89a270d01620ede8e46@o4510745096749056.ingest.us.sentry.io/4511527562706944"

            // Adds IP for users.
            // For more information, visit: https://docs.sentry.io/platforms/apple/data-management/data-collected/
            options.sendDefaultPii = true

            // Sample a fraction of transactions for performance monitoring to keep overhead low.
            options.tracesSampleRate = 0.1

            // Configure profiling. Visit https://docs.sentry.io/platforms/apple/profiling/ to learn more.
            options.configureProfiling = {
                $0.sessionSampleRate = 0.1 // Profile only a fraction of sessions to avoid UI lag.
                $0.lifecycle = .trace
            }

            // Uncomment the following lines to add more data to your events
            // options.attachScreenshot = true // This adds a screenshot to the error events
            // options.attachViewHierarchy = true // This adds the view hierarchy to the error events
            
            // Disable Session Replay.
            options.sessionReplay.sessionSampleRate = 0.0
            options.sessionReplay.onErrorSampleRate = 0.0
        }
    }
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var repository = GroceryRepository.makeShared()
    @State private var settings = SettingsStore.shared
    @State private var subscriptions = SubscriptionStore.shared
    @State private var appUpdateGate = AppUpdateGate.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(repository)
                .environment(settings)
                .environment(subscriptions)
                .environment(appUpdateGate)
                .preferredColorScheme(settings.appearance.colorScheme)
                .task {
                    await subscriptions.start()
                    await repository.bootstrap()
                    if PostHogConfiguration.isConfigured {
                        let memberId = settings.memberIdOrDevice
                        PostHogSDK.shared.identify(memberId, userProperties: [
                            "display_name": repository.displayName,
                        ])
                    }
                }
        }
    }
}
