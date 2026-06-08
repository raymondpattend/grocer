import Foundation

/// Record-type and field-key constants for the CloudKit schema.
///
/// All grocery records live in the **shared** database under a single custom
/// zone ("HouseholdZone") rooted at the Household record, which is the object
/// shared via `CKShare` for family access. Personal settings live in the
/// **private** database default zone.
///
/// See docs/CLOUDKIT.md for the full setup (record types, fields, indexes).
enum CK {
    /// Update this to your real container identifier (and in Grocer.entitlements).
    static let containerIdentifier = "iCloud.org.narro.grocer"

    /// Custom zone holding all shared household data (so it can be shared as a unit).
    static let householdZoneName = "HouseholdZone"

    enum RecordType {
        static let household = "Household"
        static let member = "HouseholdMember"
        static let list = "GroceryList"
        static let item = "GroceryItem"
        static let session = "ShoppingSession"
        static let event = "ItemEvent"
        // Private DB only:
        static let appSettings = "AppSettings"
        static let recentItem = "RecentItem"
    }

    enum Field {
        // Shared across types
        static let householdId = "householdId"
        static let createdAt = "createdAt"
        static let updatedAt = "updatedAt"

        // Household
        static let name = "name"
        static let ownerMemberId = "ownerMemberId"

        // Member
        static let displayName = "displayName"
        static let profileImage = "profileImage"
        static let iCloudUserRecordName = "iCloudUserRecordName"
        static let role = "role"
        static let joinedAt = "joinedAt"

        // Household appearance (group is the list)
        static let icon = "icon"
        static let colorTheme = "colorTheme"
        // (group store reuses the `storeName` key below)

        // List
        static let listName = "name"
        static let archived = "archived"

        // Item
        static let listId = "listId"
        static let itemName = "name"
        static let quantity = "quantity"
        static let category = "category"
        static let notes = "notes"
        static let requestedByMemberId = "requestedByMemberId"
        static let requestedByDisplayName = "requestedByDisplayName"
        static let status = "status"
        static let replacementPreference = "replacementPreference"
        static let replacementItemName = "replacementItemName"
        static let priority = "priority"
        static let completedAt = "completedAt"
        static let deletedAt = "deletedAt"
        static let activeSessionId = "activeSessionId"

        // Session
        static let startedByMemberId = "startedByMemberId"
        static let startedByDisplayName = "startedByDisplayName"
        static let storeName = "storeName"
        static let startedAt = "startedAt"
        static let endedAt = "endedAt"

        // Event
        static let itemId = "itemId"
        static let sessionId = "sessionId"
        static let eventType = "eventType"
        static let createdByMemberId = "createdByMemberId"
        static let createdByDisplayName = "createdByDisplayName"
        static let metadata = "metadata"

        // AppSettings (private)
        static let familyLiveActivitiesEnabled = "familyLiveActivitiesEnabled"
        static let notificationsEnabled = "notificationsEnabled"
        static let memberId = "memberId"
        static let deviceId = "deviceId"
    }
}
