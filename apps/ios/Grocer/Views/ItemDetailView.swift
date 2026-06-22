import SwiftUI

struct ItemDetailView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State var item: GroceryItem
    @State private var editing = false
    @State private var showRemoveConfirm = false
    /// Drives the full-screen preview of the member's own attached photo.
    @State private var showPhotoPreview = false

    /// The member who requested the item, for their avatar in "Requested".
    private var requestedByMember: HouseholdMember? {
        repo.member(for: item)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    itemImage
                    VStack(spacing: 2) {
                        Text(item.name)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(item.category.localizedName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    // The name and category are already the navigation title — keep
                    // them out of VoiceOver here so the only stop is the photo.
                    .accessibilityHidden(true)
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
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { HapticBackButton() }
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

    /// The AI-generated product image (shown everywhere), with the member's own
    /// photo — when one was attached — tucked in small in the corner. This is the
    /// only screen that surfaces the user-taken photo; tapping it opens a
    /// full-screen preview.
    @ViewBuilder
    private var itemImage: some View {
        ZStack(alignment: .bottomTrailing) {
            ProductImageView(itemName: item.name, size: 160)
                .accessibilityHidden(true)
            if let photoData = item.photoData, let image = UIImage(data: photoData) {
                Button {
                    Haptics.tap()
                    showPhotoPreview = true
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color(.systemBackground), lineWidth: 3)
                        }
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View your photo")
                .accessibilityAddTraits(.isImage)
                .fullScreenCover(isPresented: $showPhotoPreview) {
                    FullScreenPhotoView(image: image)
                }
            }
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
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
            item.quantity = Quantity(amount: amount, unit: unit).formatted
        }
        // Persist on the next runloop pass so the repo's observable write doesn't
        // commit a non-animated transaction in the same tick as the stepper
        // animation above (which would otherwise cancel it).
        let updated = item
        Task { @MainActor in repo.update(updated) }
    }

    private func moveItem(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), action)
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
                Toggle("Critical", isOn: Binding(
                    get: { item.priority == .critical },
                    set: { item.priority = $0 ? .critical : .normal }
                ))
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

/// Full-screen viewer for the member's own attached photo. Fits the image to the
/// screen on a black backdrop, supports pinch-to-zoom, and dismisses on a tap (or
/// the close button) when not zoomed in.
private struct FullScreenPhotoView: View {
    let image: UIImage

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Committed zoom scale; `1` is fit-to-screen.
    @State private var scale: CGFloat = 1
    /// Live pinch delta layered on top of `scale` while the gesture is active.
    @GestureState private var pinch: CGFloat = 1

    private var currentScale: CGFloat { scale * pinch }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(currentScale)
                .gesture(magnification)
                .onTapGesture(count: 2) { toggleZoom() }
                // A single tap dismisses, but only at rest so it doesn't fight the
                // pinch/double-tap-to-zoom interactions.
                .onTapGesture { if currentScale <= 1.01 { dismiss() } }
                .accessibilityLabel("Your photo")
        }
        .overlay(alignment: .topTrailing) { closeButton }
        .statusBarHidden()
    }

    private var closeButton: some View {
        Button {
            Haptics.tap()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(16)
        .accessibilityLabel("Close")
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in
                // Clamp to a sensible range, snapping back to fit when pinched out.
                scale = min(max(scale * value, 1), 5)
            }
    }

    private func toggleZoom() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            scale = scale > 1 ? 1 : 2.5
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
