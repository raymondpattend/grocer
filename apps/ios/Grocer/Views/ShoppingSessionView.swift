import SwiftUI
import Combine

/// Focused shopping mode — swipe-driven, one-handed item marking.
struct ShoppingSessionView: View {
    @Environment(GroceryRepository.self) private var repo

    let sessionId: String
    var onExit: () -> Void = {}

    @State private var replacingItem: GroceryItem?
    @State private var editingItem: GroceryItem?
    @State private var selectedItem: GroceryItem?
    @State private var showCompleted = true
    @State private var showFinish = false
    @State private var showAddItem = false
    @State private var editingStore = false
    @State private var storeText = ""
    @State private var now = Date()

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
        .onChange(of: session?.status) { _, status in
            handleSessionEnded(status)
        }
    }

    /// When the shopper ends the trip, a spectator (someone who didn't start it)
    /// has no Finish flow of their own, so the screen would otherwise sit on a
    /// stale, no-longer-active session. Kick them back to the main list and
    /// close any sheets they had open. The shopper is excluded — they end the
    /// trip through the summary flow and dismiss themselves.
    private func handleSessionEnded(_ status: SessionStatus?) {
        guard let session, let status, status != .active else { return }
        guard !repo.isStartedByCurrentUser(session) else { return }
        selectedItem = nil
        editingItem = nil
        replacingItem = nil
        showAddItem = false
        editingStore = false
        showFinish = false
        onExit()
    }

    @ViewBuilder
    private func sessionContent(_ session: ShoppingSession) -> some View {
        let canManageTrip = repo.isStartedByCurrentUser(session)

        List {
            progressHeader(session, canManageTrip: canManageTrip)

            ForEach(pendingGroups(session), id: \.category) { group in
                Section {
                    ForEach(group.items) { item in
                        shopItemButton(item, canManageTrip: canManageTrip)
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
                        shopItemButton(item, canManageTrip: canManageTrip)
                    }
                } header: {
                    Label("Added During Trip", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .textCase(nil)
                }
            }

            completedSection(session, canManageTrip: canManageTrip)
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: progress.remaining)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                SyncStatusBar(state: repo.syncState)
                if canManageTrip {
                    finishButton
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAddItem = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $selectedItem) { item in
            ShoppingItemDetailView(item: item, tint: tint, canManageTrip: canManageTrip) { action in
                selectedItem = nil
                switch action {
                case .found:
                    repo.mark(item, as: .found)
                case .replace:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        replacingItem = item
                    }
                case .skip:
                    repo.mark(item, as: .skipped)
                case .outOfStock:
                    repo.mark(item, as: .outOfStock)
                case .edit:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        editingItem = item
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            now = Date()
        }
    }

    private func shopItemButton(_ item: GroceryItem, canManageTrip: Bool) -> some View {
        Button { selectedItem = item } label: {
            ShopItemRow(item: item, member: repo.currentMembers.first { $0.id == item.requestedByMemberId }, tint: tint)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: canManageTrip) {
            if canManageTrip {
                Button { repo.mark(item, as: .found) } label: {
                    Label("Found", systemImage: "checkmark")
                }
                .tint(.green)
            } else {
                Button { editingItem = item } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(tint)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if canManageTrip {
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

    private func progressHeader(_ session: ShoppingSession, canManageTrip: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    if canManageTrip {
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
                    } else {
                        Text(session.storeName ?? "Store not set")
                            .font(.title2.bold())
                            .foregroundStyle(session.storeName == nil ? .secondary : .primary)
                    }
                    Text("\(session.startedByDisplayName) · started \(session.startedAt, format: .relative(presentation: .named))")
                        .font(.caption).foregroundStyle(.secondary)
                        .id(now)
                }
                Spacer()
            }
            ProgressView(value: Double(progress.total - progress.remaining), total: Double(max(progress.total, 1)))
                .tint(tint)
                .animation(.easeInOut(duration: 0.4), value: progress.remaining)
            HStack(spacing: 16) {
                stat("\(progress.remaining)", "left")
                stat("\(progress.found)", "found")
                if progress.replaced > 0 { stat("\(progress.replaced)", "replaced") }
                if progress.outOfStock > 0 { stat("\(progress.outOfStock)", "unavailable") }
            }
            .font(.subheadline)
            .contentTransition(.numericText())

            if canManageTrip {
                HStack(spacing: 4) {
                    Image(systemName: "hand.draw").font(.caption2)
                    Text("Swipe right → Found · Swipe left for more")
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }
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
    private func completedSection(_ session: ShoppingSession, canManageTrip: Bool) -> some View {
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
                        CompletedItemRow(item: item, canManageTrip: canManageTrip) {
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
    var member: HouseholdMember?
    var tint: Color = .green

    var body: some View {
        HStack(spacing: 12) {
            ProductImageView(itemName: item.name, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.medium))
                if let detail = detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if item.priority == .high {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline)
            } else if item.priority == .low {
                Text("low")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            MemberAvatarView(member: member, size: 26)
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
    let canManageTrip: Bool
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
                if canManageTrip {
                    Button { onUndo() } label: {
                        Label("Put Back on List", systemImage: "arrow.uturn.backward")
                    }
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

// MARK: - Shopping item detail (tap-to-open sheet)

struct ShoppingItemDetailView: View {
    @Environment(GroceryRepository.self) private var repo

    let item: GroceryItem
    var tint: Color = .green
    var canManageTrip = true
    let onAction: (Action) -> Void

    enum Action { case found, replace, skip, outOfStock, edit }

    private var member: HouseholdMember? {
        repo.currentMembers.first { $0.id == item.requestedByMemberId }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                detailsSection
                addedBySection
                actionButtons
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 12) {
            ProductImageView(itemName: item.name, size: 120)
                .padding(.top, 28)

            Text(item.name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                Label(item.category.rawValue, systemImage: item.category.systemImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.12), in: Capsule())

                if let qty = item.quantity {
                    Text(qty)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.systemGray5), in: Capsule())
                }

                if item.priority != .normal {
                    Label(item.priority.rawValue, systemImage: item.priority.systemImage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(item.priority == .high ? .red : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            (item.priority == .high ? Color.red : Color(.systemGray5)).opacity(0.12),
                            in: Capsule()
                        )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
        .background(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Details

    private var detailsSection: some View {
        VStack(spacing: 0) {
            if item.notes != nil || item.replacementPreference != nil {
                VStack(alignment: .leading, spacing: 12) {
                    if let notes = item.notes {
                        detailRow(label: "Notes", systemImage: "note.text", value: notes)
                    }
                    if let pref = item.replacementPreference {
                        detailRow(label: "If unavailable", systemImage: "arrow.triangle.2.circlepath", value: pref)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
        }
    }

    private func detailRow(label: String, systemImage: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
        }
    }

    // MARK: - Added by

    private var addedBySection: some View {
        HStack(spacing: 12) {
            MemberAvatarView(member: member, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Added by \(item.requestedByDisplayName)")
                    .font(.subheadline.weight(.medium))
                Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if canManageTrip {
                Button { onAction(.found) } label: {
                    Label("Mark Found", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)

                HStack(spacing: 10) {
                    Button { onAction(.replace) } label: {
                        Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .controlSize(.regular)

                    Button { onAction(.skip) } label: {
                        Label("Skip", systemImage: "arrow.uturn.forward")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.regular)

                    Button { onAction(.outOfStock) } label: {
                        Label("Out", systemImage: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.regular)
                }
            }

            Button { onAction(.edit) } label: {
                Label("Edit Item", systemImage: "pencil")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .tint(tint)
            .controlSize(.regular)
        }
        .padding(16)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
