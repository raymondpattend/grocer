import Foundation
import Observation

/// Personal, device-local settings backed by UserDefaults. In a fuller build
/// these would also sync to the user's CloudKit **private** database
/// (AppSettings record); UserDefaults is the MVP cache and is authoritative
/// for device-specific values like the generated deviceId.
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults = GrocerAppGroup.defaults

    private enum Keys {
        static let deviceId = "grocer.deviceId"
        static let familyLiveActivities = "grocer.familyLiveActivitiesEnabled"
        static let notifications = "grocer.notificationsEnabled"
        static let displayName = "grocer.displayName"
        static let profileImageData = "grocer.profileImageData"
        static let memberId = "grocer.memberId"
        static let selectedHouseholdId = "grocer.selectedHouseholdId"
        static let lastHeartbeatAt = "grocer.lastHeartbeatAt"
    }

    /// Stable per-install device identifier used for token registration.
    let deviceId: String

    var familyLiveActivitiesEnabled: Bool {
        didSet { defaults.set(familyLiveActivitiesEnabled, forKey: Keys.familyLiveActivities) }
    }

    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    /// Local display name used until the CloudKit member record resolves.
    var displayName: String {
        didSet { defaults.set(displayName, forKey: Keys.displayName) }
    }

    /// Local cache for the profile image synced on the shared member record.
    var profileImageData: Data? {
        didSet {
            if let profileImageData {
                defaults.set(profileImageData, forKey: Keys.profileImageData)
            } else {
                defaults.removeObject(forKey: Keys.profileImageData)
            }
        }
    }

    init() {
        if let existing = defaults.string(forKey: Keys.deviceId) {
            deviceId = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Keys.deviceId)
            deviceId = generated
        }

        // Default Live Activities ON (the spec defaults the shopper ON; other
        // members opt in — they can toggle this here).
        familyLiveActivitiesEnabled = defaults.object(forKey: Keys.familyLiveActivities) as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: Keys.notifications) as? Bool ?? true
        displayName = defaults.string(forKey: Keys.displayName) ?? String(localized: "Me")
        profileImageData = defaults.data(forKey: Keys.profileImageData)
    }

    /// CloudKit user record name for this member, resolved from the iCloud
    /// account on first sync. Empty until then — use `memberIdOrDevice` for a
    /// stable identifier that falls back to the deviceId.
    var memberId: String {
        get { defaults.string(forKey: Keys.memberId) ?? "" }
        set { defaults.set(newValue, forKey: Keys.memberId) }
    }

    /// Stable identifier for this member: the resolved `memberId` when known,
    /// otherwise the device id.
    var memberIdOrDevice: String { memberId.isEmpty ? deviceId : memberId }

    /// Last-selected group, restored on launch.
    var selectedHouseholdId: String {
        get { defaults.string(forKey: Keys.selectedHouseholdId) ?? "" }
        set { defaults.set(newValue, forKey: Keys.selectedHouseholdId) }
    }

    /// When the retention foreground heartbeat last fired. Used to debounce it
    /// to roughly once per hour so we don't POST on every quick app switch.
    var lastHeartbeatAt: Date? {
        get { defaults.object(forKey: Keys.lastHeartbeatAt) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastHeartbeatAt) }
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}
