import SwiftUI

/// Focused shopping mode — swipe-driven, one-handed item marking.
struct ShoppingSessionView: View {
    @Environment(GroceryRepository.self) private var repo

    let sessionId: String
    var onExit: () -> Void = {}

    @State private var replacingItem: GroceryItem?
    @State private var editingItem: GroceryItem?
    @State private var showCompleted = true
    @State private var showFinish = false
    @State private var showAddItem = false
    @State private var editingStore = false
    @State private var storeText = ""

    /// Live session from the repo — always up to date.
    private var session: ShoppingSession? {
        repo.sessions.first { $0.id == sessionId }
    }

    private var progress: SessionProgress {
        guard let session else { return SessionProgress(total: 0, found: 0, replaced: 0, outOfStock: 0, skipped: 0, remaining: 0) }
        return repo.progress(for: session)
    }

    private var tint: Color {
        guard let session else { return .green }
        return repo.households.first { $0.id == session.householdId }?.tint ?? .green
    }

    var body: some View {
        Group {
            if let session {
                sessionContent(session)
            } else {
                ContentUnavailableView("Session ended", systemImage: "cart",
                                       description: Text("This shopping trip is no longer active."))
            }
        }
        .navigationTitle("Shopping")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func sessionContent(_ session: ShoppingSession) -> some View {
        List {
            progressHeader(session)

            ForEach(pendingGroups(session), id: \.category) { group in
                Section {
                    ForEach(group.items) { item in
                        ShopItemRow(item: item, tint: tint)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button { repo.mark(item, as: .found) } label: {
                                    Label("Found", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button { replacingItem = item } label: {
                                    Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .tint(.blue)
                                Button { repo.mark(item, as: .skipped) } label: {
                                    Label("Skip", systemImage: "arrow.uturn.forward")
                                }
                                .tint(.orange)
                                Button { repo.mark(item, as: .outOfStock) } label: {
                                    Label("Out", systemImage: "xmark")
                                }
                                .tint(.red)
                            }
                    }
                } header: {
                    CategoryHeader(category: group.category)
                }
            }

            let addedDuringTrip = repo.addedDuringTrip(session: session)
                .filter { !originalItemIds(session).contains($0.id) }
            if !addedDuringTrip.isEmpty {
                Section {
                    ForEach(addedDuringTrip) { item in
                        ShopItemRow(item: item, tint: tint)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button { repo.mark(item, as: .found) } label: {
                                    Label("Found", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button { replacingItem = item } label: {
                                    Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .tint(.blue)
                                Button { repo.mark(item, as: .skipped) } label: {
                                    Label("Skip", systemImage: "arrow.uturn.forward")
                                }
                                .tint(.orange)
                                Button { repo.mark(item, as: .outOfStock) } label: {
                                    Label("Out", systemImage: "xmark")
                                }
                                .tint(.red)
                            }
                    }
                } header: {
                    Label("Added During Trip", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .textCase(nil)
                }
            }

            completedSection(session)
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                SyncStatusBar(state: repo.syncState)
                finishButton
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddItem = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $replacingItem) { item in
            ReplacementSheet(item: item)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showAddItem) {
            NavigationStack { AddItemView() }
        }
        .sheet(item: $editingItem) { item in
            NavigationStack {
                EditItemView(item: item) { updated in
                    repo.update(updated)
                }
            }
        }
        .navigationDestination(isPresented: $showFinish) {
            SessionSummaryView(session: session) { onExit() }
        }
        .alert("Store", isPresented: $editingStore) {
            TextField("Store name", text: $storeText)
            Button("Save") { repo.setStore(session, to: storeText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Where are you shopping for this trip?")
        }
    }

    private func originalItemIds(_ session: ShoppingSession) -> Set<String> {
        Set(repo.pendingItems(forList: session.listId).filter { $0.createdAt <= session.startedAt }.map(\.id))
    }

    private func pendingGroups(_ session: ShoppingSession) -> [(category: GroceryCategory, items: [GroceryItem])] {
        repo.pendingItems(forList: session.listId)
            .filter { $0.createdAt <= session.startedAt }
            .sorted { $0.priority.sortOrder < $1.priority.sortOrder }
            .groupedByCategory()
    }

    // MARK: - Progress header

    private func progressHeader(_ session: ShoppingSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Button {
                        storeText = session.storeName ?? ""
                        editingStore = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(session.storeName ?? "Set store").font(.title2.bold())
                                .foregroundStyle(session.storeName == nil ? .secondary : .primary)
                            Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    Text("\(session.startedByDisplayName) · started \(session.startedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ProgressView(value: Double(progress.total - progress.remaining), total: Double(max(progress.total, 1)))
                .tint(tint)
            HStack(spacing: 16) {
                stat("\(progress.remaining)", "left")
                stat("\(progress.found)", "found")
                if progress.replaced > 0 { stat("\(progress.replaced)", "replaced") }
                if progress.outOfStock > 0 { stat("\(progress.outOfStock)", "unavailable") }
            }
            .font(.subheadline)

            HStack(spacing: 4) {
                Image(systemName: "hand.draw").font(.caption2)
                Text("Swipe right → Found · Swipe left for more")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value).bold()
            Text(label).foregroundStyle(.secondary)
        }
    }

    // MARK: - Completed section (tappable disclosure)

    @ViewBuilder
    private func completedSection(_ session: ShoppingSession) -> some View {
        let handled = repo.handledItems(session: session)
        if !handled.isEmpty {
            Section {
                Button {
                    withAnimation { showCompleted.toggle() }
                } label: {
                    HStack {
                        Text("Completed (\(handled.count))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showCompleted ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showCompleted {
                    ForEach(handled) { item in
                        CompletedItemRow(item: item) {
                            repo.mark(item, as: .needed)
                        } onEdit: {
                            editingItem = item
                        }
                    }
                }
            }
        }
    }

    // MARK: - Finish button

    private var finishButton: some View {
        Button {
            showFinish = true
        } label: {
            Label("Finish Shopping", systemImage: "flag.checkered")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .controlSize(.large)
        .padding()
        .background(.bar)
    }
}

// MARK: - Pending item row (swipe-driven)

struct ShopItemRow: View {
    let item: GroceryItem
    var tint: Color = .green

    var body: some View {
        HStack(spacing: 12) {
            if item.priority == .high {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.body)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.medium))
                if let detail = detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if item.priority == .low {
                Text("low")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var detail: String? {
        [item.quantity, item.notes].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }
}

// MARK: - Completed item row with undo + edit

private struct CompletedItemRow: View {
    let item: GroceryItem
    let onUndo: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(statusColor)
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .strikethrough(item.status == .found)
                    .foregroundStyle(item.status == .found ? .secondary : .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button { onUndo() } label: {
                    Label("Put Back on List", systemImage: "arrow.uturn.backward")
                }
                Button { onEdit() } label: {
                    Label("Edit Item", systemImage: "pencil")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch item.status {
        case .found: return "checkmark.circle.fill"
        case .replaced: return "arrow.triangle.2.circlepath.circle.fill"
        case .outOfStock: return "xmark.circle.fill"
        case .skipped: return "arrow.uturn.forward.circle.fill"
        default: return "circle"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .found: return .green
        case .replaced: return .blue
        case .outOfStock: return .red
        case .skipped: return .orange
        default: return .secondary
        }
    }

    private var subtitle: String {
        switch item.status {
        case .replaced: return "Replaced with \(item.replacementItemName ?? "alternative")"
        default: return item.status.rawValue
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
