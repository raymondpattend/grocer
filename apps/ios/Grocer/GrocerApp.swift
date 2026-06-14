import SwiftUI
import Sentry


@main
struct GrocerApp: App {
    init() {
        // Capture stdout/stderr first so the [CK]/[RevenueCat]/etc. launch
        // traces are available in the shake-to-debug screen.
        LogStore.shared.startCapturing()

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

        RevenueCatConfig.configure()
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
                .task {
                    subscriptions.start()
                    await repository.bootstrap()
                }
        }
    }
}
