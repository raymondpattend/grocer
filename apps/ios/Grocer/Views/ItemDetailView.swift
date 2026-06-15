import SwiftUI

struct ItemDetailView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    @State var item: GroceryItem
    @State private var editing = false
    @State private var showRemoveConfirm = false

    /// The member who requested the item, for their avatar in "Requested".
    private var requestedByMember: HouseholdMember? {
        repo.member(for: item)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    ProductImageView(itemName: item.name, size: 160)
                    VStack(spacing: 2) {
                        Text(item.name)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(item.category.localizedName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                HStack {
                    Text("Quantity")
                    Spacer()
                    QuantityStepperControl(
                        amount: quantityLabel,
                        onDecrement: decrementQuantity,
                        onIncrement: incrementQuantity
                    )
                }
                if item.priority != .normal {
                    LabeledContent("Priority") {
                        PriorityLabel(priority: item.priority)
                    }
                }
                if let notes = item.notes { LabeledContent("Notes", value: notes) }
            }

            Section("Status") {
                LabeledContent("Current", value: item.status.localizedName)
                if let pref = item.replacementPreference {
                    LabeledContent("Replacement preference", value: pref)
                }
            }

            Section("Requested") {
                HStack {
                    Text("By")
                    Spacer()
                    MemberAvatarView(member: requestedByMember, size: 24)
                    Text(item.requestedByDisplayName)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Added", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                Button(role: .destructive) {
                    Haptics.warning()
                    moveItem {
                        repo.delete(item)
                    }
                    dismiss()
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .tint(.red)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    Haptics.selection()
                    editing = true
                }
            }
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                EditItemView(item: item) { updated in
                    item = updated
                    repo.update(updated)
                }
            }
        }
        .alert("Remove \(item.name)?", isPresented: $showRemoveConfirm) {
            Button("Remove", role: .destructive) {
                Haptics.warning()
                moveItem { repo.delete(item) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Lowering the quantity to zero removes this item from your list.")
        }
    }

    // MARK: - Quantity stepper

    /// Items always represent at least one of something, so an absent quantity
    /// reads as "1".
    private var quantityLabel: String {
        let parsed = Quantity(parsing: item.quantity ?? "")
        return Quantity(amount: parsed.amount ?? 1, unit: parsed.unit).formatted
    }

    private func incrementQuantity() {
        let parsed = Quantity(parsing: item.quantity ?? "")
        let step = GroceryUnits.step(for: parsed.unit)
        setQuantity(amount: (parsed.amount ?? 1) + step, unit: parsed.unit)
    }

    private func decrementQuantity() {
        let parsed = Quantity(parsing: item.quantity ?? "")
        let step = GroceryUnits.step(for: parsed.unit)
        let next = (parsed.amount ?? 1) - step
        guard next > 0 else {
            // Stepping to zero offers to remove the item rather than leaving a
            // quantity-less entry on the list.
            Haptics.warning()
            showRemoveConfirm = true
            return
        }
        setQuantity(amount: next, unit: parsed.unit)
    }

    private func setQuantity(amount: Double, unit: String) {
        Haptics.selection()
        withAnimation(.snappy(duration: 0.22)) {
            item.quantity = Quantity(amount: amount, unit: unit).formatted
        }
        // Persist on the next runloop pass so the repo's observable write doesn't
        // commit a non-animated transaction in the same tick as the stepper
        // animation above (which would otherwise cancel it).
        let updated = item
        Task { @MainActor in repo.update(updated) }
    }

    private func moveItem(_ action: () -> Void) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86), action)
    }
}

/// Simple editor reused by the detail screen.
struct EditItemView: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: GroceryItem
    let onSave: (GroceryItem) -> Void

    /// Natural unit proposed for the item name, offered by the quantity stepper.
    private var proposedUnit: String? {
        let unit = UnitGuess.guess(for: item.name)
        return unit.isEmpty ? nil : unit
    }

    var body: some View {
        Form {
            Section("Item") {
                TextField("Name", text: $item.name)
                LabeledContent("Quantity") {
                    QuantityStepperField(
                        quantity: Binding($item.quantity, default: ""),
                        proposedUnit: proposedUnit
                    )
                }
                Picker("Category", selection: $item.category) {
                    ForEach(GroceryCategory.ordered) { Text($0.localizedName).tag($0) }
                }
                Picker("Priority", selection: $item.priority) {
                    ForEach(ItemPriority.allCases) { p in
                        Text(p.localizedName).tag(p)
                    }
                }
            }
            Section("Notes") {
                TextField("Notes", text: Binding($item.notes, default: ""), axis: .vertical)
            }
            Section("If unavailable") {
                TextField("Replacement preference", text: Binding($item.replacementPreference, default: ""))
            }
        }
        .navigationTitle("Edit Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { Haptics.tap(); dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Haptics.success()
                    onSave(item)
                    dismiss()
                }.bold()
            }
        }
    }
}

extension Binding where Value == String {
    /// Bridge an optional String field to a non-optional TextField binding.
    init(_ source: Binding<String?>, default fallback: String) {
        self.init(
            get: { source.wrappedValue ?? fallback },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
