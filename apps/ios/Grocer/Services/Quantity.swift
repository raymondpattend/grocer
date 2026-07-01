import SwiftUI

/// Splits a free-form quantity string into a numeric amount and a unit label,
/// and reformats them back. The stored model keeps a single `quantity` string
/// (e.g. "2 dozen") so there's no schema change — this type only mediates the
/// stepper / unit-picker UI. Mirrors the API's amount + unit concept.
struct Quantity: Equatable {
    var amount: Double?
    var unit: String

    init(amount: Double? = nil, unit: String = "") {
        self.amount = amount
        self.unit = unit.trimmingCharacters(in: .whitespaces)
    }

    /// Parse "2 dozen", "1.5 lb", "3", "dozen", "" into amount + unit.
    init(parsing raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            self.init()
            return
        }

        // Pull a leading number (integer or decimal); the remainder is the unit.
        var index = trimmed.startIndex
        var digits = ""
        while index < trimmed.endIndex, trimmed[index].isNumber || trimmed[index] == "." {
            digits.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        let rest = trimmed[index...].trimmingCharacters(in: .whitespaces)
        self.init(amount: Double(digits), unit: rest)
    }

    /// Recombine into a single string, e.g. "1.5 lb", "2 dozen", "3", or "".
    var formatted: String {
        formatted(unit: unit)
    }

    /// Like `formatted`, but inflects the unit to match the amount for display —
    /// "2 bunches", "1 jar", "3 boxes". Storage stays singular (use `formatted`);
    /// this is only for labels and lists shown to the user.
    var displayFormatted: String {
        formatted(unit: GroceryUnits.form(unit, for: amount))
    }

    private func formatted(unit: String) -> String {
        let amountText = amount.map(Quantity.formatAmount) ?? ""
        let unitText = unit.trimmingCharacters(in: .whitespaces)
        switch (amountText.isEmpty, unitText.isEmpty) {
        case (true, true): return ""
        case (false, true): return amountText
        case (true, false): return unitText
        case (false, false): return "\(amountText) \(unitText)"
        }
    }

    /// Reformat a raw stored quantity string for display, inflecting the unit for
    /// its amount ("2 bunch" → "2 bunches"). Leaves a blank string blank.
    static func displayString(_ raw: String) -> String {
        Quantity(parsing: raw).displayFormatted
    }

    /// Shopping-mode display: prefixes a numeric amount with a multiplier "x" so
    /// counts read as "50x bunches". Falls back to the plain display when there's
    /// no leading number ("dozen" stays "dozen", "1 jar" stays "1x jar").
    var shoppingDisplayFormatted: String {
        guard let amount else { return displayFormatted }
        let amountText = "\(Quantity.formatAmount(amount))x"
        let unitText = GroceryUnits.form(unit, for: amount)
        return unitText.isEmpty ? amountText : "\(amountText) \(unitText)"
    }

    /// `shoppingDisplayFormatted` from a raw stored quantity string.
    static func shoppingDisplayString(_ raw: String) -> String {
        Quantity(parsing: raw).shoppingDisplayFormatted
    }

    /// Merges two free-form quantity strings for the same item into one, summing
    /// their numeric amounts — e.g. "10" + "5" → "15", "1 dozen" + "1 dozen" →
    /// "2 dozen". Used when an item is added whose name already matches one on
    /// the list, so the amounts combine instead of creating a duplicate row.
    ///
    /// Units are reconciled best-effort: a shared unit (or one supplied by only
    /// one side) is kept. In the rare case the two carry genuinely different
    /// units, the existing side's unit is kept while the amounts are still summed
    /// into the single surviving row. Returns `nil` when neither side has any
    /// quantity at all.
    static func merged(_ existing: String?, _ incoming: String?) -> String? {
        let lhs = Quantity(parsing: existing ?? "")
        let rhs = Quantity(parsing: incoming ?? "")

        let unit = lhs.unit.isEmpty ? rhs.unit : lhs.unit
        let amount: Double?
        switch (lhs.amount, rhs.amount) {
        case let (l?, r?): amount = l + r
        case let (l?, nil): amount = l
        case let (nil, r?): amount = r
        case (nil, nil): amount = nil
        }

        let result = Quantity(amount: amount, unit: unit).formatted
        return result.isEmpty ? nil : result
    }

    /// Drop a trailing ".0" so whole numbers read as "2" not "2.0".
    static func formatAmount(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e9 {
            return String(Int(value))
        }
        return String(format: "%g", value)
    }
}

/// Curated palette of grocery units offered in the unit picker. The unit is
/// free-form (users can enter a custom one), so this is a convenience list, not
/// a constraint. Mirrors `GROCERY_UNITS` in packages/shared/src/constants.ts.
enum GroceryUnits {
    static let all = [
        "each", "dozen", "pack", "bunch", "bag", "box", "can", "bottle", "jar",
        "loaf", "lb", "oz", "gallon", "quart", "liter", "ml", "g", "kg",
    ]

