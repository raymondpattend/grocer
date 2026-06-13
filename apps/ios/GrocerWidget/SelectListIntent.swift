import AppIntents
import WidgetKit

/// One grocery list, surfaced as a configurable option in the widget editor.
struct ListEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "List" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static var defaultQuery = ListQuery()
}

/// Supplies the list of choices (and resolves saved selections) from the
/// snapshot the app publishes to the App Group container.
struct ListQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ListEntity] {
        allLists().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ListEntity] {
        allLists()
    }

    func defaultResult() async -> ListEntity? {
        allLists().first
    }

    private func allLists() -> [ListEntity] {
        (WidgetSnapshotStore.load()?.lists ?? []).map { ListEntity(id: $0.id, name: $0.name) }
    }
}

/// Widget configuration: which list to display. Leaving it unset shows the
/// first list.
struct SelectListIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Select List" }
    static var description: IntentDescription {
        IntentDescription("Choose which grocery list to show.")
    }

    @Parameter(title: "List")
    var list: ListEntity?
}
