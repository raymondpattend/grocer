import PostHog
import SwiftUI

/// Planning screen for the current group (each group is its own list, with a
/// store, icon, and color theme). Pushed from HomeView; the system back button
/// returns to the group grid. Items are grouped by category with a Start
/// Shopping CTA themed to the group.
struct GroceryListView: View {
    @Environment(GroceryRepository.self) private var repo

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

    private var tint: Color { repo.currentHousehold?.tint ?? .green }

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
                    withAnimation { storeBannerHidden = true }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if let session = repo.activeSession {
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
                ForEach(repo.pendingItemGroups, id: \.category) { group in
                    Section {
                        ForEach(group.items) { item in
                            itemButton(item)
                        }
                    } header: {
                        CategoryHeader(category: group.category, count: group.items.count)
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
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .refreshable { await repo.manualRefresh() }
        .safeAreaInset(edge: .top, spacing: 0) {
            CloudIssueChip(issue: repo.cloudIssue)
        }
        .navigationTitle(repo.currentHousehold?.name ?? String(localized: "Grocer"))
        .navigationBarTitleDisplayMode(.large)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled()
        .tint(tint)
        .navigationDestination(item: $sessionForNav) { session in
            ShoppingSessionView(sessionId: session.id) { sessionForNav = nil }
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
                if canSendHeadsUp {
                    Button { Haptics.tap(); showHeadsUp = true } label: {
                        Image(systemName: "bell.and.waves.left.and.right")
                    }
                    .accessibilityLabel("Give the group a heads-up")
                }
                if repo.isOwnerOfCurrentGroup && repo.currentHousehold != nil {
                    Button { Haptics.tap(); showingInvite = true } label: { Image(systemName: "person.crop.circle.badge.plus") }
                }
                Button { Haptics.tap(); showingHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                Button { Haptics.tap(); showingSettings = true } label: { Image(systemName: "gearshape") }
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
        .onChange(of: repo.currentHousehold?.id) { _, _ in storeBannerHidden = false }
        .sheet(isPresented: $showStartTrip) {
            StartTripSheet(
                groupName: repo.currentHousehold?.name ?? String(localized: "this list"),
                itemCount: repo.pendingItems.count,
                tint: tint
            ) {
                guard let list = repo.currentList else { return }
                Task {
                    await repo.startShopping(list: list)
                    sessionForNav = repo.activeSession
                }
            }
            .presentationDetents([.height(300)])
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

    private func removeItem(_ item: GroceryItem) {
        Haptics.warning()
        PostHogSDK.shared.capture("item_deleted", properties: [
            "item_name": item.name,
            "category": item.category.rawValue,
        ])
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
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
    var tint: Color = .green
    let onStart: () -> Void

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
    }

    private var headline: String {
        if let storeName = session.storeName {
            return String(localized: "\(session.startedByDisplayName) is shopping at \(storeName)")
        }
        return String(localized: "\(session.startedByDisplayName) is shopping")
    }
}
