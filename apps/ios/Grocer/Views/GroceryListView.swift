import PostHog
import SwiftUI

/// Planning screen for the current group (each group is its own list, with a
/// store, icon, and color theme). Pushed from HomeView; the system back button
/// returns to the group grid. Items are grouped by category with a Start
/// Shopping CTA themed to the group.
struct GroceryListView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showingAddSearch = false
    @State private var showingSettings = false
    @State private var showingInvite = false
    @State private var showingHistory = false
    @State private var sessionForNav: ShoppingSession?
    @State private var selectedItem: GroceryItem?
    @State private var showStartTrip = false
    @State private var showHeadsUp = false
    @State private var showStoreLink = false
    @State private var storeBannerHidden = false
    @State private var showMultiList = false
    @State private var combinedTrip: CombinedTripRef?
    /// Drives drag-to-reorder when the list uses custom ("My Order") organization.
    @State private var listEditMode: EditMode = .inactive

    /// The group's shared list organization. Writing flips it for everyone via the
    /// repo; leaving custom mode also exits any in-progress reordering.
    private var sortModeBinding: Binding<ListSortMode> {
        Binding(
            get: { repo.currentSortMode },
            set: { newValue in
                Haptics.selection()
                if newValue != .custom { listEditMode = .inactive }
                repo.setListSortMode(newValue)
            }
        )
    }

    /// Hashable wrapper so a combined trip (a set of session ids) can drive a
    /// `navigationDestination(item:)`.
    private struct CombinedTripRef: Hashable {
        let sessionIds: [String]
    }

    private var tint: Color { repo.currentHousehold?.tint ?? .green }

    /// The current group plus any other groups that shop at the same store —
    /// candidates for a combined trip. Empty when the current group has no store
    /// or no same-store siblings, which hides the multi-list entry point.
    private var sameStoreGroups: [Household] {
        guard let current = repo.currentHousehold,
              let store = current.storeName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !store.isEmpty else { return [] }
        let matches = repo.households.filter { house in
            house.id != current.id
                && house.storeName?.trimmingCharacters(in: .whitespacesAndNewlines) == store
        }
        return matches.isEmpty ? [] : ([current] + matches)
    }

    /// True when the current list's active session is part of the running
    /// combined trip — used to suppress the per-list banner in favor of the
    /// combined one.
    private var currentSessionInCombinedTrip: Bool {
        guard repo.hasActiveCombinedTrip, let session = repo.activeSession else { return false }
        return repo.combinedTripSessionIds.contains(session.id)
    }

    /// The heads-up button only appears when there's something on the list to
    /// shop for, and only when the group has someone else to notify.
    private var canSendHeadsUp: Bool {
        repo.currentHousehold != nil
            && !repo.pendingItems.isEmpty
            && repo.currentMembers.count > 1
    }

    /// Show the "link this list to a store" prompt until a store is linked or the
    /// member dismisses it (persisted per list, per device).
    private var showStoreBanner: Bool {
        guard let house = repo.currentHousehold, !house.hasLinkedStore, !storeBannerHidden else {
            return false
        }
        return !SettingsStore.shared.storeBannerDismissed(forHousehold: house.id)
    }

    var body: some View {
        List {
            if showStoreBanner {
                StoreLinkBanner(tint: tint) {
                    Haptics.selection()
                    showStoreLink = true
                } onClose: {
                    Haptics.tap()
                    if let id = repo.currentHousehold?.id {
                        SettingsStore.shared.setStoreBannerDismissed(true, forHousehold: id)
                    }
                    withAnimation(reduceMotion ? nil : .default) { storeBannerHidden = true }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if repo.hasActiveCombinedTrip {
                CombinedSessionBanner(
                    listCount: repo.combinedTripSessions.count,
                    progress: repo.combinedProgress(sessionIds: repo.combinedTripSessionIds),
                    shoppers: repo.combinedShoppers(sessionIds: repo.combinedTripSessionIds),
                    tint: tint
                ) {
                    Haptics.selection()
                    combinedTrip = CombinedTripRef(sessionIds: repo.combinedTripSessionIds)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if let session = repo.activeSession, !currentSessionInCombinedTrip {
                ActiveSessionBanner(
                    session: session,
                    progress: repo.progress(for: session),
                    shopper: repo.member(id: session.startedByMemberId, householdId: session.householdId),
                    tint: tint
                ) {
                    Haptics.selection()
                    sessionForNav = session
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if repo.currentList != nil {
                if repo.currentSortMode == .custom {
                    Section {
                        ForEach(repo.pendingItemsCustom) { item in
                            itemButton(item)
                        }
                        .onMove { source, destination in
                            Haptics.selection()
                            repo.reorderPendingItems(from: source, to: destination)
                        }
                    }
                } else {
                    ForEach(repo.pendingItemGroups, id: \.category) { group in
                        Section {
                            ForEach(group.items) { item in
                                itemButton(item)
                            }
                        } header: {
                            CategoryHeader(category: group.category, count: group.items.count)
                        }
                    }
                }

                if repo.pendingItems.isEmpty {
                    ContentUnavailableView("Nothing on the list", systemImage: "checklist",
                                           description: Text("Add what you need for \(repo.currentHousehold?.name ?? String(localized: "this list"))."))
                    .padding(.top, 40)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if !repo.pendingItems.isEmpty {
                    Text("^[\(repo.pendingItems.count) item](inflect: true)")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .padding(.bottom, 20)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if repo.currentHousehold != nil {
                // A group is selected but its list hasn't arrived yet — e.g.
                // a freshly joined shared group whose records are still
                // syncing. Showing "No lists yet" here would be misleading.
                ContentUnavailableView("Syncing list…", systemImage: "icloud.and.arrow.down",
                                       description: Text("\(repo.currentHousehold?.name ?? String(localized: "This list")) is on its way."))
                .padding(.top, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else if repo.hasCompletedInitialLoad {
                ContentUnavailableView("No lists yet", systemImage: "person.2",
                                       description: Text("Create a list to start planning."))
                .padding(.top, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                GroceryListSkeleton()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityHidden(true)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $listEditMode)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .refreshable { await repo.manualRefresh() }
        .navigationTitle(repo.currentHousehold?.name ?? String(localized: "Grocer"))
        .navigationBarTitleDisplayMode(.large)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled()
        .tint(tint)
        // Stable PostHog screen name (the nav title is the per-group name, which
        // would be high-cardinality) so rage/dead clicks roll up per screen.
        .postHogScreenView("Shopping List")
        .navigationDestination(item: $sessionForNav) { session in
            ShoppingSessionView(sessionId: session.id) { sessionForNav = nil }
        }
        .navigationDestination(item: $combinedTrip) { trip in
            CombinedShoppingSessionView(sessionIds: trip.sessionIds) { combinedTrip = nil }
        }
        .navigationDestination(item: $selectedItem) { item in
            ItemDetailView(item: item)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if repo.currentList != nil {
                VStack(alignment: .trailing, spacing: 12) {
                    floatingAddButton
                    if repo.activeSession == nil {
                        startShoppingButton
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { HapticBackButton() }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if repo.currentList != nil && !repo.pendingItems.isEmpty {
                    Menu {
                        Picker("Organize", selection: sortModeBinding) {
                            Label("Categories", systemImage: "square.grid.2x2").tag(ListSortMode.category)
                            Label("My order", systemImage: "line.3.horizontal").tag(ListSortMode.custom)
                        }
                        .pickerStyle(.inline)

                        if repo.currentSortMode == .custom {
                            Divider()
                            Button {
                                Haptics.tap()
                                withAnimation(reduceMotion ? nil : .default) {
                                    listEditMode = listEditMode.isEditing ? .inactive : .active
                                }
                            } label: {
                                Label(listEditMode.isEditing ? "Done" : "Reorder items",
                                      systemImage: listEditMode.isEditing ? "checkmark" : "arrow.up.arrow.down")
                            }
                        }
                    } label: {
                        Image(systemName: repo.currentSortMode == .custom ? "line.3.horizontal" : "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Organize list")
                }
                if canSendHeadsUp {
                    Button { Haptics.tap(); showHeadsUp = true } label: {
                        Image(systemName: "bell.and.waves.left.and.right")
                    }
                    .accessibilityLabel("Give the group a heads-up")
                }
                if repo.isOwnerOfCurrentGroup && repo.currentHousehold != nil {
                    Button { Haptics.tap(); showingInvite = true } label: { Image(systemName: "person.crop.circle.badge.plus") }
                        .accessibilityLabel("Invite to list")
                }
                if !repo.currentCompletedTrips.isEmpty {
                    Button { Haptics.tap(); showingHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Trip history")
                }
                Button { Haptics.tap(); showingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .fullScreenCover(isPresented: $showingAddSearch) {
            AddItemSearchView(tint: tint)
        }
        .sheet(isPresented: $showingInvite) {
            InviteToGroupSheet()
        }
        .navigationDestination(isPresented: $showingSettings) { SettingsView() }
        .navigationDestination(isPresented: $showingHistory) { TripHistoryView() }
        .sheet(isPresented: $showHeadsUp) {
            HeadsUpSheet()
        }
        .sheet(isPresented: $showStoreLink) {
            StoreLinkSheet()
        }
        .onChange(of: repo.currentHousehold?.id) { _, _ in
            storeBannerHidden = false
            openAddItemsIfRequested()
        }
        .onAppear { openAddItemsIfRequested() }
        .onReceive(NotificationCenter.default.publisher(for: GroupNavigationCoordinator.openGroupNotification)) { _ in
            openAddItemsIfRequested()
        }
        .sheet(isPresented: $showStartTrip) {
            StartTripSheet(
                groupName: repo.currentHousehold?.name ?? String(localized: "this list"),
                itemCount: repo.pendingItems.count,
                otherStoreListCount: sameStoreGroups.isEmpty ? 0 : sameStoreGroups.count - 1,
                tint: tint,
                onStart: {
                    guard let list = repo.currentList else { return }
                    Task {
                        await repo.startShopping(list: list)
                        sessionForNav = repo.activeSession
                    }
                },
                onShopMultiple: sameStoreGroups.isEmpty ? nil : { showMultiList = true }
            )
            .presentationDetents([.height(sameStoreGroups.isEmpty ? 300 : 360)])
        }
        .sheet(isPresented: $showMultiList) {
            MultiListSelectionSheet(candidates: sameStoreGroups, tint: tint) { lists in
                Task {
                    let ids = await repo.startCombinedShopping(lists: lists)
                    if ids.count >= 2 {
                        combinedTrip = CombinedTripRef(sessionIds: ids)
                    }
                }
            }
        }
    }

    private var startShoppingButton: some View {
        Button {
            Haptics.selection()
            showStartTrip = true
        } label: {
            Label("Start Trip", systemImage: "cart.fill")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .grocerGlassButton(prominent: true)
        .tint(tint)
        .controlSize(.large)
        .disabled(repo.pendingItems.isEmpty)
    }

    /// Small floating glass add button, parked above the Start Shopping CTA.
    private var floatingAddButton: some View {
        Button {
            Haptics.tap()
            showingAddSearch = true
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
                .padding(14)
        }
        .grocerGlassButton()
        .buttonBorderShape(.circle)
        .accessibilityLabel("Add item")
    }

    private func itemButton(_ item: GroceryItem) -> some View {
        Button {
            Haptics.selection()
            selectedItem = item
        } label: {
            GroceryItemRow(
                item: item,
                member: repo.member(for: item)
            )
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                removeItem(item)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    /// Opens the Add Items modal when this list was reached via the widget's Add
    /// button (a `grocer://group/<id>?action=add` deep link). One-shot.
    private func openAddItemsIfRequested() {
        guard let id = repo.currentHousehold?.id,
              GroupNavigationCoordinator.shared.consumePendingAdd(for: id) else { return }
        showingAddSearch = true
    }

    private func removeItem(_ item: GroceryItem) {
        Haptics.warning()
        PostHogSDK.shared.capture("item_deleted", properties: [
            "item_name": item.name,
            "category": item.category.rawValue,
        ])
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
            repo.delete(item)
        }
    }
}

// MARK: - Rows / banners

struct GroceryItemRow: View {
    let item: GroceryItem
    var member: HouseholdMember?

    var body: some View {
        HStack(spacing: 12) {
            ProductImageView(itemName: item.name, size: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let qty = item.quantity {
                        Text(Quantity.displayString(qty))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if item.notes != nil {
                        if item.quantity != nil {
                            Text("·").font(.caption).foregroundStyle(.tertiary)
                        }
                        Text(item.notes!)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            PriorityLabel(priority: item.priority)

            MemberAvatarView(member: member, size: 28)

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel)
    }

    private var rowAccessibilityLabel: String {
        var parts = [item.name]
        if let qty = item.quantity, !qty.isEmpty {
            parts.append(Quantity.displayString(qty))
        }
        if let notes = item.notes, !notes.isEmpty {
            parts.append(notes)
        }
        if item.priority != .normal {
            parts.append(String(localized: "\(item.priority.localizedName) priority"))
        }
        return parts.joined(separator: ", ")
    }
}

/// Displays a household member's profile picture as a small circular avatar.
///
/// The decoded image is produced off the main thread by `AvatarImageCache` and
/// held in `@State`, so it is NOT re-decoded on every `body` pass (which would
/// otherwise stall the main thread on each keystroke when the avatar appears in a
/// frequently-invalidated list).
struct MemberAvatarView: View {
    let member: HouseholdMember?
    var size: CGFloat = 28

    @State private var image: UIImage?

    private struct AvatarToken: Equatable {
        let id: String?
        let byteCount: Int
    }

    private var token: AvatarToken {
        AvatarToken(id: member?.id, byteCount: member?.profileImageData?.count ?? 0)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(.systemGray5))
                    .frame(width: size, height: size)
                    .overlay {
                        Text(initials(for: member))
                            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .accessibilityHidden(true)
        .task(id: token) {
            guard let data = member?.profileImageData else {
                image = nil
                return
            }
            let scale = UIScreen.main.scale
            image = await AvatarImageCache.shared.thumbnail(for: data, maxPixel: size * scale)
        }
    }

    private func initials(for member: HouseholdMember?) -> String {
        guard let name = member?.displayName, !name.isEmpty else { return "?" }
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(1)).uppercased()
    }
}

struct StartTripSheet: View {
    @Environment(\.dismiss) private var dismiss
    let groupName: String
    let itemCount: Int
    /// Number of *other* same-store lists that could join this trip. Drives the
    /// "Shop with other lists" affordance; zero hides it.
    var otherStoreListCount: Int = 0
    var tint: Color = .green
    let onStart: () -> Void
    /// Present only when there are same-store lists to combine.
    var onShopMultiple: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "cart.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(tint)
                    Text("Start Trip")
                        .font(.title2.bold())
                    Text("^[\(itemCount) item](inflect: true) on \(groupName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                Text("Ready to start a shopping trip?")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                VStack(spacing: 12) {
                    Button {
                        Haptics.success()
                        PostHogSDK.shared.capture("shopping_trip_started", properties: [
                            "group_name": groupName,
                            "item_count": itemCount,
                        ])
                        dismiss()
                        onStart()
                    } label: {
                        Label("Start Trip", systemImage: "cart.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .controlSize(.large)

                    if let onShopMultiple, otherStoreListCount > 0 {
                        Button {
                            Haptics.selection()
                            dismiss()
                            onShopMultiple()
                        } label: {
                            Label("Shop with ^[\(otherStoreListCount) other list](inflect: true)",
                                  systemImage: "square.stack.3d.up.fill")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .tint(tint)
                        .controlSize(.large)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Haptics.tap()
                        dismiss()
                    }
                }
            }
            .postHogScreenView("Start Trip")
        }
    }
}

struct ActiveSessionBanner: View {
    let session: ShoppingSession
    let progress: SessionProgress
    var shopper: HouseholdMember?
    var tint: Color = .green
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    MemberAvatarView(member: shopper, size: 48)
                    Image(systemName: "cart.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(tint))
                        .overlay(Circle().strokeBorder(Color(.systemGroupedBackground), lineWidth: 2))
                        .offset(x: 4, y: 4)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(String(localized: "\(progress.found) found · \(progress.remaining) left"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(headline), \(progress.found) found, \(progress.remaining) left"))
        .accessibilityHint(String(localized: "Opens shopping session"))
    }

    private var headline: String {
        if let storeName = session.storeName {
            return String(localized: "\(session.startedByDisplayName) is shopping at \(storeName)")
        }
        return String(localized: "\(session.startedByDisplayName) is shopping")
    }
}
