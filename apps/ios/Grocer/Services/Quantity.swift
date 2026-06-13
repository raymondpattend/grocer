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
        let amountText = amount.map(Quantity.formatAmount) ?? ""
        let unitText = unit.trimmingCharacters(in: .whitespaces)
        switch (amountText.isEmpty, unitText.isEmpty) {
        case (true, true): return ""
        case (false, true): return amountText
        case (true, false): return unitText
        case (false, false): return "\(amountText) \(unitText)"
        }
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

// MARK: - Quantity stepper control

/// The shared minus / amount / plus capsule used by every quantity stepper in
/// the app (add-item, history "add again", and the item detail page). The amount
/// animates with iOS's numeric content transition when callers mutate the value
/// inside a `withAnimation` block. The control is purely presentational — it
/// owns no state, so each call site keeps whatever zero / unit behaviour it
/// needs.
struct QuantityStepperControl: View {
    /// Pre-formatted text shown between the buttons (e.g. "2", "1.5", "2 lb").
    let amount: String
    /// Spoken value for VoiceOver; defaults to `amount` when omitted.
    var accessibilityValue: String? = nil
    var onDecrement: () -> Void
    var onIncrement: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            stepButton(systemImage: "minus", action: onDecrement)
            Text(amount)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                .frame(minWidth: 30)
            stepButton(systemImage: "plus", action: onIncrement)
        }
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quantity")
        .accessibilityValue(accessibilityValue ?? amount)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onIncrement()
            case .decrement: onDecrement()
            @unknown default: break
            }
        }
    }

    private func stepButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.bold))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

/// A drop-in replacement for a quantity `TextField`: a stepper for the amount
/// plus a menu for the unit. Reads and writes a single formatted string binding
/// so callers (and storage) stay string-based. When the bound string has no
/// unit yet, `proposedUnit` (from the AI / on-device guess) is offered and
/// adopted the moment the user engages the control.
struct QuantityStepperField: View {
    @Binding var quantity: String
    var proposedUnit: String? = nil
    var tint: Color = .accentColor

    @State private var showingCustomUnit = false
    @State private var customUnit = ""

    private var parsed: Quantity { Quantity(parsing: quantity) }

    /// Unit shown to the user: the explicit unit if set, else the proposal.
    private var effectiveUnit: String {
        let unit = parsed.unit
        return unit.isEmpty ? (proposedUnit ?? "") : unit
    }

    private var amountLabel: String {
        parsed.amount.map(Quantity.formatAmount) ?? "0"
    }

    var body: some View {
        HStack(spacing: 12) {
            stepperControl
            unitMenu
        }
        .alert("Custom unit", isPresented: $showingCustomUnit) {
            TextField("Unit", text: $customUnit)
                .textInputAutocapitalization(.never)
            Button("Set") { setUnit(customUnit.trimmingCharacters(in: .whitespaces)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a unit like \u{201C}case\u{201D} or \u{201C}sticks\u{201D}.")
        }
    }

    private var stepperControl: some View {
        QuantityStepperControl(
            amount: amountLabel,
            accessibilityValue: "\(amountLabel) \(effectiveUnit)",
            onDecrement: { adjust(-1) },
            onIncrement: { adjust(1) }
        )
    }

    private var unitMenu: some View {
        Menu {
            Button("None") { setUnit("") }
            Divider()
            ForEach(GroceryUnits.all, id: \.self) { unit in
                Button {
                    setUnit(unit)
                } label: {
                    if unit == effectiveUnit {
                        Label(unit, systemImage: "checkmark")
                    } else {
                        Text(unit)
                    }
                }
            }
            Divider()
            Button("Custom\u{2026}") {
                customUnit = effectiveUnit
                showingCustomUnit = true
            }
        } label: {
            HStack(spacing: 4) {
                Text(effectiveUnit.isEmpty ? "unit" : effectiveUnit)
                    .foregroundStyle(effectiveUnit.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            // Never wrap or get squeezed — the label keeps its intrinsic width.
            .fixedSize()
        }
        // Neutral, not accent-tinted — the label colors above own its appearance.
        .tint(.primary)
        .fixedSize()
        .accessibilityLabel("Unit")
    }

    // MARK: - Mutation

    private func adjust(_ direction: Double) {
        Haptics.selection()
        let unit = effectiveUnit
        let step = GroceryUnits.step(for: unit)
        let next = (parsed.amount ?? 0) + direction * step
        withAnimation(.snappy(duration: 0.22)) {
            // Stepping to zero clears the quantity.
            quantity = next > 0 ? Quantity(amount: next, unit: unit).formatted : ""
        }
    }

    private func setUnit(_ unit: String) {
        Haptics.selection()
        var next = parsed
        next.unit = unit
        // Picking a real unit with no amount yet implies one of it.
        if !unit.isEmpty && next.amount == nil {
            next.amount = 1
        }
        withAnimation(.snappy(duration: 0.22)) {
            quantity = next.formatted
        }
    }
}
