import Foundation

@MainActor
final class GroupNavigationCoordinator {
    static let shared = GroupNavigationCoordinator()
    static let openGroupNotification = Notification.Name("org.narro.grocer.openGroup")
    static let householdIdUserInfoKey = "householdId"

    private var pendingHouseholdIds: [String] = []

    private init() {}

    func openGroup(householdId: String) {
        let trimmed = householdId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pendingHouseholdIds.append(trimmed)
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
}
