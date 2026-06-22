import Foundation

@MainActor
final class GroupNavigationCoordinator {
    static let shared = GroupNavigationCoordinator()
    static let openGroupNotification = Notification.Name("org.narro.grocer.openGroup")
    static let householdIdUserInfoKey = "householdId"

    private var pendingHouseholdIds: [String] = []
    /// Groups that should open their Add Items modal once their list is on
    /// screen (set when opened via the widget's Add button). Consumed by
    /// `GroceryListView` when it becomes current.
    private var pendingAddHouseholdIds: Set<String> = []

    private init() {}

    func openGroup(householdId: String, showAdd: Bool = false) {
        let trimmed = householdId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pendingHouseholdIds.append(trimmed)
        if showAdd { pendingAddHouseholdIds.insert(trimmed) }
        NotificationCenter.default.post(
            name: Self.openGroupNotification,
            object: nil,
            userInfo: [Self.householdIdUserInfoKey: trimmed]
        )
    }

    func consumePendingHouseholdIds() -> [String] {
        let ids = pendingHouseholdIds
        pendingHouseholdIds.removeAll()
        return ids
    }

    /// Returns (and clears) whether the given group was asked to open its Add
    /// Items modal. One-shot per request.
    func consumePendingAdd(for householdId: String) -> Bool {
        let trimmed = householdId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pendingAddHouseholdIds.contains(trimmed) else { return false }
        pendingAddHouseholdIds.remove(trimmed)
        return true
    }
}
