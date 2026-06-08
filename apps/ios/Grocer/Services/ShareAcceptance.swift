import AVFoundation
import CloudKit
import UIKit
import UserNotifications

private let shoppingTripItemAddedNotificationKind = "shoppingTripItemAdded"

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
/// can arrive before `configure(householdMemberships:)` is called (common on
/// subsequent launches where the device is already registered). We hold the
/// token and flush the registration as soon as both pieces are available.
@MainActor
final class PushNotificationCoordinator {
    static let shared = PushNotificationCoordinator()

    private let api = APIClient.shared
    private let settings = SettingsStore.shared

    private var memberIdsByHouseholdId: [String: String] = [:]
    private var deviceToken: String?
    /// True once we've called `configure` at least once — prevents silently
    /// skipping registration when the token arrives before configure.
    private var isConfigured: Bool = false
    /// True when a token arrived before configure, so configure can flush it.
    private var hasPendingToken: Bool = false

    func configure(householdId: String, memberId: String) {
        configure(householdMemberships: [householdId: memberId])
    }

    func configure(householdMemberships: [String: String]) {
        let removedMemberships = memberIdsByHouseholdId.filter { householdMemberships[$0.key] == nil }
        let changed = memberIdsByHouseholdId != householdMemberships
        self.memberIdsByHouseholdId = householdMemberships
        self.isConfigured = true
        let hadPendingToken = hasPendingToken
        hasPendingToken = false

        guard changed || hadPendingToken else { return }
        Task { [removedMemberships] in
            await unregisterNotifications(for: removedMemberships)
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
        let memberships = memberIdsByHouseholdId
        guard !memberships.isEmpty else {
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
        print("[Notifications] syncRegistration(\(logContext)): allowed=\(allowed), hasToken=\(tokenToSend != nil), households=\(memberships.count)")

        for (householdId, memberId) in memberships {
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
    }

    private func unregisterNotifications(for memberships: [String: String]) async {
        for (householdId, memberId) in memberships {
            await api.registerPushToStart(
                RegisterTokenPayload(
                    householdId: householdId,
                    memberId: memberId,
                    deviceId: settings.deviceId,
                    pushToStartToken: nil,
                    pushNotificationToken: nil,
                    familyLiveActivitiesEnabled: false,
                    notificationsEnabled: false,
                    appVersion: settings.appVersion
                )
            )
        }
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

/// Alerts the active shopper when someone else adds an item during their trip.
///
/// Foreground alerts are intentionally sound-only and use an ambient audio
/// session so the hardware silent switch still mutes them. Background alerts use
/// a local notification because CloudKit sync arrives through a silent push.
@MainActor
final class ShoppingTripItemAddedAlertCoordinator: NSObject, AVAudioPlayerDelegate {
    static let shared = ShoppingTripItemAddedAlertCoordinator()

    private let settings = SettingsStore.shared
    private lazy var chimeData = Self.makeChimeWAV()
    private var activePlayers: [AVAudioPlayer] = []

    func alert(item: GroceryItem, session: ShoppingSession) {
        guard settings.notificationsEnabled else { return }

        if UIApplication.shared.applicationState == .active {
            playForegroundSound()
        } else {
            scheduleNotification(item: item, session: session)
        }
    }

    private func playForegroundSound() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true, options: [])

            let player = try AVAudioPlayer(data: chimeData)
            player.delegate = self
            player.volume = 0.75
            player.prepareToPlay()
            activePlayers.append(player)
            player.play()
        } catch {
            print("[TripItemAlert] foreground sound failed: \(error)")
        }
    }

    private func scheduleNotification(item: GroceryItem, session: ShoppingSession) {
        Task {
            let center = UNUserNotificationCenter.current()
            let notificationSettings = await center.notificationSettings()
            guard Self.canDeliverNotifications(notificationSettings.authorizationStatus) else {
                print("[TripItemAlert] notification skipped; authorization=\(notificationSettings.authorizationStatus.rawValue)")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Added to your trip"
            content.body = "\(item.requestedByDisplayName.trimmedNonEmpty ?? "Someone") added \(itemDisplayName(item)) to your shopping trip."
            content.sound = .default
            content.threadIdentifier = "shopping-trip-\(session.householdId)"
            content.userInfo = [
                "kind": shoppingTripItemAddedNotificationKind,
                "householdId": session.householdId,
                "sessionId": session.id,
                "itemId": item.id,
            ]

            let request = UNNotificationRequest(
                identifier: "shopping-trip-item-added-\(item.id)",
                content: content,
                trigger: nil
            )

            do {
                try await center.add(request)
            } catch {
                print("[TripItemAlert] notification failed: \(error)")
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            activePlayers.removeAll { $0 === player }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            activePlayers.removeAll { $0 === player }
        }
    }

    private static func canDeliverNotifications(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    private func itemDisplayName(_ item: GroceryItem) -> String {
        let name = item.name.trimmedNonEmpty ?? "an item"
        guard let quantity = item.quantity?.trimmedNonEmpty else { return name }
        return "\(quantity) \(name)"
    }

    private static func makeChimeWAV() -> Data {
        let sampleRate = 44_100
        let duration = 0.34
        let sampleCount = Int(Double(sampleRate) * duration)
        var pcm = Data(capacity: sampleCount * 2)

        for index in 0..<sampleCount {
            let t = Double(index) / Double(sampleRate)
            let attack = min(t / 0.025, 1)
            let release = min((duration - t) / 0.14, 1)
            let envelope = max(0, min(attack, release))
            let tone = (sin(2 * .pi * 880 * t) * 0.65) + (sin(2 * .pi * 1_320 * t) * 0.35)
            let clamped = max(-1, min(1, tone * envelope * 0.45))
            pcm.appendLittleEndian(Int16(clamped * Double(Int16.max)))
        }

        let byteRate = UInt32(sampleRate * 2)
        let blockAlign: UInt16 = 2
        var wav = Data()
        wav.append(Data("RIFF".utf8))
        wav.appendLittleEndian(UInt32(36 + pcm.count))
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(byteRate)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(UInt16(16))
        wav.append(Data("data".utf8))
        wav.appendLittleEndian(UInt32(pcm.count))
        wav.append(pcm)
        return wav
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
        if notification.request.content.userInfo["kind"] as? String == shoppingTripItemAddedNotificationKind {
            completionHandler([.sound])
            return
        }

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

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
