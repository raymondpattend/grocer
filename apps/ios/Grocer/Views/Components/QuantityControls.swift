import SwiftUI

// Quantity stepper controls. Presentation layer for the Quantity value type
// (in Services/Quantity.swift); kept in Views so SwiftUI lives out of Services.


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
    /// Larger type and tap targets for prominent placements (e.g. the photo
    /// confirm card), where the stepper is the focal control rather than a row.
    var large: Bool = false
    /// Spread to fill the available width (minus pinned leading, plus trailing)
    /// and drop the capsule background. For placements that already sit on a
    /// surface — e.g. a form row — so the stepper doesn't read as a background
    /// floating inside another background.
    var fill: Bool = false
    var onDecrement: () -> Void
    var onIncrement: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            stepButton(systemImage: "minus", action: onDecrement)
            if fill { Spacer(minLength: 12) }
            Text(amount)
                .font((large ? Font.title3 : Font.subheadline).weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
                // Self-animate on value change so the rolling-digit transition
                // fires regardless of whether the caller wrapped the mutation in
                // `withAnimation` (and survives an interleaved non-animated
                // observation, e.g. the item-detail repo write).
                .animation(.snappy(duration: 0.22), value: amount)
                .frame(minWidth: large ? 44 : 30)
            if fill { Spacer(minLength: 12) }
            stepButton(systemImage: "plus", action: onIncrement)
        }
        .padding(.vertical, large ? 8 : 4)
        .padding(.horizontal, large ? 4 : 0)
        // `fill` placements ride on the host surface's own background, so they
        // drop the capsule to avoid a background-inside-a-background look.
        .background(fill ? AnyShapeStyle(.clear) : AnyShapeStyle(.quaternary.opacity(0.6)), in: Capsule())
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
            FAImage(systemImage, size: large ? 17 : 13)
                .frame(width: large ? 44 : 30, height: large ? 34 : 24)
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
    /// Larger type and tap targets for prominent placements (e.g. the photo
    /// confirm card). Passed through to the underlying `QuantityStepperControl`.
    var large: Bool = false
    /// Spread the stepper to fill the row and drop its capsule background — for
    /// placements that already sit on a surface (e.g. a form row). Passed through
    /// to the underlying `QuantityStepperControl`.
    var fill: Bool = false
    /// Prominent circular style: large filled-circle minus/plus buttons pinned to
    /// the row's leading and trailing edges, with the amount centered above the
    /// unit menu — the stepper card used in the Add Item sheet.
    var prominent: Bool = false

    @State private var showingCustomUnit = false
    @State private var customUnit = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var parsed: Quantity { Quantity(parsing: quantity) }

    /// Unit shown to the user: the explicit unit if set, else the proposal.
    private var effectiveUnit: String {
        let unit = parsed.unit
        return unit.isEmpty ? (proposedUnit ?? "") : unit
    }

    /// `effectiveUnit` inflected for the current amount ("bunches" at 4, "bunch"
    /// at 1). Used only for the label — selection still keys off the singular.
    private var displayUnit: String {
        GroceryUnits.form(effectiveUnit, for: parsed.amount)
    }

    private var amountLabel: String {
        parsed.amount.map(Quantity.formatAmount) ?? "0"
    }

    var body: some View {
        Group {
            if prominent {
                prominentStepper
            } else {
                HStack(spacing: 12) {
                    stepperControl
                        .frame(maxWidth: fill ? .infinity : nil)
                    unitMenu
                }
            }
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
            accessibilityValue: "\(amountLabel) \(displayUnit)",
            large: large,
            fill: fill,
            onDecrement: { adjust(-1) },
            onIncrement: { adjust(1) }
        )
    }

    private var unitMenu: some View {
        Menu {
            UnitMenuItems(
                selectedUnit: effectiveUnit,
                onSelect: { setUnit($0) },
                onCustom: {
                    customUnit = effectiveUnit
                    showingCustomUnit = true
                }
            )
        } label: {
            HStack(spacing: 4) {
                Text(effectiveUnit.isEmpty ? String(localized: "unit") : displayUnit)
                    .foregroundStyle(effectiveUnit.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                FAImage("chevron.up.chevron.down", relativeTo: .caption2)
                    .foregroundStyle(.secondary)
            }
            .font(large ? .body : .subheadline)
            // Never wrap or get squeezed — the label keeps its intrinsic width.
            .fixedSize()
        }
        // Neutral, not accent-tinted — the label colors above own its appearance.
        .tint(.primary)
        .fixedSize()
        .accessibilityLabel("Unit")
    }

    /// The circular, edge-aligned stepper used by the Add Item sheet: big filled
    /// minus/plus circles pinned to the leading and trailing edges, with the amount
    /// (and the unit menu beneath it) centered between them.
    private var prominentStepper: some View {
        HStack(spacing: 0) {
            circleButton(systemImage: "minus") { adjust(-1) }
            Spacer(minLength: 12)
            VStack(spacing: 2) {
                Text(amountLabel)
                    .font(.title.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: amountLabel)
                unitMenu
            }
            Spacer(minLength: 12)
            circleButton(systemImage: "plus") { adjust(1) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func circleButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FAImage(systemImage, relativeTo: .title3)
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .background(Color(.systemGray5), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mutation

    private func adjust(_ direction: Double) {
        Haptics.selection()
        let unit = effectiveUnit
        let step = GroceryUnits.step(for: unit)
        let next = (parsed.amount ?? 0) + direction * step
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
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
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            quantity = next.formatted
        }
    }
}

/// The grocery-unit picker menu content: a "None" option, every unit in
/// `GroceryUnits.all` (checkmarking the current one), and a "Custom…" escape
/// hatch. Lives inside the add-item stepper's unit `Menu`. (The inline quantity
/// chip's long-press picker offers the same `GroceryUnits.all` options in a
/// popover instead.)
struct UnitMenuItems: View {
    /// The unit currently in effect — checkmarked in the list.
    var selectedUnit: String
    var onSelect: (String) -> Void
    var onCustom: () -> Void

    var body: some View {
        Button("None") { onSelect("") }
        Divider()
        ForEach(GroceryUnits.all, id: \.self) { unit in
            Button {
                onSelect(unit)
            } label: {
                if unit == selectedUnit {
                    FALabel(unit, icon: "checkmark")
                } else {
                    Text(unit)
                }
            }
        }
        Divider()
        Button("Custom\u{2026}") { onCustom() }
    }
}
