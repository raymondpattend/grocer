import PostHog
import SwiftUI

/// Home screen: every group (each group is its own grocery list) shown as a
/// card. Tapping a group zooms into its list. Groups shared into this account
/// can be split out into a "Shared with Me" section.
struct HomeView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(SubscriptionStore.self) private var subscriptions

    @AppStorage("home.separateShared") private var separateShared = false

    @State private var path: [String] = []
    @State private var showNewGroup = false
    @State private var showProPaywall = false
    @State private var editingGroup: Household?
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
                    .animation(.snappy(duration: 0.35), value: separateShared)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await repo.manualRefresh() }
            .navigationTitle("My Groups")
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SyncStatusBar(state: repo.syncState, pendingCount: repo.pendingCloudWriteCount)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Haptics.selection()
                        withAnimation(.snappy) { separateShared.toggle() }
                    } label: {
                        Image(systemName: separateShared ? "person.2.fill" : "person.2")
                    }
                    .accessibilityLabel("Separate shared groups")

                    Button {
                        addGroupTapped()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(isAtFreeOwnedGroupLimit
                                        ? String(localized: "Upgrade to add group")
                                        : String(localized: "New group"))
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
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if repo.households.isEmpty {
            if repo.hasCompletedInitialLoad {
                ContentUnavailableView("No groups yet", systemImage: "person.2",
                                       description: Text("Create a group to start planning."))
                .padding(.top, 40)
            } else {
                skeleton
            }
        } else if separateShared && !sharedHouseholds.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                groupSection(title: String(localized: "My Groups"), households: ownedHouseholds, includesProUpsell: true)
                groupSection(title: String(localized: "Shared with Me"), households: sharedHouseholds)
            }
        } else if isAtFreeOwnedGroupLimit {
            VStack(spacing: 14) {
                groupCollection(ownedHouseholds)
                proGroupUpsellCard
                if !sharedHouseholds.isEmpty {
                    groupCollection(sharedHouseholds)
                }
            }
        } else {
            groupCollection(repo.households)
        }
    }

    @ViewBuilder
    private func groupSection(title: String,
                              households: [Household],
                              includesProUpsell: Bool = false) -> some View {
        if !households.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                groupCollection(households)
                if includesProUpsell && isAtFreeOwnedGroupLimit {
                    proGroupUpsellCard
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
                Image(systemName: "sparkle")
                    .font(.system(size: 24, weight: .semibold))
                    .offset(x: -22, y: -22)
                Image(systemName: "lock.open")
                    .font(.system(size: 42, weight: .medium))
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
        Button {
            open(house)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                itemPreview(house)

                // Label: group name + item count, anchored bottom-left.
                VStack(alignment: .leading, spacing: 1) {
                    Text(house.name)
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text("^[\(pendingCount(for: house)) item](inflect: true)")
                        if hasActiveSession(house) {
                            Image(systemName: "cart.fill")
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
        .groupZoomSource(id: house.id, in: zoomNamespace)
        .contextMenu { contextActions(house) }
        .overlay(alignment: .topTrailing) { cardMenu(house) }
    }

    /// The first few pending items, as a mini read-only list that fades out at
    /// the bottom edge so the list reads as continuing past the card.
    @ViewBuilder
    private func itemPreview(_ house: Household) -> some View {
        let items = previewItems(for: house)
        if items.isEmpty {
            Text("Nothing on the list")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    HStack(spacing: 7) {
                        ProductImageView(itemName: item.name, size: 22)
                        Text(item.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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

    /// Top-right accessory: an ellipsis menu for groups you own, or a "shared"
    /// badge for groups shared into your account.
    @ViewBuilder
    private func cardMenu(_ house: Household) -> some View {
        if repo.isSharedWithMe(house) {
            Image(systemName: "person.2.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Shared with you")
        } else {
            Menu {
                contextActions(house)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    /// Shared actions for both the ellipsis menu and the press-and-hold context menu.
    @ViewBuilder
    private func contextActions(_ house: Household) -> some View {
        if !repo.isSharedWithMe(house) {
            editButton(house)
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
            Label("Edit Group", systemImage: "paintbrush")
        }
    }

    private func open(_ house: Household) {
        Haptics.selection()
        repo.selectHousehold(house.id)
        path.append(house.id)
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

    private var skeleton: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                  spacing: 14) {
            ForEach(0..<4, id: \.self) { _ in
                ShimmerRect(cornerRadius: 20)
                    .frame(height: Self.cardHeight)
            }
        }
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
            households: households, lists: lists, items: items
        ))
}
#endif
