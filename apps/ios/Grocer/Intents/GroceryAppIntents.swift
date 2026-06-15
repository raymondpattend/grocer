import AppIntents
import Foundation

// MARK: - Add Grocery Item intent

/// Adds an item to a grocery group.
///
/// Runs **in the background** (no app launch). App Intents execute inside the
/// app's own process, so this reuses ``GroceryRepository`` directly — a Siri /
/// Shortcuts / Spotlight add behaves exactly like an in-app add and syncs to the
/// family through the same CloudKit outbox. See
/// ``GroceryRepository/addItemFromIntent(_:householdId:)``.
///
/// When the user has one list, it is chosen automatically. With multiple lists,
/// Siri / Shortcuts prompt for the list unless the phrase or shortcut already
/// supplies one (e.g. "add to my Home list in Grocer", then Siri asks for the item).
struct AddGroceryItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Grocery Item"
    static let description = IntentDescription(
        "Adds an item to your grocery list.",
        categoryName: "Grocery List"
    )

    /// Hands-free: handle the add without bringing the app to the foreground.
    static let openAppWhenRun = false

    @Parameter(
        title: "Item",
        requestValueDialog: "What would you like to add?"
    )
    var item: GroceryItemNameEntity

    @Parameter(
        title: "List",
        requestValueDialog: "Which list should I add this to?",
        requestDisambiguationDialog: "Which list did you mean?"
    )
    var list: GroceryListEntity?

    static var parameterSummary: some ParameterSummary {
        When(\.$list, .hasAnyValue) {
            Summary("Add \(\.$item) to \(\.$list)")
        } otherwise: {
            Summary("Add \(\.$item) to my grocery list")
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let repo = await GroceryRepository.sharedForIntent()
        let households = await repo.intentHouseholdChoices()
        let householdId: String?
        if let list {
            householdId = list.id
        } else if households.count <= 1 {
            householdId = households.first?.id
        } else {
            throw $list.needsValueError("Which list should I add this to?")
        }

        switch await repo.addItemFromIntent(item.name, householdId: householdId) {
        case let .added(name, list):
            return .result(dialog: "Added \(name) to \(list).")
        case .empty:
            return .result(dialog: "Sorry, I didn't catch what to add.")
        case .noList:
            return .result(dialog: "You don't have a grocery list yet. Open Grocer to create one.")
        }
    }
}

// MARK: - App Shortcuts (zero-config Siri phrases)

/// Registers spoken phrases so users can add an item without any setup.
///
/// Every App Shortcut phrase must contain the app-name token
/// (`\(.applicationName)`), and only **one** entity parameter per phrase. Two
/// shortcuts cover the two natural orderings:
///
/// - **Item first** — "Hey Siri, add milk to Grocer" (list auto-selected or prompted).
/// - **List first** — "Hey Siri, add to my Home list in Grocer" (then prompted for the item).
struct GrocerAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddGroceryItemIntent(),
            phrases: [
                "Add \(\.$item) to \(.applicationName)",
                "Add \(\.$item) to my \(.applicationName) list",
                "Add \(\.$item) to my grocery list in \(.applicationName)",
                "Add an item to \(.applicationName)",
                "Add a grocery item to \(.applicationName)",
                "Add something to my \(.applicationName) list",
                "Add to my \(.applicationName) list",
            ],
            shortTitle: "Add Grocery Item",
            systemImageName: "cart.badge.plus"
        )
        AppShortcut(
            intent: AddGroceryItemIntent(),
            phrases: [
                "Add to my \(\.$list) list in \(.applicationName)",
                "Add to \(\.$list) in \(.applicationName)",
                "Add to my \(\.$list) list with \(.applicationName)",
            ],
            shortTitle: "Add to List",
            systemImageName: "list.bullet"
        )
    }
}

// MARK: - Dictated item entity

/// App Shortcuts can only interpolate `AppEntity` / `AppEnum` parameters in
/// spoken phrases. This entity is intentionally tiny: it lets Siri resolve
/// arbitrary dictated item names, then the repository stores the plain text.
struct GroceryItemNameEntity: AppEntity, Hashable {
    let id: String
    let name: String

    init?(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        self.id = name
        self.name = name
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Grocery Item" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static var defaultQuery = GroceryItemNameQuery()
}

// MARK: - Grocery list entity

/// A household / grocery group, surfaced as an optional App Intent parameter.
/// When the user has multiple lists and does not name one in their phrase,
/// ``AddGroceryItemIntent`` requests a list value via ``IntentParameter/needsValueError(_:)``.
struct GroceryListEntity: AppEntity, Hashable {
    let id: String
    let name: String

