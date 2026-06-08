import CloudKit
import UIKit
import UserNotifications

/// Bridges UIKit's CloudKit-share acceptance callback into the SwiftUI world.
///
/// When a family member taps an invite link, the system delivers a
/// `CKShare.Metadata` to the app delegate. We hand it to whatever handler the
/// repository registered (set in `GroceryRepository.bootstrap`).
@MainActor
final class ShareCoordinator {
    static let shared = ShareCoordinator()

    /// Set by the repository once it's ready to accept shares.
    private var handler: ((CKShare.Metadata) async -> Void)?

    /// Holds metadata that arrived before a handler was registered (cold launch).
    private var pending: CKShare.Metadata?

    func handle(_ metadata: CKShare.Metadata) {
        if let handler {
            Task { await handler(metadata) }
        } else {
            pending = metadata
        }
    }

    func setHandler(_ handler: @escaping (CKShare.Metadata) async -> Void) {
        self.handler = handler
        if let pending {
            self.pending = nil
            Task { await handler(pending) }
        }
    }
}

/// Registers this device for ordinary APNs alert notifications used for
/// shopping trip start/end messages.
///
/// Token delivery from iOS (`didRegisterForRemoteNotificationsWithDeviceToken`)
/// can arrive before `configure(householdId:memberId:)` is called (common on
/// subsequent launches where the device is already registered). We hold the
/// token and flush the registration as soon as both pieces are available.
@MainActor
final class PushNotificationCoordinator {
    static let shared = PushNotificationCoordinator()

    private let api = APIClient.shared
    private let settings = SettingsStore.shared

    private var householdId: String?
    private var memberId: String?
    private var deviceToken: String?
    /// True once we've called `configure` at least once — prevents silently
    /// skipping registration when the token arrives before configure.
    private var isConfigured: Bool = false
    /// True when a token arrived before configure, so configure can flush it.
    private var hasPendingToken: Bool = false

    func configure(householdId: String, memberId: String) {
        self.householdId = householdId
        self.memberId = memberId
        self.isConfigured = true
        let hadPendingToken = hasPendingToken
        hasPendingToken = false

        Task {
            await syncRegistration(
                requestAuthorizationIfNeeded: settings.notificationsEnabled,
                forceRegisterForRemoteNotifications: true,
                logContext: hadPendingToken ? "configure+pending-token" : "configure"
            )
        }
    }

    func notificationPreferenceChanged() {
        Task {
            await syncRegistration(
                requestAuthorizationIfNeeded: settings.notificationsEnabled,
                logContext: "preference-changed"
            )
        }
    }

    func handleRemoteNotificationToken(_ token: String) {
        let previousToken = deviceToken
        deviceToken = token

        guard isConfigured else {
            hasPendingToken = true
            print("[Notifications] token received before configure — queued for later (\(token.prefix(8))…)")
            return
        }

        if previousToken != token {
            print("[Notifications] device token updated (\(token.prefix(8))…)")
        }

        Task {
            await syncRegistration(
                requestAuthorizationIfNeeded: false,
                forceRegisterForRemoteNotifications: false,
                logContext: "token-callback"
            )
        }
    }

    func handleRemoteNotificationRegistrationFailure(_ error: Error) {
        print("[Notifications] remote registration failed: \(error)")
    }

    private func syncRegistration(
        requestAuthorizationIfNeeded: Bool,
        forceRegisterForRemoteNotifications: Bool = true,
        logContext: String = ""
    ) async {
        guard let householdId, let memberId else {
            print("[Notifications] syncRegistration(\(logContext)) skipped — not configured")
            return
        }

        let allowed = settings.notificationsEnabled
            ? await notificationsAllowed(requestAuthorizationIfNeeded: requestAuthorizationIfNeeded)
            : false

        if allowed && forceRegisterForRemoteNotifications {
            UIApplication.shared.registerForRemoteNotifications()
        }

        let tokenToSend = allowed ? deviceToken : nil
        print("[Notifications] syncRegistration(\(logContext)): allowed=\(allowed), hasToken=\(tokenToSend != nil), household=\(householdId.prefix(8))…")

        await api.registerPushToStart(
            RegisterTokenPayload(
                householdId: householdId,
                memberId: memberId,
                deviceId: settings.deviceId,
                pushToStartToken: nil,
                pushNotificationToken: tokenToSend,
                familyLiveActivitiesEnabled: settings.familyLiveActivitiesEnabled,
                notificationsEnabled: allowed,
                appVersion: settings.appVersion
            )
        )
    }

    private func notificationsAllowed(requestAuthorizationIfNeeded: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined where requestAuthorizationIfNeeded:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                print("[Notifications] authorization failed: \(error)")
                return false
            }
        default:
            print("[Notifications] authorization status: \(settings.authorizationStatus.rawValue)")
            return false
        }
    }
}

/// App delegate receives APNs registration events and wires up the scene
/// delegate that handles CloudKit share acceptance.
///
/// Note: in a SwiftUI (scene-based) app, iOS delivers CloudKit share
/// acceptance to `UIWindowSceneDelegate.windowScene(_:userDidAcceptCloudKitShareWith:)`,
/// **not** to `UIApplicationDelegate.application(_:userDidAcceptCloudKitShareWith:)`.
/// The latter is only invoked for pre-scene apps and silently never fires here,
/// which is why tapping "Join" on an invite link did nothing. We therefore
/// provide a scene delegate (see `ShareSceneDelegate`) for that callback.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ShareSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushNotificationCoordinator.shared.handleRemoteNotificationToken(deviceToken.hexString)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            PushNotificationCoordinator.shared.handleRemoteNotificationRegistrationFailure(error)
        }
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await GroceryRepository.current?.handleRemoteNotification()
            completionHandler(.newData)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Scene delegate whose sole job is to receive CloudKit share acceptance.
///
/// We deliberately do not implement `scene(_:willConnectTo:)` or create a
/// window — SwiftUI's `WindowGroup` continues to manage the UI. Adding this
/// delegate only opts us into the scene-level CloudKit callback, which is the
/// one iOS actually delivers for SwiftUI apps. On a cold launch from an invite
/// link the metadata is also surfaced via the connection options, so we handle
/// both paths and let `ShareCoordinator` buffer until the repository is ready.
final class ShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { @MainActor in
                ShareCoordinator.shared.handle(metadata)
            }
        }
    }

    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in
            ShareCoordinator.shared.handle(cloudKitShareMetadata)
        }
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
