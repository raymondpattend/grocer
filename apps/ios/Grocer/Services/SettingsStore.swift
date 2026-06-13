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
        displayName = defaults.string(forKey: Keys.displayName) ?? "Me"
        profileImageData = defaults.data(forKey: Keys.profileImageData)
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
}
