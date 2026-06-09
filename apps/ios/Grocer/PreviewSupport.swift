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
        joinedHouseholdId: String? = nil
    ) -> GroceryRepository {
        GroceryRepository.makePreview(
            households: households,
            members: members,
            joinedHouseholdId: joinedHouseholdId
        )
    }

    static var settings: SettingsStore {
        SettingsStore.shared
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
    }
}
#endif
