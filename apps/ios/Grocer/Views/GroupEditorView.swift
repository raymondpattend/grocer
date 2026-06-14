import SwiftUI

/// Create or edit a group. A group *is* the grocery list, so this is where the
/// name, store, icon, and color theme are set.
struct GroupEditorView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    /// nil = create a new group; non-nil = edit an existing one.
    let group: Household?

    /// Called with the freshly created group after a successful create, before
    /// the editor dismisses — lets the presenter navigate into the new group.
    var onCreate: ((Household) -> Void)? = nil

    @State private var name = ""
    @State private var storeName = ""
    @State private var icon = GROUP_ICON_CHOICES[0]
    @State private var theme: ListColorTheme = .default
    @State private var isSaving = false
    @State private var saveError: String?

    private var isEditing: Bool { group != nil }
    private let columns = Array(repeating: GridItem(.flexible()), count: 6)

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: icon)
                        .font(.title2).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(theme.color))
                    TextField("Group name", text: $name).font(.headline)
                }
            }

            Section("Store") {
                TextField("Store name (optional)", text: $storeName)
            }

            Section("Color") {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(ListColorTheme.allCases) { t in
                        Circle()
                            .fill(t.color)
                            .frame(width: 32, height: 32)
                            .overlay {
                                if t == theme {
                                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                }
                            }
                            .onTapGesture {
                                Haptics.selection()
                                theme = t
                            }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Icon") {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(GROUP_ICON_CHOICES, id: \.self) { choice in
                        Image(systemName: choice)
                            .font(.title3)
                            .foregroundStyle(choice == icon ? .white : theme.color)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(choice == icon ? AnyShapeStyle(theme.color) : AnyShapeStyle(theme.color.opacity(0.15))))
                            .onTapGesture {
                                Haptics.selection()
                                icon = choice
                            }
                    }
                }
                .padding(.vertical, 4)
            }

        }
        .navigationTitle(isEditing ? String(localized: "Edit Group") : String(localized: "New Group"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { Haptics.selection(); dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save", action: save).bold()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (isEditing && !repo.isOwnerOfCurrentGroup))
                }
            }
        }
        .onAppear(perform: load)
        .alert("Couldn't Save Group", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func load() {
        guard let group else { return }
        name = group.name
        storeName = group.storeName ?? ""
        icon = group.icon
        theme = group.colorTheme
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let store = storeName.trimmingCharacters(in: .whitespaces)
        if isEditing {
            guard repo.isOwnerOfCurrentGroup else {
                Haptics.error()
                saveError = String(localized: "Only the group owner can edit group details.")
                return
            }
            repo.updateGroup(name: trimmedName, store: store, icon: icon, theme: theme)
            Haptics.success()
            dismiss()
            return
        }

        isSaving = true
        Task {
            let created = await repo.createGroup(name: trimmedName, store: store, icon: icon, theme: theme)
            await MainActor.run {
                isSaving = false
                if let created {
                    Haptics.success()
                    onCreate?(created)
                    dismiss()
                } else {
                    Haptics.error()
                    saveError = repo.usingCloudKit
                        ? String(localized: "This group couldn't be saved to iCloud. Check Settings → Diagnostics for sync status, then try again.")
                        : String(localized: "Sign in to iCloud to save groups across devices.")
                }
            }
        }
    }
}