    /// Weight/volume units step by halves; countable units step by one.
    private static let fractionalUnits: Set<String> = ["lb", "oz", "g", "kg", "liter", "ml"]

    static func step(for unit: String) -> Double {
        fractionalUnits.contains(unit.lowercased()) ? 0.5 : 1
    }

    /// The most of a countable item we'll add at once before clamping. Weight
    /// units are exempt (see `cappedAmount`) — 1500 lb of cement is reasonable,
    /// but 1500 cartons of milk is almost always a typo.
    static let maxCountableAmount: Double = 999

    /// Weight units, which bypass the `maxCountableAmount` cap — you really can buy
    /// 1500 lb of something. Everything else (counts and volume) is capped, but the
    /// shopper is always offered the chance to keep their original number.
    private static let weightUnits: Set<String> = ["lb", "oz", "g", "kg"]

    static func isWeightUnit(_ unit: String) -> Bool {
        weightUnits.contains(unit.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Clamp a countable amount to `maxCountableAmount`; weight amounts pass
    /// through unchanged.
    static func cappedAmount(_ amount: Double, unit: String) -> Double {
        isWeightUnit(unit) ? amount : min(amount, maxCountableAmount)
    }

    /// Units that read the same regardless of count — abbreviations and collective
    /// measures ("2 lb", "2 dozen", not "2 lbs" / "2 dozens").
    private static let invariableUnits: Set<String> = [
        "each", "dozen", "lb", "oz", "ml", "g", "kg",
    ]

    /// English plural of a unit ("bunch" → "bunches", "box" → "boxes", "loaf" →
    /// "loaves"). Abbreviations and collective units are left untouched. Custom
    /// units fall through to the standard rules.
    static func pluralized(_ unit: String) -> String {
        let trimmed = unit.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        let lower = trimmed.lowercased()
        if invariableUnits.contains(lower) { return trimmed }

        if lower.hasSuffix("fe") {
            return String(trimmed.dropLast(2)) + "ves"      // knife → knives
        }
        if lower.hasSuffix("f") {
            return String(trimmed.dropLast()) + "ves"       // loaf → loaves
        }
        if lower.hasSuffix("y"), let secondLast = lower.dropLast().last,
           !"aeiou".contains(secondLast) {
            return String(trimmed.dropLast()) + "ies"       // berry → berries
        }
        // A word already ending in a single "s" ("packs", "sticks", "cans") is
        // almost always a custom unit the user already pluralized — leave it be
        // rather than producing "packses". Only true sibilant singulars get "es".
        if lower.hasSuffix("s") {
            return lower.hasSuffix("ss") ? trimmed + "es" : trimmed  // glass → glasses, packs → packs
        }
        if lower.hasSuffix("x") || lower.hasSuffix("z")
            || lower.hasSuffix("ch") || lower.hasSuffix("sh") {
            return trimmed + "es"                            // bunch → bunches, box → boxes
        }
        return trimmed + "s"
    }

    /// The unit form matching `amount` — singular for exactly one (or no amount),
    /// plural otherwise.
    static func form(_ unit: String, for amount: Double?) -> String {
        guard let amount, amount != 1 else { return unit }
        return pluralized(unit)
    }
}

/// On-device unit guesser so the app proposes units fully offline. The API's
/// `/suggestions` and `/parse-list` provide richer results when online; this is
/// the always-available fallback, mirroring `guessUnit` in the API.
/// See also [CategoryGuess].
enum UnitGuess {
    private static let keywords: [(String, [String])] = [
        ("dozen", ["egg"]),
        ("gallon", ["milk", "juice", "lemonade"]),
        ("bunch", ["banana", "grape", "kale", "cilantro", "parsley", "herb", "asparagus", "scallion"]),
        ("loaf", ["bread", "baguette", "sourdough"]),
        ("lb", ["beef", "steak", "pork", "chicken", "turkey", "fish", "salmon", "tuna", "shrimp", "meat", "cheese", "deli", "apple", "potato", "tomato", "carrot"]),
        ("bottle", ["oil", "vinegar", "wine", "ketchup", "syrup", "shampoo", "conditioner"]),
        ("jar", ["jam", "jelly", "sauce", "salsa", "honey", "pickle", "peanut butter"]),
        ("can", ["soup", "canned", "bean"]),
        ("box", ["cereal", "pasta", "cracker", "tissue", "cake mix", "granola"]),
        ("bag", ["chip", "rice", "flour", "sugar", "frozen", "coffee", "litter", "dog food", "cat food", "salad", "spinach"]),
        ("pack", ["soda", "beer", "yogurt", "bacon", "paper towel", "toilet paper", "bagel", "tortilla", "battery", "gum", "water", "seltzer"]),
    ]

    static func guess(for name: String) -> String {
        let n = name.lowercased()
        for (unit, terms) in keywords where terms.contains(where: { n.contains($0) }) {
            return unit
        }
        return ""
    }
}