    init(household: Household) {
        id = household.id
        name = household.name
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Grocery List" }
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static var defaultQuery = GroceryListQuery()
}

struct GroceryListQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [GroceryListEntity] {
        let repo = await GroceryRepository.sharedForIntent()
        return await repo.intentHouseholdChoices()
            .filter { identifiers.contains($0.id) }
            .map(GroceryListEntity.init)
    }

    func entities(matching string: String) async throws -> [GroceryListEntity] {
        let repo = await GroceryRepository.sharedForIntent()
        let households = await repo.intentHouseholdChoices()
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return households.map(GroceryListEntity.init) }

        return households
            .filter { $0.name.localizedCaseInsensitiveContains(needle) }
            .map(GroceryListEntity.init)
    }

    func suggestedEntities() async throws -> [GroceryListEntity] {
        let repo = await GroceryRepository.sharedForIntent()
        return await repo.intentHouseholdChoices().map(GroceryListEntity.init)
    }

    func defaultResult() async -> GroceryListEntity? {
        let repo = await GroceryRepository.sharedForIntent()
        let households = await repo.intentHouseholdChoices()
        guard households.count == 1, let household = households.first else {
            return nil
        }
        return GroceryListEntity(household: household)
    }
}

struct GroceryItemNameQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [GroceryItemNameEntity] {
        identifiers.compactMap(GroceryItemNameEntity.init)
    }

    func entities(matching string: String) async throws -> [GroceryItemNameEntity] {
        GroceryItemNameEntity(string).map { [$0] } ?? []
    }

    func suggestedEntities() async throws -> [GroceryItemNameEntity] {
        let repo = await GroceryRepository.sharedForIntent()
        let names = await repo.intentItemNameSuggestions()
        return names.compactMap(GroceryItemNameEntity.init)
    }
}

// MARK: - Result of an out-of-app add

/// Outcome of an item-add initiated from outside the app (Siri / App Intents),
/// returned by ``GroceryRepository/addItemFromIntent(_:householdId:)``.
enum IntentAddOutcome: Equatable {
    /// Item landed on `list`; `item` is the cleaned display name.
    case added(item: String, list: String)
    /// The dictated text had no usable item name.
    case empty
    /// No group / list exists yet to add into.
    case noList
}

// MARK: - Dictated-phrase parsing

/// Splits a dictated phrase like "2 bags of potato chips" into a clean item
/// name and an optional quantity string ("2 bag"). Falls back to using the whole
/// phrase as the name. Lives here so the App Intent and any future voice entry
/// points share one parser. Richer parsing (units, categories) is handled
/// downstream by `UnitGuess` / `CategoryGuess`, matching the in-app add path.
struct SiriItemPhrase {
    let name: String
    let quantity: String?

    init(parsing raw: String) {
        var words = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " })
            .map(String.init)

        // Drop a leading article, e.g. "add a potato" / "add some milk".
        if let first = words.first.map({ $0.lowercased() }),
           ["a", "an", "the", "some"].contains(first) {
            words.removeFirst()
        }

        var amount: Double?
        var unit: String?

        // Optional leading number, e.g. "2" or "1.5".
        if let first = words.first, let value = Double(first) {
            amount = value
            words.removeFirst()
            // Optional known unit right after the number, e.g. "2 bags".
            if let next = words.first {
                let singular = next.lowercased().hasSuffix("s")
                    ? String(next.lowercased().dropLast())
                    : next.lowercased()
                if GroceryUnits.all.contains(singular) {
                    unit = singular
                    words.removeFirst()
                }
            }
        }

        // Drop a connecting "of" ("2 bags of chips").
        if words.first?.lowercased() == "of" {
            words.removeFirst()
        }

        let stripped = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        // If stripping left nothing usable, treat the raw text as the name.
        if stripped.isEmpty {
            name = raw.trimmingCharacters(in: .whitespacesAndNewlines).siriTitleCased
            quantity = nil
            return
        }

        name = stripped.siriTitleCased
        if let amount {
            quantity = Quantity(amount: amount, unit: unit ?? "").formatted
        } else {
            quantity = nil
        }
    }
}

private extension String {
    /// Title-cases a dictated item name ("potato chips" -> "Potato Chips"),
    /// mirroring how typed items are capitalized in the add flow.
    var siriTitleCased: String {
        trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
