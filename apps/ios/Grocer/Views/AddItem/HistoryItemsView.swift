import SwiftUI

// History browser for the add-item flow, extracted from AddItemView.swift.

/// Full-pane history browser shown when "History" is tapped in the add flow. It
/// lists items anyone in the group has bought before (with product image and the
/// last-used quantity). Tapping a row reveals the shared quantity stepper to
/// confirm the amount; "Add" stages it back in the add flow.
struct HistoryItemsView: View {
    @Environment(GroceryRepository.self) private var repo
    var tint: Color
    /// Whether the add flow currently has at least one staged item — gates the
    /// header's confirm checkmark.
    var hasProposedItems: Bool
    var onSelect: (String, String, GroceryCategory) -> Void
    /// Live amount change for a row that's already been added — (name, quantity).
    var onUpdateQuantity: (String, String) -> Void
    var onRemove: (String) -> Void
    /// Permanently drop a previously-bought item from the group's history.
    var onDeleteFromHistory: (String) -> Void
    var onClose: () -> Void

    @State private var search = ""

    /// Read live from the repo so removing an item updates the list immediately,
    /// rather than against a snapshot captured when the sheet opened.
    private var suggestions: [GroceryItemSuggestion] { repo.currentItemSuggestions }

    private var filtered: [GroceryItemSuggestion] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return suggestions }
        return suggestions.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                searchField
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)

                content
            }
        }
        .tint(.primary)
    }

    private var header: some View {
        ZStack {
            Text("History")
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(height: 36)
                // Purely a label — taps pass through to nothing.
                .allowsHitTesting(false)

            // A single, always-visible action pinned to the trailing edge (where the
            // confirm checkmark used to live). It reads as a close (X) until at least
            // one item is staged, then morphs into a checkmark — either way it just
            // dismisses the sheet.
            HStack {
                Spacer()
                Button {
                    Haptics.tap()
                    onClose()
                } label: {
                    FAImage(hasProposedItems ? "checkmark" : "xmark", relativeTo: .subheadline)
                        // Glyph inverts against the fill: dark on the light
                        // (dark-theme) circle, light on the dark (light-theme) one.
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 44, height: 44)
                        // Solid primary fill — white in dark mode, black in light.
                        .background(Color.primary, in: Circle())
                        .contentShape(Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hasProposedItems ? "Done" : "Close")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.84), value: hasProposedItems)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            FAImage("magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search previous items", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button {
                    Haptics.tap()
                    search = ""
                } label: {
                    FAImage("xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .grocerLiquidGlass(in: Capsule())
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filtered) { suggestion in
                        HistoryItemRow(
                            suggestion: suggestion,
                            tint: tint,
                            onAdd: { quantity in
                                onSelect(suggestion.name, quantity, suggestion.category)
                            },
                            onUpdateQuantity: { quantity in
                                onUpdateQuantity(suggestion.name, quantity)
                            },
                            onRemove: { onRemove(suggestion.name) },
                            onDeleteFromHistory: { onDeleteFromHistory(suggestion.name) }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            FAImage(search.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass", relativeTo: .title)
                .foregroundStyle(.tertiary)
            Text(search.isEmpty
                 ? String(localized: "No previous items yet")
                 : String(localized: "No items match \u{201C}\(search)\u{201D}"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 28)
    }
}

/// A single history row. Collapsed it shows the image, name, and last quantity;
/// tapping expands it to confirm the amount via `QuantityStepperField` before
/// adding.
struct HistoryItemRow: View {
    let suggestion: GroceryItemSuggestion
    var tint: Color
    var onAdd: (String) -> Void
    /// Called when the amount changes after the row has been added, so the staged
    /// item's quantity tracks the stepper without re-tapping "Add".
    var onUpdateQuantity: (String) -> Void
    var onRemove: () -> Void
    /// Permanently drop this item from the group's history (it disappears from the
    /// suggestion list).
    var onDeleteFromHistory: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var quantity = ""
    /// Drives the "already on your list" confirmation before re-adding.
    @State private var showAddAgainConfirm = false
    /// Amount captured when the confirmation is raised, applied on confirm.
    @State private var pendingQuantity = ""
    /// Drives the "remove from history?" prompt raised when the amount is stepped
    /// down to zero.
    @State private var showRemoveFromHistoryConfirm = false
    /// The amount in the field before it was stepped to zero — restored if the
    /// removal prompt is dismissed (the "undo").
    @State private var quantityBeforeZero = ""
    /// Set once this item has been staged from history. Gives the row a border and
    /// flips the action to "Remove" so the staged item can be taken back off.
    @State private var addedToList = false

    /// Whether the row should read as "on the list" — either it was already
    /// pending, or it's been staged here.
    private var isOnList: Bool { suggestion.isPending || addedToList }

    private var proposedUnit: String? {
        let unit = UnitGuess.guess(for: suggestion.name)
        return unit.isEmpty ? nil : unit
    }

    /// A sensible non-zero amount for a one-tap add: the group's last-used amount,
    /// else one of the natural unit, else no quantity at all (never "0").
    private var defaultQuantity: String {
        let last = suggestion.quantity?.trimmingCharacters(in: .whitespaces) ?? ""
        if !last.isEmpty { return last }
        if let unit = proposedUnit { return "1 \(unit)" }
        // No last-used amount and no natural unit: default to one rather than 0.
        return "1"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            rowInfo

            HStack(spacing: 12) {
                QuantityStepperField(
                    quantity: $quantity,
                    proposedUnit: proposedUnit,
                    tint: tint
                )

                Spacer(minLength: 0)

                Button {
                    toggleAdd()
                } label: {
                    FALabel(addedToList ? String(localized: "Remove") : String(localized: "Add"),
                          icon: addedToList ? "minus" : "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .contentTransition(.symbolEffect(.replace))
                }
                .tint(.primary)
                .grocerGlassButton()
                .clipShape(Capsule())
                .accessibilityLabel(addedToList
                    ? String(localized: "Remove \(suggestion.name) from list")
                    : String(localized: "Add \(suggestion.name) to list"))
            }
        }
        .padding(14)
        .grocerLiquidGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
        .overlay {
            if addedToList {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(.systemGray3), lineWidth: 2)
            }
        }
        .alert("Already on your list", isPresented: $showAddAgainConfirm) {
            Button("Add Again") { performAdd(pendingQuantity) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(suggestion.name) is already on your list. Add it again?")
        }
        .alert(
            String(localized: "Remove \(suggestion.name) from History?"),
            isPresented: $showRemoveFromHistoryConfirm
        ) {
            Button(String(localized: "Remove from History"), role: .destructive) {
                Haptics.warning()
                onDeleteFromHistory()
            }
            // Dismissing (Cancel or tapping away) undoes the step to zero.
            Button(String(localized: "Cancel"), role: .cancel) {
                quantity = quantityBeforeZero
            }
        } message: {
            Text("This removes \(suggestion.name) from your saved items. You can always add it again later.")
        }
        .onAppear {
            // Always-expanded rows seed a non-zero amount to adjust from.
            if quantity.isEmpty { quantity = defaultQuantity }
        }
        .onChange(of: quantity) { oldValue, newValue in
            // Stepping the amount down to zero on a row that isn't staged yet offers
            // to drop the item from history entirely — the prompt's Cancel restores
            // the previous amount (the "undo").
            if !addedToList,
               sanitizedQuantity(newValue).isEmpty,
               !sanitizedQuantity(oldValue).isEmpty {
                quantityBeforeZero = oldValue
                showRemoveFromHistoryConfirm = true
                return
            }
            // Once the row is on the list, edits to the amount flow straight through
            // to the staged item — no need to remove and re-add to change a quantity.
            guard addedToList else { return }
            onUpdateQuantity(sanitizedQuantity(newValue))
        }
    }

    private var rowInfo: some View {
        HStack(spacing: 12) {
            ProductImageView(itemName: suggestion.name, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(suggestion.name)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if isOnList {
                        Text("On list")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                FALabel(suggestion.category.localizedName, icon: suggestion.category.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    /// Toggle the row's staged state: stage it (via the duplicate check) when it
    /// isn't on the list yet, or take it back off when it is.
    private func toggleAdd() {
        Haptics.tap()
        if addedToList {
            performRemove()
        } else {
            attemptAdd(quantity)
        }
    }

    /// Route an add through the duplicate check: items already on the list prompt
    /// for confirmation; everything else is added straight away.
    private func attemptAdd(_ rawQuantity: String) {
        let quantity = sanitizedQuantity(rawQuantity)
        if suggestion.isPending {
            pendingQuantity = quantity
            showAddAgainConfirm = true
        } else {
            performAdd(quantity)
        }
    }

    private func performAdd(_ quantity: String) {
        onAdd(quantity)
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            addedToList = true
        }
        // Sound the success notification just after the press tap. Haptics
        // debounces feedback fired within 40ms of each other, so a small delay
        // lets both land — the add reads as a tap followed by the success buzz.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Haptics.success()
        }
    }

    private func performRemove() {
        onRemove()
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            addedToList = false
        }
    }

    /// Never hand a zero (or blank) amount to the list — treat it as "no quantity".
    private func sanitizedQuantity(_ quantity: String) -> String {
        let trimmed = quantity.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        if let amount = Quantity(parsing: trimmed).amount, amount <= 0 { return "" }
        return trimmed
    }
}
