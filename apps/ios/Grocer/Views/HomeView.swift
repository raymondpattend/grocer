import SwiftUI

/// Home screen: every group (each group is its own grocery list) shown as a
/// card. Tapping a group zooms into its list. Groups shared into this account
/// can be split out into a "Shared with Me" section.
struct HomeView: View {
    @Environment(GroceryRepository.self) private var repo

    @AppStorage("home.separateShared") private var separateShared = false

    @State private var path: [String] = []
    @State private var showNewGroup = false
    @State private var editingGroup: Household?
    @Namespace private var zoomNamespace

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
                SyncStatusBar(state: repo.syncState)
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

                    Button { showNewGroup = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New group")
                }
            }
            .navigationDestination(for: String.self) { householdId in
                GroceryListView(navigationPath: $path, householdId: householdId)
                    .groupZoomDestination(id: householdId, in: zoomNamespace)
            }
            .sheet(isPresented: $showNewGroup) { NavigationStack { GroupEditorView(group: nil) } }
            .sheet(item: $editingGroup) { group in NavigationStack { GroupEditorView(group: group) } }
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
                groupSection(title: "My Groups", households: ownedHouseholds)
                groupSection(title: "Shared with Me", households: sharedHouseholds)
            }
        } else {
            groupCollection(repo.households)
        }
    }

    @ViewBuilder
    private func groupSection(title: String, households: [Household]) -> some View {
        if !households.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                groupCollection(households)
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
