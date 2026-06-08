import SwiftUI

struct AddItemView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var quantity = ""
    @State private var category: GroceryCategory = .other
    @State private var notes = ""
    @State private var replacementPreference = ""
    @State private var priority: ItemPriority = .normal
    @State private var categoryEditedManually = false
    @State private var showPastItems = false

    var body: some View {
        Form {
            if !repo.pastItemNames.isEmpty {
                Section {
                    Button {
                        showPastItems = true
                    } label: {
                        Label("Add from Previous Items", systemImage: "clock.arrow.circlepath")
                    }
                }
            }

            Section("Item") {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .onSubmit { if canSave { save() } }
            }

            Section("Details (optional)") {
                TextField("Quantity", text: $quantity)
                Picker("Category", selection: $category) {
                    ForEach(GroceryCategory.ordered) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: category) { _, _ in categoryEditedManually = true }
                Picker("Priority", selection: $priority) {
                    ForEach(ItemPriority.allCases) { p in
                        Label(p.rawValue, systemImage: p.systemImage).tag(p)
                    }
                }
                TextField("Notes", text: $notes, axis: .vertical)
            }

            Section("If unavailable") {
                TextField("Replacement preference", text: $replacementPreference)
                    .textInputAutocapitalization(.sentences)
            }
        }
        .navigationTitle("Add Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add", action: save).bold()
                    .disabled(!canSave)
            }
        }
        .onChange(of: name) { _, newValue in
            guard !categoryEditedManually else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 2 {
                category = CategoryGuess.guess(for: trimmed)
            }
        }
        .sheet(isPresented: $showPastItems) {
            PastItemsSheet { selectedName in
                name = selectedName
                if !categoryEditedManually {
                    category = CategoryGuess.guess(for: selectedName)
                }
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty
    }

    private func save() {
        repo.addItem(
            name: trimmedName,
            quantity: quantity,
            category: category,
            notes: notes,
            priority: priority,
            replacementPreference: replacementPreference
        )
        dismiss()
    }
}

// MARK: - Past Items Sheet

private struct PastItemsSheet: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    let onSelect: (String) -> Void

    @State private var search = ""

    private var filtered: [String] {
        let items = repo.pastItemNames
        guard !search.isEmpty else { return items }
        let query = search.lowercased()
        return items.filter { $0.lowercased().contains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ForEach(filtered, id: \.self) { itemName in
                        Button {
                            onSelect(itemName)
                            dismiss()
                        } label: {
                            Label(itemName, systemImage: "arrow.counterclockwise")
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Filter previous items")
            .navigationTitle("Previous Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
