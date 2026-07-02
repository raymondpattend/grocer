import PostHog
import SwiftUI

/// Quick actions when a shopper taps an item during a session.
struct ItemActionSheet: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: GroceryItem
    let onReplace: () -> Void

    @State private var addingNote = false
    @State private var note: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.title3.bold())
                        if let detail = [item.quantity, item.notes].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    actionRow(String(localized: "Mark Found"), systemImage: "checkmark.circle.fill", tint: .green) {
                        Haptics.success()
                        moveItem { repo.mark(item, as: .found) }
                        dismiss()
                    }
                    actionRow(String(localized: "Replace"), systemImage: "arrow.triangle.2.circlepath.circle.fill", tint: .blue) {
                        Haptics.selection()
                        dismiss(); onReplace()
                    }
                    actionRow(String(localized: "Out of Stock"), systemImage: "xmark.circle.fill", tint: .red) {
                        Haptics.warning()
                        moveItem { repo.mark(item, as: .outOfStock) }
                        dismiss()
                    }
                    actionRow(String(localized: "Skip"), systemImage: "arrow.uturn.forward.circle.fill", tint: .orange) {
                        Haptics.warning()
                        moveItem { repo.mark(item, as: .skipped) }
                        dismiss()
                    }
                }

                Section {
                    Button {
                        Haptics.selection()
                        note = item.notes ?? ""
                        addingNote = true
                    } label: {
                        FALabel("Add Note", icon: "note.text")
                    }
                    NavigationLink {
                        ItemDetailView(item: item)
                    } label: {
                        FALabel("View Details", icon: "info.circle")
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        Haptics.selection()
                    })
                }
            }
            .navigationTitle("Quick Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        Haptics.tap()
                        dismiss()
                    }
                }
            }
            .alert("Add Note", isPresented: $addingNote) {
                TextField("Note", text: $note)
                Button("Save") {
                    Haptics.success()
                    var updated = item
                    updated.notes = note.isEmpty ? nil : note
                    repo.update(updated)
                }
                Button("Cancel", role: .cancel) {}
            }
            .postHogScreenView("Quick Actions")
        }
    }

    private func actionRow(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            FALabel(title, icon: systemImage)
                .foregroundStyle(.primary)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)
        }
    }

    private func moveItem(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), action)
    }
}

/// Replacement picker shown when an item is unavailable.
struct ReplacementSheet: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: GroceryItem
    @State private var customReplacement = ""

    private var suggestions: [String] {
        // Use the item's stored preference plus a couple of generic options.
        var options: [String] = []
        if let pref = item.replacementPreference, !pref.isEmpty { options.append(pref) }
        options.append(contentsOf: [
            String(localized: "Any similar \(item.category.localizedName.lowercased())"),
            String(localized: "Store brand"),
            String(localized: "Any similar item"),
        ])
        return Array(NSOrderedSet(array: options)) as? [String] ?? options
    }

    var body: some View {
        NavigationStack {
            List {
                Section("\(item.name) unavailable — replace with") {
                    ForEach(suggestions, id: \.self) { option in
                        Button {
                            Haptics.success()
                            moveItem { repo.mark(item, as: .replaced, replacement: option) }
                            dismiss()
                        } label: {
                            FALabel(option, icon: "cart.badge.plus")
                        }
                    }
                }
                Section("Custom replacement") {
                    HStack {
                        TextField("Replacement item", text: $customReplacement)
                        Button("Use") {
                            Haptics.success()
                            moveItem { repo.mark(item, as: .replaced, replacement: customReplacement) }
                            dismiss()
                        }
                        .disabled(customReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    Button("No replacement — mark Out of Stock", role: .destructive) {
                        Haptics.warning()
                        moveItem { repo.mark(item, as: .outOfStock) }
                        dismiss()
                    }
                }
            }
            .navigationTitle("Replacement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Haptics.tap()
                        dismiss()
                    }
                }
            }
            .postHogScreenView("Replacement")
        }
    }

    private func moveItem(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86), action)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
