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
    @State private var suggestions: [Suggestion] = []
    @State private var categoryEditedManually = false
    @State private var suggestTask: Task<Void, Never>?
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

                if !filteredSuggestions.isEmpty {
                    ForEach(filteredSuggestions) { suggestion in
                        Button { apply(suggestion) } label: {
                            HStack {
                                Image(systemName: "sparkles").foregroundStyle(.green)
                                VStack(alignment: .leading) {
                                    Text(suggestion.name)
                                    if let detail = suggestionDetail(suggestion) {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
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
        .task(id: name) {
            await updateSuggestions()
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

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var filteredSuggestions: [Suggestion] {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return [] }
        return suggestions.filter { $0.name.lowercased() != trimmed }
    }

    private func suggestionDetail(_ s: Suggestion) -> String? {
        [s.quantity, s.category, s.notes].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    private func apply(_ s: Suggestion) {
        name = s.name
        if let q = s.quantity { quantity = q }
        if let c = GroceryCategory(rawValue: s.category) { category = c; categoryEditedManually = true }
        if let n = s.notes { notes = n }
        suggestions = []
    }

    @MainActor
    private func updateSuggestions() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { suggestions = []; return }

        if !categoryEditedManually {
            category = CategoryGuess.guess(for: trimmed)
        }

        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        let recent = repo.pendingItems.map(\.name)
        let result = await APIClient.shared.suggestions(query: trimmed, recent: recent)
        guard !Task.isCancelled else { return }
        suggestions = result
    }

    private func save() {
        repo.addItem(
            name: name.trimmingCharacters(in: .whitespaces),
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
