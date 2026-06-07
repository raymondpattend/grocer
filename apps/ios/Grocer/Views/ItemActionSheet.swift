import SwiftUI

/// Quick actions when a shopper taps an item during a session.
struct ItemActionSheet: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

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
                    actionRow("Mark Found", systemImage: "checkmark.circle.fill", tint: .green) {
                        repo.mark(item, as: .found); dismiss()
                    }
                    actionRow("Replace", systemImage: "arrow.triangle.2.circlepath.circle.fill", tint: .blue) {
                        dismiss(); onReplace()
                    }
                    actionRow("Out of Stock", systemImage: "xmark.circle.fill", tint: .red) {
                        repo.mark(item, as: .outOfStock); dismiss()
                    }
                    actionRow("Skip", systemImage: "arrow.uturn.forward.circle.fill", tint: .orange) {
                        repo.mark(item, as: .skipped); dismiss()
                    }
                }

                Section {
                    Button {
                        note = item.notes ?? ""
                        addingNote = true
                    } label: {
                        Label("Add Note", systemImage: "note.text")
                    }
                    NavigationLink {
                        ItemDetailView(item: item)
                    } label: {
                        Label("View Details", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("Quick Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .alert("Add Note", isPresented: $addingNote) {
                TextField("Note", text: $note)
                Button("Save") {
                    var updated = item
                    updated.notes = note.isEmpty ? nil : note
                    repo.update(updated)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func actionRow(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.primary)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)
        }
    }
}

/// Replacement picker shown when an item is unavailable.
struct ReplacementSheet: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    let item: GroceryItem
    @State private var customReplacement = ""

    private var suggestions: [String] {
        // Use the item's stored preference plus a couple of generic options.
        var options: [String] = []
        if let pref = item.replacementPreference, !pref.isEmpty { options.append(pref) }
        options.append(contentsOf: ["Any similar \(item.category.rawValue.lowercased())", "Store brand", "Any similar item"])
        return Array(NSOrderedSet(array: options)) as? [String] ?? options
    }

    var body: some View {
        NavigationStack {
            List {
                Section("\(item.name) unavailable — replace with") {
                    ForEach(suggestions, id: \.self) { option in
                        Button {
                            repo.mark(item, as: .replaced, replacement: option)
                            dismiss()
                        } label: {
                            Label(option, systemImage: "cart.badge.plus")
                        }
                    }
                }
                Section("Custom replacement") {
                    HStack {
                        TextField("Replacement item", text: $customReplacement)
                        Button("Use") {
                            repo.mark(item, as: .replaced, replacement: customReplacement)
                            dismiss()
                        }
                        .disabled(customReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    Button("No replacement — mark Out of Stock", role: .destructive) {
                        repo.mark(item, as: .outOfStock)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Replacement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
