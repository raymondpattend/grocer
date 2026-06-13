import Foundation

/// Default list name backing every group (the user sees the group, not the list).
/// Mirrors `DEFAULT_LIST_NAME` in packages/shared/src/constants.ts.
let DEFAULT_LIST_NAME = "Groceries"

/// Curated SF Symbols offered when customizing a group.
let GROUP_ICON_CHOICES = [
    "cart.fill", "basket.fill", "bag.fill", "takeoutbag.and.cup.and.straw.fill",
    "fork.knife", "carrot.fill", "fish.fill", "birthday.cake.fill",
    "wineglass.fill", "cup.and.saucer.fill", "house.fill", "pawprint.fill",
    "gift.fill", "leaf.fill", "shippingbox.fill", "heart.fill",
]

/// Preset color themes for a group (raw value persisted in CloudKit).
enum ListColorTheme: String, CaseIterable, Codable, Hashable, Identifiable {
    case green, blue, indigo, purple, pink, red, orange, yellow, teal, mint, brown, gray
    var id: String { rawValue }
    static var `default`: ListColorTheme { .green }
}

// MARK: - Enums
//
// These mirror packages/shared/src/constants.ts. Keep the raw string values in
// sync so the API and Live Activity payloads round-trip cleanly.

enum GroceryCategory: String, CaseIterable, Codable, Identifiable, Hashable {
    case produce = "Produce"
    case meatSeafood = "Meat & Seafood"
    case dairy = "Dairy"
    case frozen = "Frozen"
    case pantry = "Pantry"
    case bakery = "Bakery"
    case drinks = "Drinks"
    case snacks = "Snacks"
    case household = "Household"
    case personalCare = "Personal Care"
    case pet = "Pet"
    case other = "Other"

    var id: String { rawValue }

    /// Stable display order used to group the list.
    static var ordered: [GroceryCategory] { allCases }

    var systemImage: String {
        switch self {
        case .produce: return "leaf"
        case .meatSeafood: return "fish"
        case .dairy: return "drop"
        case .frozen: return "snowflake"
        case .pantry: return "archivebox"
        case .bakery: return "birthday.cake"
        case .drinks: return "cup.and.saucer"
        case .snacks: return "popcorn"
        case .household: return "house"
        case .personalCare: return "comb"
        case .pet: return "pawprint"
        case .other: return "bag"
        }
    }
}

enum ItemPriority: String, CaseIterable, Codable, Hashable, Identifiable {
    case low = "Low"
    case normal = "Normal"
    case high = "High"

    var id: String { rawValue }

    var sortOrder: Int {
        switch self {
        case .high: return 0
        case .normal: return 1
        case .low: return 2
        }
    }
}

enum ItemStatus: String, Codable, Hashable {
    case needed = "Needed"
    case found = "Found"
    case replaced = "Replaced"
    case outOfStock = "Out of Stock"
    case skipped = "Skipped"
    case removed = "Removed"

    /// Items still on the active shopping list.
    var isPending: Bool { self == .needed }
}

enum SessionStatus: String, Codable, Hashable {
    case active = "Active"
    case completed = "Completed"
    case cancelled = "Cancelled"
}

enum MemberRole: String, Codable, Hashable {
    case owner = "Owner"
    case member = "Member"
}

// MARK: - Domain models

/// A group is also the grocery list: it carries the store, icon, and color
/// theme, and holds a single implicit `GroceryList` for its items.
struct Household: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var ownerMemberId: String
    var storeName: String?
    var icon: String
    var colorTheme: ListColorTheme
    var createdAt: Date
    var updatedAt: Date
    var recordZoneName: String?
    var recordOwnerName: String?
}

struct HouseholdMember: Identifiable, Codable, Hashable {
    var id: String
    var householdId: String
    var displayName: String
    var profileImageData: Data?
    var iCloudUserRecordName: String?
    var role: MemberRole
    var joinedAt: Date
    var recordZoneName: String?
    var recordOwnerName: String?
}

/// Internal 1:1 container for a group's items (not surfaced in the UI).
struct GroceryList: Identifiable, Codable, Hashable {
    var id: String
    var householdId: String
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var archived: Bool
}

struct GroceryItem: Identifiable, Codable, Hashable {
    var id: String
    var householdId: String
    var listId: String
    var name: String
    var quantity: String?
    var category: GroceryCategory
    var notes: String?
    var requestedByMemberId: String
    var requestedByDisplayName: String
    var status: ItemStatus
    var priority: ItemPriority
    var replacementPreference: String?
    var replacementItemName: String?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var deletedAt: Date?
    var activeSessionId: String?
}

struct GroceryItemSuggestion: Identifiable, Hashable {
    var name: String
    var quantity: String?
    var category: GroceryCategory
    var isPending: Bool
    var lastUsedAt: Date

    var id: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ShoppingSession: Identifiable, Codable, Hashable {
    var id: String
    var householdId: String
    var listId: String
    var startedByMemberId: String
    var startedByDisplayName: String
    var storeName: String?
    var startedAt: Date
    var endedAt: Date?
    var updatedAt: Date
    var status: SessionStatus
}

/// Immutable snapshot of one item's outcome within one shopping trip, captured
/// when the trip ends. The live `GroceryItem` is reused (and its `activeSessionId`
/// cleared) across trips, so these records are what make a finished trip's
/// contents durably reviewable. `outcome == .needed` means the item was on the
/// list but left unfound. Record name is `"<sessionId>_<itemId>"` so re-capturing
/// a trip upserts rather than duplicates.
struct ShoppingTripItem: Identifiable, Codable, Hashable {
    var id: String
    var householdId: String
    var sessionId: String
    var itemId: String
    var name: String
    var quantity: String?
    var category: GroceryCategory
    var outcome: ItemStatus
    var replacementItemName: String?
    var requestedByMemberId: String
    var requestedByDisplayName: String
    var createdAt: Date

