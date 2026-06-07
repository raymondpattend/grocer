import SwiftUI

struct ItemDetailView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    @State var item: GroceryItem
    @State private var editing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: item.name)
                if let q = item.quantity { LabeledContent("Quantity", value: q) }
                LabeledContent("Category", value: item.category.rawValue)
                if item.priority != .normal {
                    Label(item.priority.rawValue, systemImage: item.priority.systemImage)
                }
                if let notes = item.notes { LabeledContent("Notes", value: notes) }
            }

            Section("Status") {
                LabeledContent("Current", value: item.status.rawValue)
                if let pref = item.replacementPreference {
                    LabeledContent("Replacement preference", value: pref)
                }
            }

            Section("Requested") {
                LabeledContent("By", value: item.requestedByDisplayName)
                LabeledContent("Added", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            Section {
                Button {
                    repo.mark(item, as: .found)
                    dismiss()
                } label: {
                    Label("Mark as Bought", systemImage: "checkmark.circle")
                }
                Button {
                    repo.mark(item, as: .removed)
                    dismiss()
                } label: {
                    Label("Mark as Not Needed", systemImage: "minus.circle")
                }
                Button(role: .destructive) {
                    repo.delete(item)
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { editing = true }
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
    }
}

/// Simple editor reused by the detail screen.
struct EditItemView: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: GroceryItem
    let onSave: (GroceryItem) -> Void

    var body: some View {
        Form {
            Section("Item") {
                TextField("Name", text: $item.name)
                TextField("Quantity", text: Binding($item.quantity, default: ""))
                Picker("Category", selection: $item.category) {
                    ForEach(GroceryCategory.ordered) { Text($0.rawValue).tag($0) }
                }
                Picker("Priority", selection: $item.priority) {
                    ForEach(ItemPriority.allCases) { p in
                        Label(p.rawValue, systemImage: p.systemImage).tag(p)
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
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(item); dismiss() }.bold()
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
