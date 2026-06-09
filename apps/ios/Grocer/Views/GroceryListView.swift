import SwiftUI

/// Home / planning screen. A Group menu switches between groups (each group is
/// its own list, with a store, icon, and color theme). Items are grouped by
/// category with a Start Shopping CTA themed to the group.
struct GroceryListView: View {
    @Environment(GroceryRepository.self) private var repo

    @State private var showingAddSearch = false
    @State private var showingSettings = false
    @State private var sessionForNav: ShoppingSession?
    @State private var showNewGroup = false
    @State private var showEditGroup = false
    @State private var showStartTrip = false

    private var tint: Color { repo.currentHousehold?.tint ?? .green }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let session = repo.activeSession {
                    ActiveSessionBanner(session: session, progress: repo.progress(for: session), tint: tint) {
                        sessionForNav = session
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }

                if repo.currentList != nil {
                    ForEach(repo.pendingItems.groupedByCategory(), id: \.category) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            CategoryHeader(category: group.category)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 8)
                                .padding(.top, 4)

                            VStack(spacing: 0) {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                    NavigationLink(value: item) {
                                        GroceryItemRow(
                                            item: item,
                                            member: repo.currentMembers.first { $0.id == item.requestedByMemberId }
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    if index < group.items.count - 1 {
                                        Divider()
                                            .padding(.leading, 76)
                                    }
                                }
                            }
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.horizontal, 16)
                        }
                        .padding(.bottom, 12)
                    }

                    if repo.pendingItems.isEmpty {
                        ContentUnavailableView("Nothing on the list", systemImage: "checklist",
                                               description: Text("Add what you need for \(repo.currentHousehold?.name ?? "this group")."))
                        .padding(.top, 40)
                    }

                    if !repo.pendingItems.isEmpty {
                        Text("^[\(repo.pendingItems.count) item](inflect: true) on the list")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.bottom, 20)
                    }
                } else if repo.currentHousehold != nil {
                    // A group is selected but its list hasn't arrived yet — e.g.
                    // a freshly joined shared group whose records are still
                    // syncing. Showing "No groups yet" here would be misleading.
                    ContentUnavailableView("Syncing group…", systemImage: "icloud.and.arrow.down",
                                           description: Text("\(repo.currentHousehold?.name ?? "This group")'s list is on its way."))
                    .padding(.top, 40)
                } else if repo.hasCompletedInitialLoad {
                    ContentUnavailableView("No groups yet", systemImage: "person.2",
                                           description: Text("Create a group to start planning."))
                    .padding(.top, 40)
                } else {
                    GroceryListSkeleton()
                }
            }
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await repo.manualRefresh() }
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
                Button { showingAddSearch = true } label: { Image(systemName: "plus") }
                    .disabled(repo.currentList == nil)
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .fullScreenCover(isPresented: $showingAddSearch) {
            AddItemSearchView(tint: tint)
        }
        .sheet(isPresented: $showingSettings) { NavigationStack { SettingsView() } }
        .sheet(isPresented: $showNewGroup) { NavigationStack { GroupEditorView(group: nil) } }
        .sheet(isPresented: $showEditGroup) { NavigationStack { GroupEditorView(group: repo.currentHousehold) } }
        .sheet(isPresented: $showStartTrip) {
            StartTripSheet(
                groupName: repo.currentHousehold?.name ?? "this group",
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
            if repo.currentHousehold != nil && repo.isOwnerOfCurrentGroup {
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

    private var startShoppingButton: some View {
        Button {
            showStartTrip = true
        } label: {
            Label("Start Shopping", systemImage: "cart.fill")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .grocerGlassButton(prominent: true)
        .tint(tint)
        .controlSize(.large)
        .padding()
        .disabled(repo.pendingItems.isEmpty)
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
                        Text(qty)
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
                    .background(Color(.systemGray5), in: Capsule())
            }

            MemberAvatarView(member: member, size: 28)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.quaternary)
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
                    Text("Start Shopping")
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
                Text("View")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
