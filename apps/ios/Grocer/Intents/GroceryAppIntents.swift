import AppIntents
import Foundation

// MARK: - Add Grocery Item intent

/// Adds an item to the user's currently selected grocery group.
///
/// Runs **in the background** (no app launch). App Intents execute inside the
/// app's own process, so this reuses ``GroceryRepository`` directly — a Siri /
/// Shortcuts / Spotlight add behaves exactly like an in-app add and syncs to the
/// family through the same CloudKit outbox. See
/// ``GroceryRepository/addItemFromIntent(_:)``.
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

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$item) to my grocery list")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let repo = await GroceryRepository.sharedForIntent()
        switch await repo.addItemFromIntent(item.name) {
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
/// (`\(.applicationName)`). Siri phrase parameters have to be entities/enums, so
/// `GroceryItemNameEntity` is a lightweight wrapper around dictated text. This
/// lets "Hey Siri, add milk to Grocer" run in one step while still supporting
/// the prompt-based fallback "add an item to Grocer".
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
/// returned by ``GroceryRepository/addItemFromIntent(_:)``.
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
