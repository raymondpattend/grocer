import PostHog
import SwiftUI
import Combine

/// Focused shopping mode — swipe-driven, one-handed item marking.
struct ShoppingSessionView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let sessionId: String
    var onExit: () -> Void = {}

    @State private var replacingItem: GroceryItem?
    @State private var editingItem: GroceryItem?
    @State private var selectedItem: GroceryItem?
    @State private var showCompleted = true
    @State private var showFinish = false
    @State private var showFinishConfirm = false
    /// Kicked off as soon as the shopper commits to finishing, so the session
    /// ends (and the shared Live Activity closes) for everyone right away
    /// instead of waiting on the Trip Summary's Done button.
    @State private var endingTask: Task<Void, Never>?
    @State private var showAddItem = false
    @State private var editingStore = false
    @State private var storeText = ""
    @State private var now = Date()

    /// Live session from the repo — always up to date.
    private var session: ShoppingSession? {
        repo.session(id: sessionId)
    }

    private var progress: SessionProgress {
        guard let session else { return SessionProgress(total: 0, found: 0, replaced: 0, outOfStock: 0, skipped: 0, remaining: 0) }
        return repo.progress(for: session)
    }

    private var tint: Color {
        guard let session else { return .green }
        return repo.households.first { $0.id == session.householdId }?.tint ?? .green
    }

    /// Two-way binding to the group's shared sort mode for this trip's list, so the
    /// shopper can switch between aisle categories and the manual order mid-trip.
    private func sortModeBinding(_ session: ShoppingSession) -> Binding<ListSortMode> {
        Binding(
            get: { repo.sortMode(forSession: session) },
            set: { newValue in
                Haptics.selection()
                repo.setListSortMode(newValue, forSession: session)
            }
        )
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
        .postHogScreenView("Shopping Session")
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

            if repo.sortMode(forSession: session) == .custom {
                Section {
                    ForEach(repo.pendingShoppingItemsCustom(session: session), id: \.shoppingPendingRowID) { item in
                        shopItemButton(item, canManageTrip: canManageTrip)
                    }
                }
            } else {
                ForEach(repo.pendingShoppingGroups(session: session), id: \.category) { group in
                    Section {
                        ForEach(group.items, id: \.shoppingPendingRowID) { item in
                            shopItemButton(item, canManageTrip: canManageTrip)
                        }
                    } header: {
                        CategoryHeader(category: group.category, count: group.items.count)
                    }
                }
            }

            let addedDuringTrip = repo.addedDuringTrip(session: session)
            if !addedDuringTrip.isEmpty {
                Section {
                    ForEach(addedDuringTrip, id: \.shoppingAddedRowID) { item in
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if canManageTrip {
                finishButton
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Organize", selection: sortModeBinding(session)) {
                        Label("Categories", systemImage: "square.grid.2x2").tag(ListSortMode.category)
                        Label("My order", systemImage: "line.3.horizontal").tag(ListSortMode.custom)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: repo.sortMode(forSession: session) == .custom ? "line.3.horizontal" : "arrow.up.arrow.down")
                }
                .accessibilityLabel("Organize list")

                Button { Haptics.tap(); showAddItem = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $selectedItem) { item in
            ShoppingItemDetailView(item: item, tint: tint, canManageTrip: canManageTrip) { action in
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
        .fullScreenCover(isPresented: $showAddItem) {
            AddItemSearchView(tint: tint)
        }
        .sheet(item: $editingItem) { item in
            NavigationStack {
                EditItemView(item: item) { updated in
                    repo.update(updated)
                }
            }
        }
        .navigationDestination(isPresented: $showFinish) {
            SessionSummaryView(session: session, endingTask: endingTask) { onExit() }
        }
        .alert("Finish shopping?", isPresented: $showFinishConfirm) {
            Button("Finish Anyway") {
                Haptics.selection()
                beginFinishing(session)
            }
            Button("Keep Shopping", role: .cancel) {}
        } message: {
            Text("^[\(progress.remaining) item](inflect: true) still on the list. Finish the trip anyway?")
        }
        .alert("Store", isPresented: $editingStore) {
            TextField("Store name", text: $storeText)
            Button("Save") {
                Haptics.success()
                repo.setStore(session, to: storeText)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Where are you shopping for this trip?")
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            now = Date()
        }
    }

    private func shopItemButton(_ item: GroceryItem, canManageTrip: Bool) -> some View {
        Button {
            Haptics.selection()
            selectedItem = item
        } label: {
            ShopItemRow(item: item, member: repo.member(for: item), tint: tint)
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
                .tint(tint)
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

    private func markItem(_ item: GroceryItem, as status: ItemStatus, replacement: String? = nil) {
        feedback(for: status)
        switch status {
        case .found:
            PostHogSDK.shared.capture("item_marked_found", properties: [
                "item_name": item.name,
                "category": item.category.rawValue,
            ])
        case .outOfStock:
            PostHogSDK.shared.capture("item_marked_out_of_stock", properties: [
                "item_name": item.name,
                "category": item.category.rawValue,
            ])
        default:
            break
        }
        // `.snappy` is critically damped (no overshoot). A bouncy spring made
        // rows visibly jump past their spot while a category Section collapsed
        // around them — `.snappy` keeps the section reflow clean.
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

    private func progressHeader(_ session: ShoppingSession, canManageTrip: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    if canManageTrip {
                        Button {
                            Haptics.selection()
                            storeText = session.storeName ?? ""
                            editingStore = true
                        } label: {
                            HStack(spacing: 6) {
                                Text(session.storeName ?? String(localized: "Set store")).font(.title2.bold())
                                    .foregroundStyle(session.storeName == nil ? .secondary : .primary)
                                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(session.storeName ?? String(localized: "Store not set"))
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
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: progress.remaining)
            HStack(spacing: 16) {
                stat("\(progress.remaining)", String(localized: "left"))
                stat("\(progress.found)", String(localized: "found"))
                if progress.replaced > 0 { stat("\(progress.replaced)", String(localized: "replaced")) }
                if progress.outOfStock > 0 { stat("\(progress.outOfStock)", String(localized: "unavailable")) }
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
                    ForEach(handled, id: \.shoppingHandledRowID) { item in
                        CompletedItemRow(item: item, canManageTrip: canManageTrip) {
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

    /// Starts ending the session in the background and pushes the Trip
    /// Summary immediately — the shopper doesn't wait on this.
    private func beginFinishing(_ session: ShoppingSession) {
        endingTask = Task { await repo.finishShopping(session) }
        showFinish = true
    }

    private var finishButton: some View {
        let allHandled = progress.remaining == 0
        return Button {
            Haptics.selection()
            guard let session else { return }
            if allHandled {
                beginFinishing(session)
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
        // Dimmed while items remain — still fully tappable, just signals there's
        // unfinished work. Goes fully opaque once everything's been handled.
        .opacity(allHandled ? 1 : 0.55)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: allHandled)
        .accessibilityHint(allHandled ? "" : String(localized: "\(progress.remaining) items still remaining"))
        .padding()
    }
}

private extension GroceryItem {
    var shoppingPendingRowID: String { "pending-\(id)" }
    var shoppingAddedRowID: String { "added-\(id)" }
    var shoppingHandledRowID: String { "handled-\(id)-\(status.rawValue)" }
}

// MARK: - Pending item row (swipe-driven)

struct ShopItemRow: View {
    let item: GroceryItem
    var member: HouseholdMember?
    var tint: Color = .green
    /// In a combined trip the row shows which group the item came from. `nil` for
    /// a single-list session, where every item belongs to the same group.
    var groupBadge: GroupBadge?

    struct GroupBadge {
        let name: String
        let tint: Color
        let icon: String
    }

    var body: some View {
        HStack(spacing: 12) {
            ProductImageView(itemName: item.name, size: 44)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.body.weight(.medium))
                if quantityText != nil || item.notes != nil {
                    HStack(spacing: 6) {
                        if let quantityText {
                            Text(quantityText)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .grocerLiquidGlass(in: Capsule())
                        }
                        if let notes = item.notes {
                            Text(notes)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            if item.priority != .normal {
                PriorityCircle(priority: item.priority, size: 10)
            }

            // The member who added the item, with the source group's icon as a
            // small corner badge during a combined trip (`groupBadge` is nil in a
            // single-list session, so the avatar shows alone).
            MemberAvatarView(member: member, size: 26)
                .overlay(alignment: .bottomTrailing) {
                    if let groupBadge {
                        Image(systemName: groupBadge.icon)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(Circle().fill(groupBadge.tint))
                            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                            .offset(x: 3, y: 3)
                    }
                }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    private var rowAccessibilityLabel: String {
        var parts = [item.name]
        if let qty = quantityText { parts.append(qty) }
        if let notes = item.notes, !notes.isEmpty { parts.append(notes) }
        if let groupBadge { parts.append(groupBadge.name) }
        if item.priority != .normal { parts.append(String(localized: "\(item.priority.localizedName) priority")) }
        return parts.joined(separator: ", ")
    }

    /// Quantity shown as a multiplier ("50x bunches") in the glass pill.
    private var quantityText: String? {
        guard let qty = item.quantity?.nilIfEmpty else { return nil }
        return Quantity.shoppingDisplayString(qty).nilIfEmpty
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

// MARK: - Shopping item detail (tap-to-open sheet)

struct ShoppingItemDetailView: View {
    @Environment(GroceryRepository.self) private var repo

    let item: GroceryItem
    var tint: Color = .green
    var canManageTrip = true
    let onAction: (Action) -> Void

    enum Action { case found, replace, skip, outOfStock, edit }

    private var member: HouseholdMember? {
        repo.member(for: item)
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
        .postHogScreenView("Shopping Item Detail")
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
                Label(item.category.localizedName, systemImage: item.category.systemImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.12), in: Capsule())

                if let qty = item.quantity {
                    Text(Quantity.displayString(qty))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.systemGray5), in: Capsule())
                }

                if item.priority != .normal {
                    PriorityLabel(priority: item.priority)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            item.priority.markerColor.opacity(0.12),
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