    /// Deterministic record name pairing a trip with one of its items.
    static func recordName(sessionId: String, itemId: String) -> String {
        "\(sessionId)_\(itemId)"
    }
}

enum ItemEventType: String, Codable, Hashable {
    case itemAdded, itemEdited, itemFound, itemReplaced, itemOutOfStock
    case itemSkipped, itemRemoved
    case sessionStarted, sessionCompleted, sessionCancelled
}

struct ItemEvent: Identifiable, Codable, Hashable {
    var id: String
    var householdId: String
    var itemId: String?
    var sessionId: String?
    var type: ItemEventType
    var createdByMemberId: String
    var createdByDisplayName: String
    var createdAt: Date
    var metadata: [String: String]
}

// MARK: - Convenience

private func stableDateOrder(_ lhsDate: Date, _ rhsDate: Date, lhsID: String, rhsID: String) -> Bool {
    if lhsDate != rhsDate { return lhsDate < rhsDate }
    return lhsID < rhsID
}

private func stableRecentDateOrder(_ lhsDate: Date, _ rhsDate: Date, lhsID: String, rhsID: String) -> Bool {
    if lhsDate != rhsDate { return lhsDate > rhsDate }
    return lhsID < rhsID
}

extension Household {
    static func stableDisplayOrder(_ lhs: Household, _ rhs: Household) -> Bool {
        stableDateOrder(lhs.createdAt, rhs.createdAt, lhsID: lhs.id, rhsID: rhs.id)
    }
}

extension HouseholdMember {
    static func stableDisplayOrder(_ lhs: HouseholdMember, _ rhs: HouseholdMember) -> Bool {
        if lhs.joinedAt != rhs.joinedAt { return lhs.joinedAt < rhs.joinedAt }
        let nameComparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
        return lhs.id < rhs.id
    }
}

extension GroceryList {
    static func stableDisplayOrder(_ lhs: GroceryList, _ rhs: GroceryList) -> Bool {
        stableDateOrder(lhs.createdAt, rhs.createdAt, lhsID: lhs.id, rhsID: rhs.id)
    }
}

extension GroceryItem {
    static func listDisplayOrder(_ lhs: GroceryItem, _ rhs: GroceryItem) -> Bool {
        stableDateOrder(lhs.createdAt, rhs.createdAt, lhsID: lhs.id, rhsID: rhs.id)
    }

    static func shoppingPriorityOrder(_ lhs: GroceryItem, _ rhs: GroceryItem) -> Bool {
        if lhs.priority.sortOrder != rhs.priority.sortOrder {
            return lhs.priority.sortOrder < rhs.priority.sortOrder
        }
        return listDisplayOrder(lhs, rhs)
    }

    static func handledDisplayOrder(_ lhs: GroceryItem, _ rhs: GroceryItem) -> Bool {
        stableRecentDateOrder(
            lhs.completedAt ?? lhs.updatedAt,
            rhs.completedAt ?? rhs.updatedAt,
            lhsID: lhs.id,
            rhsID: rhs.id
        )
    }
}

extension ShoppingSession {
    static func stableDisplayOrder(_ lhs: ShoppingSession, _ rhs: ShoppingSession) -> Bool {
        stableDateOrder(lhs.startedAt, rhs.startedAt, lhsID: lhs.id, rhsID: rhs.id)
    }

    /// Most-recent-first ordering for the trip history list.
    static func recentDisplayOrder(_ lhs: ShoppingSession, _ rhs: ShoppingSession) -> Bool {
        stableRecentDateOrder(lhs.startedAt, rhs.startedAt, lhsID: lhs.id, rhsID: rhs.id)
    }
}

extension ShoppingTripItem {
    /// Stable display order within a trip: by category, then name, then id.
    static func tripDisplayOrder(_ lhs: ShoppingTripItem, _ rhs: ShoppingTripItem) -> Bool {
        let lhsCat = GroceryCategory.ordered.firstIndex(of: lhs.category) ?? Int.max
        let rhsCat = GroceryCategory.ordered.firstIndex(of: rhs.category) ?? Int.max
        if lhsCat != rhsCat { return lhsCat < rhsCat }
        let nameComparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
        return lhs.id < rhs.id
    }
}

extension ItemEvent {
    static func stableDisplayOrder(_ lhs: ItemEvent, _ rhs: ItemEvent) -> Bool {
        stableDateOrder(lhs.createdAt, rhs.createdAt, lhsID: lhs.id, rhsID: rhs.id)
    }

    static func recentDisplayOrder(_ lhs: ItemEvent, _ rhs: ItemEvent) -> Bool {
        stableRecentDateOrder(lhs.createdAt, rhs.createdAt, lhsID: lhs.id, rhsID: rhs.id)
    }
}

extension Array where Element == GroceryItem {
    /// Pending items grouped by category in display order.
    func groupedByCategory() -> [(category: GroceryCategory, items: [GroceryItem])] {
        GroceryCategory.ordered.compactMap { category in
            let items = filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }
}
