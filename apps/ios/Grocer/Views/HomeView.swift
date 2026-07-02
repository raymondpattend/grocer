import PostHog
import SwiftUI

/// Home screen: every group (each group is its own grocery list) shown as a
/// card. Tapping a group zooms into its list. Groups shared into this account
/// can be split out into a "Shared with Me" section.
struct HomeView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("home.separateShared") private var separateShared = true
    // Pinned group ids, newline-joined (ids are UUIDs, so never contain "\n").
    @AppStorage("home.pinnedHouseholdIds") private var pinnedHouseholdIdsRaw = ""

    @State private var path: [String] = []
    @State private var showNewGroup = false
    @State private var showProPaywall = false
    @State private var editingGroup: Household?
    @State private var collapsedSharers: Set<String> = []
    @State private var didHapticOnLoad = false
    @State private var pendingRouteHouseholdId: String?
    @Namespace private var zoomNamespace

    private static let freeOwnedGroupLimit = 2
    private static let proAccent = Color(red: 0.06, green: 0.72, blue: 0.51)

    private var ownedHouseholds: [Household] {
        repo.households.filter { !repo.isSharedWithMe($0) }
    }

    private var sharedHouseholds: [Household] {
        repo.households.filter { repo.isSharedWithMe($0) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: separateShared)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await repo.manualRefresh() }
            .navigationTitle("My Lists")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Only worth offering the "Separate shared lists" toggle when
                    // the account actually has groups shared into it (where it
                    // isn't the owner) — otherwise there's nothing to separate.
                    if !sharedHouseholds.isEmpty {
                        Button {
                            Haptics.selection()
                            withAnimation(reduceMotion ? nil : .snappy) { separateShared.toggle() }
                        } label: {
                            FAImage(separateShared ? "person.2.fill" : "person.2")
                        }
                        .accessibilityLabel("Separate shared lists")
                    }

                    Button {
                        addGroupTapped()
                    } label: {
                        FAImage("plus")
                    }
                    .accessibilityLabel(isAtFreeOwnedGroupLimit
                                        ? String(localized: "Upgrade to add list")
                                        : String(localized: "New list"))
                }
            }
            .navigationDestination(for: String.self) { householdId in
                GroceryListView()
                    .groupZoomDestination(id: householdId, in: zoomNamespace)
            }
            // If a group the user has drilled into disappears — they left it,
            // deleted it as owner, or were kicked while the settings menu was
            // open — pop back to home. Emptying the path also tears down any
            // pushed Settings screen sitting on top of that group's list.
            .onChange(of: repo.households.map(\.id)) { _, ids in
                let valid = Set(ids)
                if let firstStale = path.firstIndex(where: { !valid.contains($0) }) {
                    path.removeSubrange(firstStale...)
                }
                openPendingRouteIfReady()
            }
            // Tap when the first load lands, so the skeleton handing off to real
            // content has a tactile "ready" beat. Only fires once, and only if
            // we hadn't already finished loading by the time the view appeared.
            .onAppear {
                didHapticOnLoad = repo.hasCompletedInitialLoad
                for householdId in GroupNavigationCoordinator.shared.consumePendingHouseholdIds() {
                    requestOpenHousehold(householdId)
                }
            }
            .onChange(of: repo.hasCompletedInitialLoad) { _, loaded in
                if loaded, !didHapticOnLoad {
                    didHapticOnLoad = true
                    Haptics.success()
                }
                openPendingRouteIfReady()
            }
            .onReceive(NotificationCenter.default.publisher(for: GroupNavigationCoordinator.openGroupNotification)) { notification in
                let pending = GroupNavigationCoordinator.shared.consumePendingHouseholdIds()
                if !pending.isEmpty {
                    pending.forEach(requestOpenHousehold)
                    return
                }

                guard let householdId = notification.userInfo?[GroupNavigationCoordinator.householdIdUserInfoKey] as? String else {
                    return
                }
                requestOpenHousehold(householdId)
            }
            .sheet(isPresented: $showNewGroup) {
                NavigationStack {
                    GroupEditorView(group: nil) { created in
                        path.append(created.id)
                    }
                }
            }
            .sheet(item: $editingGroup) { group in NavigationStack { GroupEditorView(group: group) } }
            .fullScreenCover(isPresented: $showProPaywall) {
                GrocerProPaywallView(context: .groupLimit)
            }
            // Names this screen for PostHog so dead/rage-click reports group
            // under "My Lists" instead of an opaque SwiftUI view identifier.
            .postHogScreenView("My Lists")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if repo.households.isEmpty {
            if repo.hasCompletedInitialLoad {
                ContentUnavailableView {
                    FALabel("No lists yet", icon: "person.2")
                } description: {
                    Text("Create a list to start planning.")
                }
                .padding(.top, 40)
            } else {
                skeleton
            }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                if !pinnedHouseholds.isEmpty {
                    pinnedSection
                }
                unpinnedContent
            }
        }
    }

    /// Pinned groups float to the very top of the page, above every section,
    /// in the order they appear in the list.
    @ViewBuilder
    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(String(localized: "Pinned"))
            groupCollection(pinnedHouseholds)
        }
    }

    /// Everything that isn't pinned, laid out in its usual sections.
    @ViewBuilder
    private var unpinnedContent: some View {
        if separateShared {
            ownedSection
            if !unpinned(sharedHouseholds).isEmpty {
                sharedBySharerSection
            }
        } else if isAtFreeOwnedGroupLimit {
            VStack(spacing: 14) {
                let owned = unpinned(ownedHouseholds)
                if !owned.isEmpty {
                    groupCollection(owned)
                }
                proGroupUpsellCard
                let shared = unpinned(sharedHouseholds)
                if !shared.isEmpty {
                    groupCollection(shared)
                }
            }
        } else {
            groupCollection(unpinned(repo.households))
        }
    }

    /// Owned lists under "Separate shared lists". Keeps the genuine "no owned
    /// lists" hint, but stays quiet when the section is empty only because the
    /// owned lists are all pinned up top.
    @ViewBuilder
    private var ownedSection: some View {
        let owned = unpinned(ownedHouseholds)
        if !owned.isEmpty {
            groupSection(households: owned, includesProUpsell: true)
        } else if ownedHouseholds.isEmpty {
            groupSection(households: [], includesProUpsell: true)
        } else if isAtFreeOwnedGroupLimit {
            proGroupUpsellCard
        }
    }

    private func groupSection(title: String? = nil,
                              households: [Household],
                              includesProUpsell: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                sectionHeader(title)
            }
            if households.isEmpty {
                emptySectionPlaceholder(String(localized: "No lists here yet."))
            } else {
                groupCollection(households)
            }
            if includesProUpsell && isAtFreeOwnedGroupLimit {
                proGroupUpsellCard
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func emptySectionPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
    }

    // MARK: - Shared groups, broken out by who shared them

    /// One sharer (the owner of the shared zone) and the groups they shared
    /// into this account. Keyed by CloudKit zone owner so groups from the same
    /// person collapse under a single header even across multiple groups.
    private struct SharerGroup: Identifiable {
        let id: String
        let member: HouseholdMember?
        let households: [Household]
    }

    private var sharedGroupsBySharer: [SharerGroup] {
        let grouped = Dictionary(grouping: unpinned(sharedHouseholds)) { $0.recordOwnerName ?? "shared" }
        return grouped
            .map { key, houses in
                let sorted = houses.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                // The owner member carries the sharer's name + avatar; look it up
                // from whichever of their groups already has it synced.
                let owner = sorted.compactMap { repo.member(id: $0.ownerMemberId, householdId: $0.id) }.first
                return SharerGroup(id: key, member: owner, households: sorted)
            }
            .sorted { ($0.member?.displayName ?? "~") < ($1.member?.displayName ?? "~") }
    }

    @ViewBuilder
    private var sharedBySharerSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(String(localized: "Shared with Me"))
            if sharedGroupsBySharer.isEmpty {
                emptySectionPlaceholder(String(localized: "Nothing shared with you yet."))
            } else {
                ForEach(sharedGroupsBySharer) { sharer in
                    let collapsed = collapsedSharers.contains(sharer.id)
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            Haptics.selection()
                            withAnimation(reduceMotion ? nil : .snappy) {
                                if collapsed {
                                    collapsedSharers.remove(sharer.id)
                                } else {
                                    collapsedSharers.insert(sharer.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                MemberAvatarView(member: sharer.member, size: 26)
                                Text(sharer.member?.displayName ?? String(localized: "Shared"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(sharer.member?.displayName ?? String(localized: "Shared"))
                        .accessibilityHint(collapsed
                                           ? String(localized: "Expand shared lists")
                                           : String(localized: "Collapse shared lists"))

                        if !collapsed {
                            groupCollection(sharer.households)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                        }
                    }
                }
            }
        }
    }

    private func groupCollection(_ households: [Household]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                  spacing: 14) {
            ForEach(households) { house in
                gridCard(house)
            }
        }
    }

    /// Fixed card height so every grid tile lines up regardless of how many
    /// preview items it shows.
    private static let cardHeight: CGFloat = 190

    // MARK: - Pro upsell

    private var isAtFreeOwnedGroupLimit: Bool {
        ownedHouseholds.count == Self.freeOwnedGroupLimit && !subscriptions.hasGrocerPro
    }

    private var groupUpsellCopy: GrocerProGroupUpsellCopy {
        subscriptions.homeGroupLimitCardCopy
    }

    private var proGroupUpsellCard: some View {
        Button {
            Haptics.selection()
            PostHogSDK.shared.capture("pro_upsell_tapped", properties: [
                "source": "home_group_limit_card",
            ])
            showProPaywall = true
        } label: {
            proGroupUpsellCardContent
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var proGroupUpsellCardContent: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(groupUpsellCopy.title)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Text(groupUpsellCopy.subtitle)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
            }

            Spacer(minLength: 12)

            ZStack {
                FAImage("sparkle", size: 24)
                    .offset(x: -22, y: -22)
                FAImage("lock.open", size: 42)
                    .rotationEffect(.degrees(8))
            }
            .foregroundStyle(.white)
            .frame(width: 74, height: 62)
        }
        .padding(.leading, 20)
        .padding(.trailing, 20)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(red: 0.05, green: 0.06, blue: 0.05))

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Self.proAccent.opacity(0.72), .clear],
                        center: .bottomTrailing,
                        startRadius: 4,
                        endRadius: 190
                    )
                )

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Color.green.opacity(0.28), .clear],
                        center: UnitPoint(x: 0.62, y: 0.86),
                        startRadius: 0,
                        endRadius: 150
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Self.proAccent.opacity(0.34), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: Self.proAccent.opacity(0.18), radius: 20, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(groupUpsellCopy.accessibilityLabel)
    }

    // MARK: - Grid card

    private func gridCard(_ house: Household) -> some View {
        let count = pendingCount(for: house)
        let isActive = hasActiveSession(house)
        let sharedLabel: String? = {
            if repo.isSharedWithMe(house) { return String(localized: "Shared with you") }
            if repo.isSharedWithOthers(house) { return String(localized: "Shared with others") }
            return nil
        }()
        let cardLabel = [
            house.name,
            count == 1 ? String(localized: "1 item") : String(localized: "\(count) items"),
            isActive ? String(localized: "Shopping in progress") : nil,
            isPinned(house) ? String(localized: "Pinned") : nil,
            sharedLabel,
        ].compactMap { $0 }.joined(separator: ", ")

        return Button {
            open(house)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                itemPreview(house, reserveBadgeSpace: showsSharedBadge(house))

                // Label: group name + item count, anchored bottom-left.
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(house.name)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isPinned(house) {
                            FAImage("pin.fill", relativeTo: .caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }

                    HStack(spacing: 4) {
                        Text("^[\(pendingCount(for: house)) item](inflect: true)")
                        if hasActiveSession(house) {
                            FAImage("cart.fill")
                                .foregroundStyle(house.tint)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(height: Self.cardHeight)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.6), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(cardLabel)
        .groupZoomSource(id: house.id, in: zoomNamespace)
        .contextMenu { contextActions(house) }
        .overlay(alignment: .topTrailing) { sharedBadge(house) }
    }

    /// The first few pending items, as a mini read-only list that fades out at
    /// the bottom edge so the list reads as continuing past the card.
    @ViewBuilder
    private func itemPreview(_ house: Household, reserveBadgeSpace: Bool) -> some View {
        let items = previewItems(for: house)
        if items.isEmpty {
            Text("Nothing on the list")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 7) {
                        ProductImageView(itemName: item.name, size: 22)
                        Text(item.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    // The shared badge sits in the top-right corner over the
                    // first row only; inset that row so a long name ellipsizes
                    // before it slides under the icon.
                    .padding(.trailing, (reserveBadgeSpace && index == 0) ? 32 : 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.65),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
    }

    /// True for groups shared into this account *and* owned groups shared out
    /// to other people — both wear the two-person badge.
    private func showsSharedBadge(_ house: Household) -> Bool {
        repo.isSharedWithMe(house) || repo.isSharedWithOthers(house)
    }

    /// Top-right accessory for shared groups.
    @ViewBuilder
    private func sharedBadge(_ house: Household) -> some View {
        if showsSharedBadge(house) {
            FAImage("person.2.fill", relativeTo: .subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
        }
    }

    /// Press-and-hold actions for group cards. Every group can be pinned;
    /// owned groups can also be edited.
    @ViewBuilder
    private func contextActions(_ house: Household) -> some View {
        pinButton(house)
        if !repo.isSharedWithMe(house) {
            editButton(house)
        }
    }

    private func pinButton(_ house: Household) -> some View {
        let pinned = isPinned(house)
        return Button {
            Haptics.selection()
            withAnimation(reduceMotion ? nil : .snappy) { togglePin(house) }
        } label: {
            FALabel(pinned ? "Unpin" : "Pin to Top",
                  icon: pinned ? "pin.slash" : "pin")
        }
    }

    // MARK: - Actions / derived

    private func editButton(_ house: Household) -> some View {
        Button {
            // GroupEditorView saves against the current group, so select first.
            Haptics.selection()
            repo.selectHousehold(house.id)
            editingGroup = house
        } label: {
            FALabel("Edit List", icon: "paintbrush")
        }
    }

    private func open(_ house: Household) {
        Haptics.selection()
        repo.selectHousehold(house.id)
        path.append(house.id)
    }

    private func requestOpenHousehold(_ householdId: String) {
        pendingRouteHouseholdId = householdId
        openPendingRouteIfReady()
    }

    private func openPendingRouteIfReady() {
        guard let householdId = pendingRouteHouseholdId,
              repo.households.contains(where: { $0.id == householdId }) else {
            return
        }

        pendingRouteHouseholdId = nil
        repo.selectHousehold(householdId)
        if path != [householdId] {
            path = [householdId]
        }
    }

    private func addGroupTapped() {
        Haptics.tap()
        if isAtFreeOwnedGroupLimit {
            showProPaywall = true
        } else {
            showNewGroup = true
        }
    }

    private func pendingCount(for house: Household) -> Int {
        repo.pendingItems(forList: repo.list(for: house)?.id).count
    }

    private func previewItems(for house: Household) -> [GroceryItem] {
        Array(repo.pendingItems(forList: repo.list(for: house)?.id).prefix(4))
    }

    private func hasActiveSession(_ house: Household) -> Bool {
        repo.activeSession(for: repo.list(for: house)?.id) != nil
    }

    // MARK: - Pinning

    private var pinnedHouseholdIds: Set<String> {
        Set(pinnedHouseholdIdsRaw.split(separator: "\n").map(String.init))
    }

    /// All pinned groups, in list order, for the page-top Pinned section.
    private var pinnedHouseholds: [Household] {
        repo.households.filter { isPinned($0) }
    }

    private func unpinned(_ households: [Household]) -> [Household] {
        households.filter { !isPinned($0) }
    }

    private func isPinned(_ house: Household) -> Bool {
        pinnedHouseholdIds.contains(house.id)
    }

    private func togglePin(_ house: Household) {
        var ids = pinnedHouseholdIds
        if ids.contains(house.id) {
            ids.remove(house.id)
        } else {
            ids.insert(house.id)
        }
        pinnedHouseholdIdsRaw = ids.sorted().joined(separator: "\n")
    }

    private var skeleton: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                  spacing: 14) {
            ForEach(0..<4, id: \.self) { _ in
                skeletonCard
            }
        }
    }

    /// A plain shimmering tile the size of a real `gridCard`. We skeleton-load
    /// the card shapes only — no faked item rows, title, or count — so the
    /// hand-off to loaded content is a simple fade, not a layout reshuffle.
    private var skeletonCard: some View {
        ShimmerRect(cornerRadius: 20)
            .frame(height: Self.cardHeight)
            .accessibilityHidden(true)
    }
}

// MARK: - Zoom transition (iOS 18+, no-op on iOS 17)

private extension View {
    @ViewBuilder
    func groupZoomSource(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func groupZoomDestination(id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

#if DEBUG
#Preview("Home") {
    let households = [
        Household(id: "h1", name: "Family Groceries", ownerMemberId: "m1",
                  storeName: "Whole Foods", icon: "cart.fill",
                  colorTheme: .green, createdAt: .now, updatedAt: .now),
        Household(id: "h2", name: "Cottage", ownerMemberId: "m1",
                  storeName: nil, icon: "house.fill",
                  colorTheme: .blue, createdAt: .now, updatedAt: .now),
        Household(id: "h3", name: "Roommates", ownerMemberId: "m9",
                  storeName: "Trader Joe's", icon: "person.3.fill",
                  colorTheme: .orange, createdAt: .now, updatedAt: .now,
                  recordOwnerName: "someoneElse"),
    ]
    let members = [
        HouseholdMember(id: "m9", householdId: "h3", displayName: "Tom",
                        profileImageData: nil, iCloudUserRecordName: nil,
                        role: .owner, joinedAt: .now,
                        recordZoneName: nil, recordOwnerName: "someoneElse"),
    ]
    let lists = [
        GroceryList(id: "l1", householdId: "h1", name: "List",
                    createdAt: .now, updatedAt: .now, archived: false),
        GroceryList(id: "l3", householdId: "h3", name: "List",
                    createdAt: .now, updatedAt: .now, archived: false),
    ]
    let items = ["Milk", "Sourdough bread", "Eggs", "Bananas", "Olive oil"].enumerated().map { index, name in
        GroceryItem(id: "i\(index)", householdId: "h1", listId: "l1", name: name,
                    quantity: nil, category: .other, notes: nil,
                    requestedByMemberId: "m1", requestedByDisplayName: "Sarah",
                    status: .needed, priority: .normal,
                    replacementPreference: nil, replacementItemName: nil,
                    createdAt: .now, updatedAt: .now)
    } + [
        GroceryItem(id: "i10", householdId: "h3", listId: "l3", name: "Paper towels",
                    quantity: nil, category: .other, notes: nil,
                    requestedByMemberId: "m9", requestedByDisplayName: "Alex",
                    status: .needed, priority: .normal,
                    replacementPreference: nil, replacementItemName: nil,
                    createdAt: .now, updatedAt: .now),
    ]
    HomeView()
        .grocerPreviewEnvironment(repository: GrocerPreview.repository(
            households: households, members: members, lists: lists, items: items
        ))
}
#endif
