#if DEBUG
import SwiftUI

@MainActor
enum GrocerPreview {
    static var repository: GroceryRepository {
        GroceryRepository.makePreview()
    }

    static func repository(
        households: [Household] = [],
        members: [HouseholdMember] = [],
        lists: [GroceryList] = [],
        items: [GroceryItem] = [],
        joinedHouseholdId: String? = nil
    ) -> GroceryRepository {
        GroceryRepository.makePreview(
            households: households,
            members: members,
            lists: lists,
            items: items,
            joinedHouseholdId: joinedHouseholdId
        )
    }

    static var settings: SettingsStore {
        SettingsStore.shared
    }

    static var subscriptions: SubscriptionStore {
        SubscriptionStore.shared
    }
}

@MainActor
extension View {
    func grocerPreviewEnvironment() -> some View {
        grocerPreviewEnvironment(repository: GrocerPreview.repository)
    }

    func grocerPreviewEnvironment(repository: GroceryRepository) -> some View {
        environment(repository)
            .environment(GrocerPreview.settings)
            .environment(GrocerPreview.subscriptions)
    }
}
#endif
