import PhotosUI
import PostHog
import StoreKit
import SwiftUI
import UIKit

/// How the store-link sheet is opened: `.link` shows the intro first, `.change`
/// jumps straight to the map picker for an already-linked store.
enum StoreLinkMode: Identifiable {
    case link, change
    var id: Self { self }
}

/// Wraps the Stripe billing-portal URL so it can drive an `item:`-based sheet.
struct BillingPortalPresentation: Identifiable {
    let id = UUID()
    let url: URL
}

struct SettingsView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(SettingsStore.self) private var settings
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showProPaywall = false
    @State private var displayName = ""
    @State private var groupName = ""
    @State private var committedGroupName = ""
    @State private var confirmLeave = false
    @State private var selectedProfilePhoto: PhotosPickerItem?
    @State private var showDebug = false
    @State private var billingPortal: BillingPortalPresentation?

    fileprivate static let proAccent = Color(red: 0.06, green: 0.72, blue: 0.51)

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                profileHeader
                proCard
                thisListSection
                appSettingsSection
                dangerZoneSection
                versionFooter
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { HapticBackButton() }
        }
        .onAppear {
            displayName = repo.displayName
            syncGroupNameFromRepo()
        }
        .onChange(of: repo.currentHousehold?.id) { _, _ in
            syncGroupNameFromRepo()
        }
        .onChange(of: repo.currentHousehold?.name) { _, _ in
            syncGroupNameFromRepoIfClean()
        }
        .onChange(of: selectedProfilePhoto) { _, newItem in
            loadProfilePhoto(newItem)
        }
        .onDisappear {
            commitPendingChanges()
        }
        .sheet(isPresented: $showDebug) {
            DebugView()
        }
        .sheet(item: $billingPortal) { portal in
            WebCheckoutView(url: portal.url)
        }
        .fullScreenCover(isPresented: $showProPaywall) {
            GrocerProPaywallView()
        }
        .alert("Purchase Error", isPresented: purchaseErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(purchaseErrorMessage)
        }
        .postHogScreenView("Settings")
    }

    private var purchaseErrorPresented: Binding<Bool> {
        Binding(
            get: { subscriptions.lastErrorMessage != nil },
            set: { if !$0 { subscriptions.clearError() } }
        )
    }

    private var purchaseErrorMessage: String {
        subscriptions.lastErrorMessage ?? ""
    }

    // MARK: - Profile header

    private var profileHeader: some View {
        VStack(spacing: 14) {
            PhotosPicker(selection: $selectedProfilePhoto, matching: .images) {
                ProfilePicture(imageData: repo.profileImageData, size: 96)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change profile photo")

            TextField("Your Name", text: $displayName)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit { commitDisplayName() }
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - Grocer Pro

    private var proCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Grocer")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                    Text("Pro")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.yellow, in: Capsule())
                }

                Text(subscriptions.hasGrocerPro
                     ? subscriptions.displayStatus
                     : String(localized: "Get Pro to unlock all features"))
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Haptics.selection()
                    if subscriptions.hasGrocerPro {
                        openManageSubscription()
                    } else {
                        showProPaywall = true
                    }
                } label: {
                    Text(subscriptions.hasGrocerPro
                         ? String(localized: "Manage Subscription")
                         : String(localized: "Try for free"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
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
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.07, green: 0.08, blue: 0.07))

            // A single restrained glow keeps it on-brand without going neon.
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Self.proAccent.opacity(0.28), .clear],
                        center: .bottomTrailing,
                        startRadius: 8,
                        endRadius: 260
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func openManageSubscription() {
        // Stripe (web) subscriptions are managed through our own billing portal,
        // so keep the user in-app with a sheet.
        if subscriptions.isWebSubscription {
            guard let url = subscriptions.managementURL else {
                subscriptions.recordErrorMessage(String(localized: "Subscription management is not available yet."))
                return
            }
            billingPortal = BillingPortalPresentation(url: url)
            return
        }

        // App Store subscriptions can only be managed by Apple. Present the
        // native StoreKit management sheet in-app rather than bouncing the user
        // out to the App Store / Settings app.
        Task { await presentAppStoreManagement() }
    }

    @MainActor
    private func presentAppStoreManagement() async {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first

        guard let scene else {
            // No window scene to present from — fall back to the system URL.
            openManagementURLFallback()
            return
        }

        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            // The sheet can fail to present (e.g. simulator/sandbox); fall back
            // to opening the management URL so the user is never stuck.
            openManagementURLFallback()
        }
    }

    private func openManagementURLFallback() {
        guard let url = subscriptions.managementURL else {
            subscriptions.recordErrorMessage(String(localized: "Subscription management is not available yet."))
            return
        }
        openURL(url)
    }

    // MARK: - Section 1: This List

    private var thisListSection: some View {
        settingsSection(String(localized: "This List")) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    settingsNavTile(String(localized: "List Appearance"),
                                    systemImage: "paintbrush.fill",
                                    tint: .accentColor) {
                        CustomizeListView()
                    }
                    settingsNavTile(String(localized: "Shopping Settings"),
                                    systemImage: "cart.fill",
                                    tint: .grocerGreen) {
                        ShoppingSettingsView()
                    }
                }
                membersBlock
            }
        }
    }

    /// Full-width "Members & Sharing" block opening the member management list.
    private var membersBlock: some View {
        NavigationLink {
            MembersView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.2.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Members & Sharing")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("^[\(repo.currentMembers.count) Member](inflect: true)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { Haptics.selection() })
    }

    // MARK: - Section 2: App Settings

    private var appSettingsSection: some View {
        settingsSection(String(localized: "App Settings")) {
            settingsCard {
                settingsNavRow(String(localized: "Live Activities"),
                               systemImage: "bolt.fill", tint: .orange) {
                    LiveActivitiesSettingsView()
                }
                settingsRowDivider
                settingsNavRow(String(localized: "Notifications"),
                               systemImage: "bell.badge.fill", tint: .red) {
                    NotificationsSettingsView()
                }
                settingsRowDivider
                settingsNavRow(String(localized: "App Appearance"),
                               systemImage: "circle.lefthalf.filled", tint: .indigo) {
                    AppearanceSettingsView()
                }
                settingsRowDivider
                Button {
                    Haptics.selection()
                    if subscriptions.hasGrocerPro {
                        openManageSubscription()
                    } else {
                        showProPaywall = true
                    }
                } label: {
                    settingsRowLabel(String(localized: "Manage Pro"),
                                     systemImage: "crown.fill",
                                     tint: Self.proAccent,
                                     chevron: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Section 3: Danger Zone

    @ViewBuilder
    private var dangerZoneSection: some View {
        if repo.households.count > 1 || !repo.isOwnerOfCurrentGroup {
            settingsSection(String(localized: "Danger Zone")) {
                settingsCard {
                    Button(role: .destructive) {
                        Haptics.selection()
                        confirmLeave = true
                    } label: {
                        settingsRowLabel(repo.isOwnerOfCurrentGroup ? String(localized: "Delete List") : String(localized: "Leave List"),
                                         systemImage: repo.isOwnerOfCurrentGroup ? "trash" : "rectangle.portrait.and.arrow.right",
                                         destructive: true)
                    }
                    .buttonStyle(.plain)
                    // Anchor the confirmation popover (iPad/Mac) to the button itself.
                    .confirmationDialog(
                        repo.isOwnerOfCurrentGroup
                            ? String(localized: "Delete this list?")
                            : String(localized: "Leave this list?"),
                        isPresented: $confirmLeave,
                        titleVisibility: .visible
                    ) {
                        Button(repo.isOwnerOfCurrentGroup ? String(localized: "Delete List") : String(localized: "Leave List"),
                               role: .destructive) {
                            Haptics.warning()
                            repo.leaveCurrentGroup()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(repo.isOwnerOfCurrentGroup
                             ? String(localized: "As the owner, this deletes the list for everyone.")
                             : String(localized: "You\u{2019}ll stop seeing this list on this device."))
                    }
                }
            }
        }
    }

    /// A navigation row inside the App Settings card.
    @ViewBuilder
    private func settingsNavRow<Destination: View>(_ title: String,
                                                   systemImage: String,
                                                   tint: Color,
                                                   @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            settingsRowLabel(title, systemImage: systemImage, tint: tint, chevron: true)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { Haptics.selection() })
    }

    /// App version pinned at the bottom. Long-pressing it opens the engineer
    /// diagnostics screen (replaces the old shake gesture).
    private var versionFooter: some View {
        Text(verbatim: "Grocer \(settings.appVersion)")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.8) {
                Haptics.success()
                showDebug = true
            }
            .accessibilityLabel(Text("Version \(settings.appVersion)"))
            .accessibilityHint(Text("Opens diagnostics"))
    }

    private func commitPendingChanges() {
        commitDisplayName()
        commitGroupName()
    }

    private func commitDisplayName() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            displayName = repo.displayName
            return
        }
        repo.updateDisplayName(trimmed)
        displayName = trimmed
    }

    private func commitGroupName() {
        guard repo.isOwnerOfCurrentGroup else {
            syncGroupNameFromRepo()
            return
        }
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            syncGroupNameFromRepo()
            return
        }
        guard trimmed != committedGroupName else {
            groupName = committedGroupName
            return
        }
        repo.renameGroup(trimmed)
        committedGroupName = trimmed
        groupName = trimmed
    }

    private func syncGroupNameFromRepo() {
        let name = repo.currentHousehold?.name ?? ""
        committedGroupName = name
        groupName = name
    }

    private func syncGroupNameFromRepoIfClean() {
        let latest = repo.currentHousehold?.name ?? ""
        if groupName == committedGroupName {
            groupName = latest
        }
        committedGroupName = latest
    }

    private func loadProfilePhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            let imageData: Data?
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                imageData = image.resizedProfileImageData()
            } else {
                imageData = nil
            }

            await MainActor.run {
                if let imageData { repo.updateProfileImageData(imageData) }
                selectedProfilePhoto = nil
            }
        }
    }

}

