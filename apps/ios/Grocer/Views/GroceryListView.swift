import SwiftUI

/// Planning screen for the current group (each group is its own list, with a
/// store, icon, and color theme). Pushed from HomeView; the system back button
/// returns to the group grid. Items are grouped by category with a Start
/// Shopping CTA themed to the group.
struct GroceryListView: View {
    @Environment(GroceryRepository.self) private var repo

    /// The owning `HomeView`'s push path and this view's group id, used to tell
    /// when this screen is being popped back to Home. While it animates out, a
    /// stray tap on a row could otherwise re-push an item detail screen, so the
    /// row actions check `isTopOfStack` before firing.
    ///
    /// Important: this is only read inside action closures, never during `body`.
    /// Reading it in `body` would make the view re-render the instant the back
    /// button mutates the path — mid zoom-out — which visibly glitches the rows
    /// as they morph back into the Home card.
    @Binding var navigationPath: [String]
    let householdId: String

    @State private var showingAddSearch = false
    @State private var showingSettings = false
    @State private var sessionForNav: ShoppingSession?
    @State private var itemForNav: GroceryItem?
    @State private var showStartTrip = false

    private var tint: Color { repo.currentHousehold?.tint ?? .green }

    /// True while this group's list is the top of the push stack. Goes false the
    /// moment a pop back to Home begins, before the animation finishes.
    private var isTopOfStack: Bool { navigationPath.last == householdId }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let session = repo.activeSession {
                    ActiveSessionBanner(session: session, progress: repo.progress(for: session), tint: tint) {
                        Haptics.selection()
                        sessionForNav = session
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }

                if repo.currentList != nil {
                    ForEach(repo.pendingItemGroups, id: \.category) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            CategoryHeader(category: group.category)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 8)
                                .padding(.top, 4)

                            VStack(spacing: 0) {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                    SwipeToRemoveRow {
                                        // Ignore stray taps that land while the
                                        // screen is animating back to Home.
                                        guard isTopOfStack else { return }
                                        itemForNav = item
                                    } onRemove: {
                                        guard isTopOfStack else { return }
                                        Haptics.warning()
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                            repo.delete(item)
                                        }
                                    } content: {
                                        GroceryItemRow(
                                            item: item,
                                            member: repo.member(for: item)
                                        )
                                    }

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
        // The custom back button hides the system one, which would otherwise
        // also kill the edge-swipe-to-go-back gesture; restore it here.
        .background(InteractivePopGestureRestorer())
        .refreshable { await repo.manualRefresh() }
        .navigationTitle(repo.currentHousehold?.name ?? "Grocer")
        .navigationBarTitleDisplayMode(.large)
        .tint(tint)
        .navigationDestination(item: $sessionForNav) { session in
            ShoppingSessionView(sessionId: session.id) { sessionForNav = nil }
        }
        .navigationDestination(item: $itemForNav) { item in
            ItemDetailView(item: item)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                SyncStatusBar(state: repo.syncState)
                if repo.currentList != nil && repo.activeSession == nil {
                    // Fade the CTA out the instant the zoom-out begins so it
                    // doesn't ride the morph back into the card. Kept in a child
                    // view so the path read that drives the fade doesn't
                    // re-render the list mid-transition (which glitches the
                    // rows); opacity also preserves layout so the list doesn't
                    // shift while it fades.
                    FadeOutOnPop(navigationPath: $navigationPath, householdId: householdId) {
                        startShoppingButton
                    }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Haptics.selection()
                    if !navigationPath.isEmpty { navigationPath.removeLast() }
                } label: {
                    Label("Home", systemImage: "chevron.backward")
                }
                .accessibilityLabel("Back")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Haptics.tap(); showingAddSearch = true } label: { Image(systemName: "plus") }
                    .disabled(repo.currentList == nil)
                Button { Haptics.tap(); showingSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .fullScreenCover(isPresented: $showingAddSearch) {
            AddItemSearchView(tint: tint)
        }
        .navigationDestination(isPresented: $showingSettings) { SettingsView() }
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

// MARK: - Interactive pop gesture

/// Re-enables the swipe-from-left-edge "pop" gesture on the enclosing
/// `UINavigationController`. SwiftUI disables that gesture whenever a screen
/// supplies a custom back button (via `navigationBarBackButtonHidden`), so this
/// reinstalls it while still guarding against popping the root view controller.
private struct InteractivePopGestureRestorer: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        Holder(coordinator: context.coordinator)
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    /// Hosts itself in the SwiftUI hierarchy purely to reach the nav controller.
    final class Holder: UIViewController {
        let coordinator: Coordinator

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            guard let gesture = navigationController?.interactivePopGestureRecognizer else { return }
            coordinator.navigationController = navigationController
            gesture.delegate = coordinator
            gesture.isEnabled = true
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}

// MARK: - Rows / banners

/// Fades its content out as soon as this screen stops being the top of the push
/// stack — i.e. the moment a pop back to Home starts. It reads the navigation
/// path *itself* (rather than the parent reading it and passing a Bool) so the
/// path change only invalidates this small view, leaving the list untouched
/// during the zoom-out morph.
private struct FadeOutOnPop<Content: View>: View {
    @Binding var navigationPath: [String]
    let householdId: String
    @ViewBuilder var content: Content

    private var isTopOfStack: Bool { navigationPath.last == householdId }

    var body: some View {
        content
            .opacity(isTopOfStack ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: isTopOfStack)
    }
}

/// Wraps a list row so it can be swiped left to reveal a destructive "Remove"
/// action, with a full swipe completing the removal outright — mirroring the
/// system `swipeActions` behavior a `List` would provide, but inside the custom
/// card layout this screen uses instead of a `List`.
private struct SwipeToRemoveRow<Content: View>: View {
    let onTap: () -> Void
    let onRemove: () -> Void
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    @State private var committedOffset: CGFloat = 0
    @State private var dragAxis: Axis?

    /// Resting width of the revealed Remove button.
    private let actionWidth: CGFloat = 88
    /// Leftward drag distance past which releasing removes the item directly.
    private let fullSwipeDistance: CGFloat = 220

    var body: some View {
        ZStack(alignment: .trailing) {
            removeButton
            content
                // Opaque background so the row hides the red action when closed
                // and matches the surrounding card while at rest.
                .background(Color(.secondarySystemGroupedBackground))
                .offset(x: offset)
                .contentShape(Rectangle())
                // A tap opens the item (or closes an open row). `onTapGesture`
                // never fires mid-drag, so a swipe won't navigate — and because
                // the swipe uses `simultaneousGesture` (not `highPriorityGesture`)
                // the enclosing ScrollView keeps handling vertical scrolling.
                .onTapGesture {
                    if committedOffset != 0 { close() } else { Haptics.selection(); onTap() }
                }
                .simultaneousGesture(dragGesture)
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Label("Remove", systemImage: "trash")
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.white)
                // Track the swipe so the action grows with an over-drag.
                .frame(width: max(actionWidth, -offset))
                .frame(maxHeight: .infinity)
                .background(Color.red)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal else { return }
                // Only leftward; clamp so the row never slides past closed.
                offset = min(0, committedOffset + value.translation.width)
            }
            .onEnded { _ in
                defer { dragAxis = nil }
                guard dragAxis == .horizontal else { return }
                if -offset >= fullSwipeDistance {
                    onRemove()
                } else if -offset > actionWidth / 2 {
                    open()
                } else {
                    close()
                }
            }
    }

    private func open() {
        committedOffset = -actionWidth
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { offset = -actionWidth }
    }

    private func close() {
        committedOffset = 0
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { offset = 0 }
    }
}

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

            PriorityLabel(priority: item.priority)

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
                    Haptics.success()
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
