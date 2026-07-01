import PostHog
import SwiftUI
import Combine

/// Shop several same-store lists as one trip. Mirrors `ShoppingSessionView` but
/// merges the pending/added/completed items from every selected session into a
/// single category-grouped list, each row badged with the group it came from.
/// Marking an item routes through the repo by the item's own `listId`, so writes
/// land in the right group's CloudKit zone with no special handling here.
struct CombinedShoppingSessionView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The session ids that made up the trip when it was opened. The view always
    /// re-derives the *active* subset from the repo, so a session ending mid-trip
    /// (finished individually or expired) simply drops out.
    let sessionIds: [String]
    var onExit: () -> Void = {}

    @State private var replacingItem: GroceryItem?
    @State private var editingItem: GroceryItem?
    @State private var selectedItem: GroceryItem?
    @State private var showCompleted = true
    @State private var showFinish = false
    @State private var showFinishConfirm = false
    /// Snapshot of the active session ids taken when Finish is tapped, so the
    /// pushed summary keeps a stable set even as sessions complete during finish.
    @State private var finishingIds: [String] = []
    /// Kicked off as soon as the shopper commits to finishing, so every list's
    /// session ends (and its shared Live Activity closes) for everyone right
    /// away instead of waiting on the Trip Summary's Done button.
    @State private var endingTask: Task<[String], Never>?
    @State private var showAddGroupPicker = false
    @State private var addTarget: AddTarget?
    /// Organization for the combined view only — each list keeps its own
    /// persisted sort mode for its individual session; this is local to the
    /// combined trip since it spans lists that may not share a preference.
    @State private var sortMode: ListSortMode = .category

    /// Identifiable wrapper so the add-item cover can be driven by the chosen
    /// list id (a bare `String` isn't `Identifiable`).
    private struct AddTarget: Identifiable { let id: String }
    @State private var now = Date()

    /// Combined chrome (progress bar, finish button) uses a neutral group tint;
    /// individual rows keep their own group's color via the badge.
    private let tint: Color = .green

    private var activeSessions: [ShoppingSession] { repo.combinedTripSessions }
    private var activeIds: [String] { activeSessions.map(\.id) }

    private var progress: SessionProgress {
        repo.combinedProgress(sessionIds: activeIds)
    }

    private var canManageTrip: Bool {
        !activeSessions.isEmpty && activeSessions.allSatisfy { repo.isStartedByCurrentUser($0) }
    }

    var body: some View {
        Group {
            if activeSessions.isEmpty {
                ContentUnavailableView("Trip ended", systemImage: "cart",
                                       description: Text("These shopping trips are no longer active."))
            } else {
                content
            }
        }
        .navigationTitle("Shopping")
        .navigationBarTitleDisplayMode(.inline)
        .postHogScreenView("Combined Shopping Session")
        .onChange(of: activeSessions.isEmpty) { _, ended in
            // Every trip ended out from under us — close any open sheets and bail.
            if ended {
                selectedItem = nil
                editingItem = nil
                replacingItem = nil
                showFinish = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        List {
            progressHeader

            if sortMode == .custom {
                Section {
                    ForEach(repo.combinedPendingItemsCustom(sessionIds: activeIds), id: \.combinedPendingRowID) { item in
                        shopItemButton(item)
                    }
                }
            } else {
                ForEach(repo.combinedPendingGroups(sessionIds: activeIds), id: \.category) { group in
                    Section {
                        ForEach(group.items, id: \.combinedPendingRowID) { item in
                            shopItemButton(item)
                        }
                    } header: {
                        CategoryHeader(category: group.category, count: group.items.count)
                    }
                }
            }

            let addedDuringTrip = repo.combinedAddedDuringTrip(sessionIds: activeIds)
            if !addedDuringTrip.isEmpty {
                Section {
                    ForEach(addedDuringTrip, id: \.combinedAddedRowID) { item in
                        shopItemButton(item)
                    }
                } header: {
                    Label("Added During Trip", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .textCase(nil)
                }
            }

            completedSection
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if canManageTrip {
                finishButton
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Organize", selection: $sortMode) {
                        Label("Categories", systemImage: "square.grid.2x2").tag(ListSortMode.category)
                        Label("My order", systemImage: "line.3.horizontal").tag(ListSortMode.custom)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: sortMode == .custom ? "line.3.horizontal" : "arrow.up.arrow.down")
                }
                .accessibilityLabel("Organize list")
                .onChange(of: sortMode) { _, _ in Haptics.selection() }

                Button { Haptics.tap(); presentAddItem() } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $selectedItem) { item in
            ShoppingItemDetailView(item: item, tint: badgeTint(for: item), canManageTrip: canManageTrip) { action in
                selectedItem = nil
                switch action {
                case .found:
                    markItem(item, as: .found)
                case .replace:
                    Haptics.selection()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        replacingItem = item
                    }
                case .skip:
                    markItem(item, as: .skipped)
                case .outOfStock:
                    markItem(item, as: .outOfStock)
                case .edit:
                    Haptics.selection()
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
        .sheet(item: $editingItem) { item in
            NavigationStack {
                EditItemView(item: item) { updated in
                    repo.update(updated)
                }
            }
        }
        .fullScreenCover(item: $addTarget) { target in
            AddItemSearchView(tint: addTargetTint(listId: target.id), targetListId: target.id)
        }
        .navigationDestination(isPresented: $showFinish) {
            CombinedSessionSummaryView(sessionIds: finishingIds, endingTask: endingTask) { onExit() }
        }
        .confirmationDialog("Add to which list?", isPresented: $showAddGroupPicker, titleVisibility: .visible) {
            ForEach(activeSessions, id: \.id) { session in
                Button(repo.households.first { $0.id == session.householdId }?.name
                       ?? String(localized: "List")) {
                    selectAddTarget(session)
                }
            }
        }
        .alert("Finish all lists?", isPresented: $showFinishConfirm) {
            Button("Finish Anyway") {
                Haptics.selection()
                beginFinishing(activeIds)
            }
            Button("Keep Shopping", role: .cancel) {}
        } message: {
            Text("^[\(progress.remaining) item](inflect: true) still across these lists. Finish the trip anyway?")
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            now = Date()
        }
    }

    // MARK: - Rows

    private func shopItemButton(_ item: GroceryItem) -> some View {
        Button {
            Haptics.selection()
            selectedItem = item
        } label: {
            ShopItemRow(item: item, member: repo.member(for: item),
                        tint: badgeTint(for: item), groupBadge: badge(for: item))
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: canManageTrip) {
            if canManageTrip {
                Button { markItem(item, as: .found) } label: {
                    Label("Found", systemImage: "checkmark")
                }
                .tint(.green)
            } else {
                Button {
                    Haptics.selection()
                    editingItem = item
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(badgeTint(for: item))
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if canManageTrip {
                Button {
                    Haptics.selection()
                    replacingItem = item
                } label: {
                    Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(.blue)
                Button { markItem(item, as: .skipped) } label: {
                    Label("Skip", systemImage: "arrow.uturn.forward")
                }
                .tint(.orange)
                Button { markItem(item, as: .outOfStock) } label: {
                    Label("Out", systemImage: "xmark")
                }
                .tint(.red)
            }
        }
    }

    private func household(for item: GroceryItem) -> Household? {
        repo.households.first { $0.id == item.householdId }
    }

    private func badge(for item: GroceryItem) -> ShopItemRow.GroupBadge? {
        guard let house = household(for: item) else { return nil }
        return .init(name: house.name, tint: house.tint, icon: house.icon)
    }

    private func badgeTint(for item: GroceryItem) -> Color {
        household(for: item)?.tint ?? tint
    }

    // MARK: - Add item (asks which group)

    private func presentAddItem() {
        if activeSessions.count == 1, let only = activeSessions.first {
            selectAddTarget(only)
        } else {
            showAddGroupPicker = true
        }
    }

    /// Presents the add flow targeting the chosen group's list explicitly, so no
    /// global selection change is needed (the add UI writes to `targetListId`,
    /// not the ambient `currentList`). The added item surfaces under "Added
    /// During Trip" because its `createdAt` is after that session started.
    private func selectAddTarget(_ session: ShoppingSession) {
        Haptics.tap()
        addTarget = AddTarget(id: session.listId)
    }

    private func addTargetTint(listId: String) -> Color {
        guard let session = activeSessions.first(where: { $0.listId == listId }) else { return tint }
        return repo.households.first { $0.id == session.householdId }?.tint ?? tint
    }

    // MARK: - Mark

    private func markItem(_ item: GroceryItem, as status: ItemStatus, replacement: String? = nil) {
        feedback(for: status)
        switch status {
        case .found:
            PostHogSDK.shared.capture("item_marked_found", properties: [
                "item_name": item.name,
                "category": item.category.rawValue,
                "combined_trip": true,
            ])
        case .outOfStock:
            PostHogSDK.shared.capture("item_marked_out_of_stock", properties: [
                "item_name": item.name,
                "category": item.category.rawValue,
                "combined_trip": true,
            ])
        default:
            break
        }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            repo.mark(item, as: status, replacement: replacement)
        }
    }

    private func feedback(for status: ItemStatus) {
        switch status {
        case .found, .replaced:
            Haptics.success()
        case .outOfStock, .skipped, .removed:
            Haptics.warning()
        case .needed:
            Haptics.selection()
        }
    }

    // MARK: - Progress header

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(storeLabel)
                        .font(.title2.bold())
                    HStack(spacing: 6) {
                        AvatarStack(members: repo.combinedShoppers(sessionIds: activeIds))
                        Text("^[\(activeSessions.count) list](inflect: true) · combined trip")
                            .font(.caption).foregroundStyle(.secondary)
                            .id(now)
                    }
                }
                Spacer()
            }
            ProgressView(value: Double(progress.total - progress.remaining), total: Double(max(progress.total, 1)))
                .tint(tint)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: progress.remaining)
            HStack(spacing: 16) {
                TripStat("\(progress.remaining)", String(localized: "left"))
                TripStat("\(progress.found)", String(localized: "found"))
                if progress.replaced > 0 { TripStat("\(progress.replaced)", String(localized: "replaced")) }
                if progress.outOfStock > 0 { TripStat("\(progress.outOfStock)", String(localized: "unavailable")) }
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
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
    }

    private var storeLabel: String {
        let stores = Set(activeSessions.compactMap { session -> String? in
            let trimmed = session.storeName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        })
        if stores.count == 1, let only = stores.first { return only }
        if stores.isEmpty { return String(localized: "Store not set") }
        return String(localized: "Multiple stores")
    }

    // MARK: - Completed section

    @ViewBuilder
    private var completedSection: some View {
        let handled = repo.combinedHandledItems(sessionIds: activeIds)
        if !handled.isEmpty {
            Section {
                Button {
                    Haptics.selection()
                    withAnimation(reduceMotion ? nil : .default) { showCompleted.toggle() }
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
                .accessibilityHint(showCompleted ? String(localized: "Collapse completed items") : String(localized: "Expand completed items"))

                if showCompleted {
                    ForEach(handled, id: \.combinedHandledRowID) { item in
                        CombinedCompletedItemRow(item: item, badge: badge(for: item), canManageTrip: canManageTrip) {
                            markItem(item, as: .needed)
                        } onEdit: {
                            editingItem = item
                        }
                    }
                }
            }
        }
    }

    // MARK: - Finish button

    /// Starts ending every list's session in the background and pushes the
    /// Trip Summary immediately — the shopper doesn't wait on this.
    private func beginFinishing(_ ids: [String]) {
        finishingIds = ids
        endingTask = Task { await repo.finishCombinedShopping(sessionIds: ids) }
        showFinish = true
    }

    private var finishButton: some View {
        let allHandled = progress.remaining == 0
        return Button {
            Haptics.selection()
            if allHandled {
                beginFinishing(activeIds)
            } else {
                showFinishConfirm = true
            }
        } label: {
            Label("Finish Shopping", systemImage: "flag.checkered")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .grocerGlassButton(prominent: true)
        .tint(tint)
        .controlSize(.large)
        .opacity(allHandled ? 1 : 0.55)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: allHandled)
        .accessibilityHint(allHandled ? "" : String(localized: "\(progress.remaining) items still remaining"))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

private extension GroceryItem {
    var combinedPendingRowID: String { "combined-pending-\(id)" }
    var combinedAddedRowID: String { "combined-added-\(id)" }
    var combinedHandledRowID: String { "combined-handled-\(id)-\(status.rawValue)" }
}

/// A small horizontal stack of shopper avatars for the combined header.
private struct AvatarStack: View {
    let members: [HouseholdMember]

    var body: some View {
        HStack(spacing: -8) {
            ForEach(members.prefix(4), id: \.id) { member in
                MemberAvatarView(member: member, size: 22)
                    .overlay(Circle().strokeBorder(Color(.systemGroupedBackground), lineWidth: 1.5))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Completed row for the combined view — like the single-session one but adds a
/// group badge so it's clear which list each handled item belongs to.
private struct CombinedCompletedItemRow: View {
    let item: GroceryItem
    let badge: ShopItemRow.GroupBadge?
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
                HStack(spacing: 6) {
                    if let badge {
                        Label(badge.name, systemImage: badge.icon)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(badge.tint)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Menu {
                if canManageTrip {
                    Button { onUndo() } label: {
                        Label("Put Back on List", systemImage: "arrow.uturn.backward")
                    }
                }
                Button {
                    Haptics.selection()
                    onEdit()
                } label: {
                    Label("Edit Item", systemImage: "pencil")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(String(localized: "Options for \(item.name)"))
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
        case .replaced:
            let replacement = item.replacementItemName ?? String(localized: "alternative")
            return String(localized: "Replaced with \(replacement)")
        default:
            return item.status.localizedName
        }
    }
}