// MARK: - Shared settings building blocks

/// Rounded "card" container matching the Home screen aesthetic.
@ViewBuilder
private func settingsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(spacing: 0) { content() }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
        }
}

/// Section header + content, with an optional footer caption.
@ViewBuilder
private func settingsSection<Content: View>(
    _ title: String,
    footer: String? = nil,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        content()
        if let footer {
            Text(footer)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }
}

/// Divider between rows inside a card, inset past the leading icon.
private var settingsRowDivider: some View {
    Divider().padding(.leading, 52)
}

/// A leading-icon row label used across button/navigation rows.
private func settingsRowLabel(_ title: String,
                             systemImage: String,
                             tint: Color = .accentColor,
                             chevron: Bool = false,
                             destructive: Bool = false,
                             enabled: Bool = true) -> some View {
    let iconColor: Color = !enabled ? .secondary : (destructive ? .red : tint)
    let textColor: Color = !enabled ? .secondary : (destructive ? .red : .primary)
    return HStack(spacing: 14) {
        Image(systemName: systemImage)
            .font(.body)
            .foregroundStyle(iconColor)
            .frame(width: 24)
        Text(title)
            .foregroundStyle(textColor)
        Spacer(minLength: 8)
        if chevron {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
    .contentShape(Rectangle())
}

/// A square navigation tile (icon top-left, bold label below) — the
/// side-by-side card style used in the "This List" section.
@ViewBuilder
private func settingsNavTile<Destination: View>(_ title: String,
                                                systemImage: String,
                                                tint: Color,
                                                @ViewBuilder destination: () -> Destination) -> some View {
    NavigationLink {
        destination()
    } label: {
        settingsTileContent(title, systemImage: systemImage, tint: tint)
    }
    .buttonStyle(.plain)
    .simultaneousGesture(TapGesture().onEnded { Haptics.selection() })
}

/// Shared tile body: colored icon top-left, gray chevron top-right, and a
/// bold label below. Used by both `settingsNavTile` and the standalone store
/// button so they read as the same primary-action style.
private func settingsTileContent(_ title: String,
                                 systemImage: String,
                                 tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 10)
        Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
    .padding(16)
    .background(Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
    }
}

// MARK: - Members & Sharing

/// Members & Sharing — invite people and manage who is in the list.
struct MembersView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(SubscriptionStore.self) private var subscriptions

    @State private var showInviteIntro = false
    @State private var openMemberRowId: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                membersSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { HapticBackButton() }
        }
        .sheet(isPresented: $showInviteIntro) {
            InviteToGroupSheet()
        }
        .postHogScreenView("Members & Sharing")
    }

    private func canRemove(_ member: HouseholdMember) -> Bool {
        repo.isOwnerOfCurrentGroup && member.role != .owner
    }

    private var membersSection: some View {
        let canInvite = repo.isOwnerOfCurrentGroup && repo.canShare
        return settingsSection(String(localized: "Members"), footer: membersFooter) {
            settingsCard {
                Button {
                    Haptics.selection()
                    showInviteIntro = true
                } label: {
                    inviteRow(enabled: canInvite)
                }
                .buttonStyle(.plain)
                .disabled(!canInvite)

                ForEach(repo.currentMembers) { member in
                    Divider().padding(.leading, member.role == .owner ? 52 : 68)
                    memberRow(member)
                }
            }
            // Contain the swipe-to-remove action background within the rounded card.
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    /// "Invite to List" row. Sized to match the nav tiles — `.title2` icon and a
    /// semibold body title — so it reads as a primary action.
    private func inviteRow(enabled: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill.badge.plus")
                .font(.title2)
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
                .frame(width: 30)
            Text("Invite to List")
                .font(.body.weight(.semibold))
                .foregroundStyle(enabled ? .primary : .secondary)
            Spacer(minLength: 8)
            if showsInviteLimitChip {
                inviteLimitChip
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// Free list owners get a couple of invites before they hit the cap, so we
    /// surface their remaining allowance right on the invite row as an upsell.
    /// Pro members and non-owners (who can't invite) don't need the nudge.
    private var showsInviteLimitChip: Bool {
        !subscriptions.hasGrocerPro && repo.isOwnerOfCurrentGroup
    }

    /// "1/2 · Upgrade" capsule. Pro-yellow to read as an upgrade affordance; the
    /// row itself opens the invite sheet, which presents the paywall at the cap.
    private var inviteLimitChip: some View {
        let count = repo.invitedMemberCount
        let limit = GroceryRepository.freeInviteLimit
        return HStack(spacing: 5) {
            Text(verbatim: "\(count)/\(limit)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
            Text("Upgrade")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.yellow, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(count) of \(limit) members invited. Upgrade to Grocer Pro to invite more."))
    }

    private var membersFooter: String? {
        if !repo.isOwnerOfCurrentGroup {
            return String(localized: "Only the list owner can invite people.")
        } else if let reason = repo.sharingUnavailableReason {
            return reason
        } else if repo.currentMembers.contains(where: { $0.role != .owner }) {
            // Only relevant once there's someone other than the owner to remove.
            return String(localized: "Swipe left on a member to remove them from this list.")
        }
        return nil
    }

    @ViewBuilder
    private func memberRow(_ member: HouseholdMember) -> some View {
        let isOwner = member.role == .owner
        let content = HStack(spacing: 12) {
            ProfilePicture(
                imageData: repo.isCurrentUser(member) ? repo.profileImageData : member.profileImageData,
                size: 30
            )
            Text(member.displayName)
            Spacer(minLength: 8)
            if isOwner {
                Image(systemName: "crown.fill")
                    .font(.footnote)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel(Text(member.role.localizedName))
            }
        }
        // Nest non-owner members slightly beneath the owner to show hierarchy.
        .padding(.leading, isOwner ? 16 : 32)
        .padding(.trailing, 16)
        .padding(.vertical, 11)

        if canRemove(member) {
            SwipeToRemoveRow(id: member.id, openRowId: $openMemberRowId) {
                Haptics.warning()
                repo.removeMember(member)
            } content: {
                content
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: Text("Remove \(member.displayName)")) {
                Haptics.warning()
                repo.removeMember(member)
            }
        } else {
            content
        }
    }
}

// MARK: - Shopping Settings

/// Shopping Settings — the store this list is linked to and arrival reminders.
struct ShoppingSettingsView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(SettingsStore.self) private var settings

    @State private var storeLinkMode: StoreLinkMode?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                storeReminderSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { HapticBackButton() }
        }
        .sheet(item: $storeLinkMode) { mode in
            StoreLinkSheet(startAtPicker: mode == .change)
        }
        .postHogScreenView("Shopping Settings")
    }

    /// Per-list arrival reminder controls. The store itself is shared on the
    /// group; this opt-in is personal, so each member chooses independently.
    @ViewBuilder
    private var storeReminderSection: some View {
        if let house = repo.currentHousehold {
            settingsSection(String(localized: "Store"), footer: storeReminderFooter(house)) {
                if house.hasLinkedStore {
                    StoreLocationCard(
                        household: house,
                        remindersEnabled: storeRemindersBinding(for: house.id),
                        onChange: {
                            Haptics.tap()
                            storeLinkMode = .change
                        },
                        onRemove: {
                            Haptics.warning()
                            repo.unlinkStore()
                        }
                    )
                } else {
                    Button {
                        Haptics.tap()
                        storeLinkMode = .link
                    } label: {
                        settingsTileContent(String(localized: "Link a store"),
                                            systemImage: "mappin.and.ellipse",
                                            tint: .accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func storeReminderFooter(_ house: Household) -> String? {
        house.hasLinkedStore
            ? nil
            : String(localized: "Link this list to a store to be reminded to start a trip when you arrive.")
    }

    private func storeRemindersBinding(for householdId: String) -> Binding<Bool> {
        Binding(
            get: { settings.storeRemindersEnabled(forHousehold: householdId) },
            set: { newValue in
                settings.setStoreRemindersEnabled(newValue, forHousehold: householdId)
                if newValue { StoreReminderManager.shared.requestAlwaysAuthorization() }
                StoreReminderManager.shared.syncMonitoredRegions(households: repo.households)
            }
        )
    }
}

private struct ProfilePicture: View {
    let imageData: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().stroke(.quaternary, lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

private extension UIImage {
    func resizedProfileImageData(maxPixelSize: CGFloat = 512,
                                 compressionQuality: CGFloat = 0.82) -> Data? {
        guard size.width > 0, size.height > 0 else { return nil }

        let targetSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        let scale = max(targetSize.width / size.width, targetSize.height / size.height)
        let scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
        let drawRect = CGRect(
            x: (targetSize.width - scaledSize.width) / 2,
            y: (targetSize.height - scaledSize.height) / 2,
            width: scaledSize.width,
            height: scaledSize.height
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: targetSize, format: format)
            .jpegData(withCompressionQuality: compressionQuality) { context in
                UIColor.systemBackground.setFill()
                context.fill(CGRect(origin: .zero, size: targetSize))
                draw(in: drawRect)
            }
    }
}

struct InviteToGroupSheet: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var preparingShare = false
    @State private var shareError: String?
    @State private var showingContacts = false
    @State private var showProPaywall = false

    private var groupName: String {
        repo.currentHousehold?.name ?? String(localized: "My List")
    }

    /// Free accounts can only invite `freeInviteLimit` people per list. Once the
    /// list already has that many participants, further invites require Pro.
    private var isAtFreeInviteLimit: Bool {
        !subscriptions.hasGrocerPro
            && repo.invitedMemberCount >= GroceryRepository.freeInviteLimit
    }

    private var tint: Color {
        repo.currentHousehold?.tint ?? .accentColor
    }

    var body: some View {
        VStack(spacing: 30) {
            HStack {
                Spacer()
                closeButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Text("Shopping is better together")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)

            shareCard
                .padding(.horizontal, 48)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button(action: invite) {
                    Text("Invite People")
                        .font(.headline)
                        .foregroundStyle(primaryButtonForeground)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Capsule().fill(primaryButtonBackground))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: shareLink) {
                    Text("Share Link")
                        .font(.headline)
                        .foregroundStyle(preparingShare ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Capsule().fill(copyButtonBackground))
                        .contentShape(Capsule())
                }
                .disabled(preparingShare)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 32)
            .padding(.bottom, 8)
        }
        .presentationDetents([.height(512)])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showingContacts) {
            InviteContactsView()
        }
        .fullScreenCover(isPresented: $showProPaywall) {
            GrocerProPaywallView(context: .inviteLimit)
        }
        .alert("Couldn\u{2019}t start sharing", isPresented: Binding(
            get: { shareError != nil }, set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(shareError ?? "") }
        .postHogScreenView("Invite to List")
    }

    /// Tilted preview of the group being shared — mirrors the card recipients
    /// see, so the user knows exactly what they're handing over.
    private var shareCard: some View {
        ZStack(alignment: .topLeading) {
            Image(systemName: "cart.fill")
                .font(.system(size: 150))
                .foregroundStyle(.white.opacity(0.08))
                .rotationEffect(.degrees(-12))
                .offset(x: 110, y: 70)

            VStack(alignment: .leading, spacing: 0) {
                Text("Shared List")
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.85))

                HStack(spacing: 10) {
                    Image(systemName: repo.currentHousehold?.icon ?? "cart.fill")
                        .font(.title3.weight(.semibold))
                    Text(groupName)
                        .font(.title2.bold())
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.top, 8)

                Spacer(minLength: 12)

                HStack {
                    memberAvatars
                    Spacer()
                    Text("Grocer")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(20)
        }
        .frame(height: 190)
        .background(tint.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .rotationEffect(.degrees(-4))
        .shadow(color: tint.opacity(0.35), radius: 24, x: 0, y: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview of \(groupName)"))
    }

    @ViewBuilder
    private var memberAvatars: some View {
        let members = repo.currentMembers.prefix(4)
        HStack(spacing: -10) {
            ForEach(Array(members.enumerated()), id: \.element.id) { _, member in
                ProfilePicture(
                    imageData: repo.isCurrentUser(member) ? repo.profileImageData : member.profileImageData,
                    size: 30
                )
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1.5))
            }
        }
    }

    private var primaryButtonForeground: Color {
        colorScheme == .dark ? .black : .white
    }

    private var primaryButtonBackground: Color {
        colorScheme == .dark ? .white : .black
    }

    private var copyButtonBackground: Color {
        preparingShare ? Color.secondary.opacity(0.14) : Color.primary.opacity(0.06)
    }

    private func invite() {
        Haptics.selection()
        if isAtFreeInviteLimit {
            showProPaywall = true
            return
        }
        if let reason = repo.sharingUnavailableReason {
            shareError = reason
        } else {
            showingContacts = true
        }
    }

    /// Mints a single-use invite link and hands it to the iOS share sheet so it
    /// can be sent anywhere in a couple of taps.
    private func shareLink() {
        if isAtFreeInviteLimit {
            Haptics.selection()
            showProPaywall = true
            return
        }
        if let reason = repo.sharingUnavailableReason {
            Haptics.error()
            shareError = reason
            return
        }
        Haptics.selection()
        preparingShare = true
        Task {
            defer { preparingShare = false }
            do {
                // Branded share.grocer.sh link — single-use so it can't be
                // reshared once accepted.
                let url = try await repo.prepareBrandedInviteURL(singleUse: true)
                Haptics.success()
                ShareSheetPresenter.presentInvite(url: url)
            } catch {
                Haptics.error()
                shareError = error.localizedDescription
            }
        }
    }

    private var closeButton: some View {
        Button {
            Haptics.tap()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .modifier(GlassCircleBackground())
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityLabel("Close")
    }
}

#if DEBUG
#Preview("Invite to List") {
    @Previewable @State var isPresented = true
    Color.clear
        .sheet(isPresented: $isPresented) {
            InviteToGroupSheet()
                .grocerPreviewEnvironment()
        }
}
#endif

/// "I'm about to shop" sheet. Mirrors `InviteToGroupSheet`'s layout — big
/// rounded title, a tilted group card, and a single capsule action — and fires
/// a Time Sensitive heads-up to everyone else in the group.
struct HeadsUpSheet: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var sending = false
    @State private var sent = false
    @State private var sendError: String?

    private var groupName: String {
        repo.currentHousehold?.name ?? String(localized: "My List")
    }

    private var tint: Color {
        repo.currentHousehold?.tint ?? .accentColor
    }

    private var otherMemberCount: Int {
        max(0, repo.currentMembers.count - 1)
    }

    var body: some View {
        VStack(spacing: 30) {
            HStack {
                Spacer()
                closeButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            headsUpBell

            VStack(spacing: 12) {
                Text("Heading out soon?")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)

                Text("We\u{2019}ll send a Time Sensitive alert so everyone can add what they need before you shop.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 36)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: send) {
                Group {
                    if sent {
                        Label("Heads-Up Sent", systemImage: "checkmark")
                    } else if otherMemberCount > 0 {
                        Text("^[Notify \(otherMemberCount) person](inflect: true)")
                    } else {
                        Text("Send Heads-Up")
                    }
                }
                .font(.headline)
                .foregroundStyle(primaryButtonForeground)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Capsule().fill(primaryButtonBackground))
                .overlay(alignment: .trailing) {
                    if sending { ProgressView().tint(primaryButtonForeground).padding(.trailing, 20) }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(sending || sent)
            .padding(.horizontal, 20)
            .padding(.top, 32)
            .padding(.bottom, 8)
        }
        .presentationDetents([.height(440)])
        .presentationDragIndicator(.visible)
        .alert("Couldn\u{2019}t send heads-up", isPresented: Binding(
            get: { sendError != nil }, set: { if !$0 { sendError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(sendError ?? "") }
        .postHogScreenView("Heads-Up")
    }

    /// Bell glyph in the group's tint, ringing to signal the time-sensitive alert.
    private var headsUpBell: some View {
        Image(systemName: "bell.and.waves.left.and.right.fill")
            .font(.system(size: 64, weight: .semibold))
            .foregroundStyle(tint.gradient)
            .frame(width: 120, height: 120)
            .background(Circle().fill(tint.opacity(0.12)))
            .accessibilityHidden(true)
    }

    private var primaryButtonForeground: Color {
        colorScheme == .dark ? .black : .white
    }

    private var primaryButtonBackground: Color {
        colorScheme == .dark ? .white : .black
    }

    private func send() {
        guard !sending, !sent else { return }
        Haptics.selection()
        sending = true
        PostHogSDK.shared.capture("shopping_heads_up_sent", properties: [
            "group_name": groupName,
            "member_count": otherMemberCount,
        ])
        Task {
            let ok = await repo.sendHeadsUp()
            sending = false
            if ok {
                Haptics.success()
                withAnimation(reduceMotion ? nil : .snappy) { sent = true }
                try? await Task.sleep(for: .seconds(0.9))
                dismiss()
            } else {
                Haptics.error()
                sendError = String(localized: "Something went wrong sending the heads-up. Please try again.")
            }
        }
    }

    private var closeButton: some View {
        Button {
            Haptics.tap()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .modifier(GlassCircleBackground())
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityLabel("Close")
    }
}

#if DEBUG
#Preview("Heads Up") {
    @Previewable @State var isPresented = true
    Color.clear
        .sheet(isPresented: $isPresented) {
            HeadsUpSheet()
                .grocerPreviewEnvironment()
        }
}
#endif

/// Liquid glass circular background on iOS 26+, with a material fallback.
private struct GlassCircleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

struct FeedbackView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var email = ""
    @State private var sending = false
    @State private var sent = false

    var body: some View {
        Form {
            Section("Your feedback") {
                TextField("What's on your mind?", text: $message, axis: .vertical)
                    .lineLimit(4...10)
            }
            Section("Contact (optional)") {
                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
            }
            if sent {
                Label("Thanks for the feedback!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .navigationTitle("Send Feedback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    Haptics.tap()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") { send() }
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            }
        }
    }

    private func send() {
        sending = true
        Task {
            let ok = await APIClient.shared.sendFeedback(
                message: message,
                email: email.isEmpty ? nil : email,
                appVersion: settings.appVersion,
                device: UIDevice.current.model
            )
            await MainActor.run {
                sending = false
                sent = ok
                if ok {
                    Haptics.success()
                } else {
                    Haptics.error()
                }
                if ok { message = "" }
            }
        }
    }
}

// MARK: - Swipe to remove

/// Wraps a row so it reveals a destructive "Remove" action when swiped left,
/// mirroring the native `List` swipe-to-delete affordance for our custom cards.
/// `openRowId` is shared across rows so only one stays open at a time.
private struct SwipeToRemoveRow<Content: View>: View {
    let id: String
    @Binding var openRowId: String?
    let onRemove: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var offset: CGFloat = 0

    private let actionWidth: CGFloat = 88

    private var isOpen: Bool { openRowId == id }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                close()
                onRemove()
            } label: {
                Label("Remove", systemImage: "trash.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: actionWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.red)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)

            content()
                .background(Color(.secondarySystemGroupedBackground))
                .offset(x: offset)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 16)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            if openRowId != nil && openRowId != id { openRowId = nil }
                            let base: CGFloat = isOpen ? -actionWidth : 0
                            offset = min(0, max(-actionWidth, base + value.translation.width))
                        }
                        .onEnded { _ in
                            let shouldOpen = offset < -actionWidth / 2
                            withAnimation(reduceMotion ? nil : .snappy) {
                                offset = shouldOpen ? -actionWidth : 0
                                openRowId = shouldOpen ? id : nil
                            }
                        }
                )
        }
        .clipped()
        .onChange(of: openRowId) { _, newValue in
            if newValue != id, offset != 0 {
                withAnimation(reduceMotion ? nil : .snappy) { offset = 0 }
            }
        }
    }

    private func close() {
        withAnimation(reduceMotion ? nil : .snappy) {
            offset = 0
            openRowId = nil
        }
    }
}
