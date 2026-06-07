import SwiftUI

/// Home / planning screen. A Group menu switches between groups (each group is
/// its own list, with a store, icon, and color theme). Items are grouped by
/// category with a Start Shopping CTA themed to the group.
struct GroceryListView: View {
    @Environment(GroceryRepository.self) private var repo

    @State private var quickAddText = ""
    @State private var showingAddItem = false
    @State private var showingSettings = false
    @State private var sessionForNav: ShoppingSession?
    @State private var showNewGroup = false
    @State private var showEditGroup = false
    @State private var showRemoved = false
    @State private var showStartTrip = false
    @State private var tripStoreName = ""
    @FocusState private var quickAddFocused: Bool

    private var tint: Color { repo.currentHousehold?.tint ?? .green }

    var body: some View {
        List {
            if let session = repo.activeSession {
                Section {
                    ActiveSessionBanner(session: session, progress: repo.progress(for: session), tint: tint) {
                        sessionForNav = session
                    }
                }
            }

            if repo.currentList != nil {
                Section {
                    quickAddRow
                } footer: {
                    if !repo.pendingItems.isEmpty {
                        Text("^[\(repo.pendingItems.count) item](inflect: true) on the list")
                    }
                }

                ForEach(repo.pendingItems.groupedByCategory(), id: \.category) { group in
                    Section {
                        ForEach(group.items) { item in
                            NavigationLink(value: item) { GroceryItemRow(item: item) }
                        }
                    } header: {
                        CategoryHeader(category: group.category)
                    }
                }

                if repo.pendingItems.isEmpty && repo.removedItems.isEmpty {
                    ContentUnavailableView("Nothing on the list", systemImage: "checklist",
                                           description: Text("Add what you need for \(repo.currentHousehold?.name ?? "this group")."))
                }

                if !repo.removedItems.isEmpty {
                    removedSection
                }
            } else if repo.hasCompletedInitialLoad {
                ContentUnavailableView("No groups yet", systemImage: "person.2",
                                       description: Text("Create a group to start planning."))
            } else {
                GroceryListSkeleton()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(repo.currentHousehold?.name ?? "Grocer")
        .navigationBarTitleDisplayMode(.large)
        .tint(tint)
        .navigationDestination(for: GroceryItem.self) { item in ItemDetailView(item: item) }
        .navigationDestination(item: $sessionForNav) { session in
            ShoppingSessionView(sessionId: session.id) { sessionForNav = nil }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                SyncStatusBar(state: repo.syncState)
                if repo.currentList != nil && repo.activeSession == nil {
                    startShoppingButton
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { groupMenu }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingAddItem = true } label: { Image(systemName: "plus") }
                    .disabled(repo.currentList == nil)
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showingAddItem) { NavigationStack { AddItemView() } }
        .sheet(isPresented: $showingSettings) { NavigationStack { SettingsView() } }
        .sheet(isPresented: $showNewGroup) { NavigationStack { GroupEditorView(group: nil) } }
        .sheet(isPresented: $showEditGroup) { NavigationStack { GroupEditorView(group: repo.currentHousehold) } }
        .sheet(isPresented: $showStartTrip) {
            StartTripSheet(
                storeName: $tripStoreName,
                groupName: repo.currentHousehold?.name ?? "this group",
                itemCount: repo.pendingItems.count,
                tint: tint
            ) {
                guard let list = repo.currentList else { return }
                let store = tripStoreName.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    await repo.startShopping(list: list, storeName: store.isEmpty ? nil : store)
                    sessionForNav = repo.activeSession
                }
            }
            .presentationDetents([.medium])
        }
    }

    // MARK: - Group menu

    private var groupMenu: some View {
        Menu {
            Picker("Group", selection: Binding(
                get: { repo.currentHousehold?.id ?? "" },
                set: { repo.selectHousehold($0) }
            )) {
                ForEach(repo.households) { house in
                    Label(house.name, systemImage: house.icon).tag(house.id)
                }
            }
            Divider()
            Button { showNewGroup = true } label: { Label("New Group", systemImage: "plus") }
            if repo.currentHousehold != nil {
                Button { showEditGroup = true } label: { Label("Edit Group", systemImage: "paintbrush") }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: repo.currentHousehold?.icon ?? "person.2.fill")
                Text(repo.currentHousehold?.name ?? "Group").lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: - Quick add

    private var quickAddRow: some View {
        HStack {
            Image(systemName: "plus.circle.fill").foregroundStyle(tint)
            TextField("Add item…", text: $quickAddText)
                .focused($quickAddFocused)
                .submitLabel(.done)
                .onSubmit(submitQuickAdd)
            if !quickAddText.isEmpty {
                Button("Add", action: submitQuickAdd).buttonStyle(.borderless)
            }
        }
    }

    private func submitQuickAdd() {
        let name = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        repo.addItem(name: name, quantity: nil, category: CategoryGuess.guess(for: name),
                     notes: nil, replacementPreference: nil)
        quickAddText = ""
        quickAddFocused = true
    }

    private var removedSection: some View {
        Section {
            Button {
                withAnimation { showRemoved.toggle() }
            } label: {
                HStack {
                    Label("Completed & Removed (\(repo.removedItems.count))", systemImage: "archivebox")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showRemoved ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showRemoved {
                ForEach(repo.removedItems) { item in
                    HStack(spacing: 10) {
                        Image(systemName: statusIcon(for: item.status))
                            .foregroundStyle(statusColor(for: item.status))
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.body)
                                .foregroundStyle(.secondary)
                            Text(item.status.rawValue)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button {
                            repo.restoreItem(item)
                        } label: {
                            Text("Re-add")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func statusIcon(for status: ItemStatus) -> String {
        switch status {
        case .found: return "checkmark.circle.fill"
        case .replaced: return "arrow.triangle.2.circlepath.circle.fill"
        case .removed: return "minus.circle.fill"
        default: return "circle"
        }
    }

    private func statusColor(for status: ItemStatus) -> Color {
        switch status {
        case .found: return .green
        case .replaced: return .blue
        case .removed: return .orange
        default: return .secondary
        }
    }

    private var startShoppingButton: some View {
        Button {
            tripStoreName = repo.currentHousehold?.storeName ?? ""
            showStartTrip = true
        } label: {
            Label("Start Shopping", systemImage: "cart.fill")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
        .padding()
        .background(.bar)
        .disabled(repo.pendingItems.isEmpty)
    }
}

// MARK: - Rows / banners

struct GroceryItemRow: View {
    let item: GroceryItem
    var body: some View {
        HStack(spacing: 10) {
            if item.priority == .high {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body)
                HStack(spacing: 6) {
                    if let qty = item.quantity { Text(qty); Text("·") }
                    Text("Added by \(item.requestedByDisplayName)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if item.priority == .low {
                Spacer()
                Text("low")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

struct StartTripSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var storeName: String
    let groupName: String
    let itemCount: Int
    var tint: Color = .green
    let onStart: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "cart.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(tint)
                    Text("Start Shopping")
                        .font(.title2.bold())
                    Text("^[\(itemCount) item](inflect: true) on \(groupName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Store")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("Where are you shopping?", text: $storeName)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                }
                .padding(.horizontal)

                Text("Set a default store in **Edit Group** so it's always pre-filled.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()

                Button {
                    dismiss()
                    onStart()
                } label: {
                    Label("Start Shopping", systemImage: "cart.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct ActiveSessionBanner: View {
    let session: ShoppingSession
    let progress: SessionProgress
    var tint: Color = .green
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "cart.fill")
                    .font(.title2).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(session.startedByDisplayName) is shopping\(session.storeName.map { " at \($0)" } ?? "")")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("\(progress.found) found · \(progress.remaining) left")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("View").font(.subheadline.weight(.medium))
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
