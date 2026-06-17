import PhotosUI
import PostHog
import SwiftUI
import UIKit

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
    @State private var confirmPurge = false
    @State private var purging = false
    @State private var selectedProfilePhoto: PhotosPickerItem?
    @State private var showInviteIntro = false
    @State private var editingGroup: Household?
    @State private var openMemberRowId: String?
    @State private var showStoreLink = false

    private static let proAccent = Color(red: 0.06, green: 0.72, blue: 0.51)

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                profileHeader
                proCard
                generalSection
                membersSection
                preferencesSection
                storeReminderSection
                moreSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 36)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { HapticBackButton() }
            ToolbarItem(placement: .principal) { GrocerGlassTitle("Settings") }
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
                 : String(localized: "You’ll stop seeing this list on this device."))
        }
        .confirmationDialog("Delete all data?", isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive) {
                Haptics.warning()
                purgeAllData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all lists and items from iCloud. You can create or join a list again afterward.")
        }
        .sheet(isPresented: $showInviteIntro) {
            InviteToGroupSheet()
        }
        .sheet(item: $editingGroup) { group in
            NavigationStack { GroupEditorView(group: group) }
        }
        .sheet(isPresented: $showStoreLink) {
            StoreLinkSheet()
        }
        .fullScreenCover(isPresented: $showProPaywall) {
            GrocerProPaywallView()
        }
        .alert("Purchase Error", isPresented: purchaseErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(purchaseErrorMessage)
        }
    }

    private func canRemove(_ member: HouseholdMember) -> Bool {
        repo.isOwnerOfCurrentGroup && member.role != .owner
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

    // MARK: - Reusable building blocks

    /// Rounded "card" container matching the Home screen aesthetic.
    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 1)
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
    private var rowDivider: some View {
        Divider().padding(.leading, 52)
    }

    /// A leading-icon row label used across button/navigation rows.
    private func rowLabel(_ title: String,
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
    }

    private func openManageSubscription() {
        guard let url = subscriptions.managementURL else {
            subscriptions.recordErrorMessage(String(localized: "Subscription management is not available yet."))
            return
        }
        openURL(url)
    }

    // MARK: - General

    private var generalSection: some View {
        settingsSection(String(localized: "List")) {
            card {
                if repo.isOwnerOfCurrentGroup {
                    HStack(spacing: 14) {
                        Image(systemName: "person.2.fill")
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        TextField("List Name", text: $groupName)
                            .submitLabel(.done)
                            .onSubmit { commitGroupName() }
                        commitButton(isEnabled: canSaveGroupName) {
                            commitGroupName()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                } else {
                    HStack(spacing: 14) {
                        Image(systemName: "person.2.fill")
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        Text("List")
                        Spacer()
                        Text(repo.currentHousehold?.name ?? String(localized: "List"))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }

                if repo.isOwnerOfCurrentGroup, repo.currentHousehold != nil {
                    rowDivider

                    Button {
                        Haptics.selection()
                        editingGroup = repo.currentHousehold
                    } label: {
                        rowLabel(String(localized: "Customize List"), systemImage: "paintbrush", chevron: true)
                    }
                    .buttonStyle(.plain)
                }

                rowDivider

                NavigationLink {
                    TripHistoryView()
                } label: {
                    rowLabel(String(localized: "Trip History"), systemImage: "clock.arrow.circlepath", chevron: true)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    Haptics.selection()
                })
            }
        }
    }

    // MARK: - Members

    private var membersSection: some View {
        let canInvite = repo.isOwnerOfCurrentGroup && repo.canShare
        return settingsSection(String(localized: "Members"), footer: membersFooter) {
            card {
                Button {
                    Haptics.selection()
                    showInviteIntro = true
                } label: {
                    rowLabel(String(localized: "Invite to List"), systemImage: "person.crop.circle.badge.plus",
                             enabled: canInvite)
                }
                .buttonStyle(.plain)
                .disabled(!canInvite)

                ForEach(repo.currentMembers) { member in
                    rowDivider
                    memberRow(member)
                }
            }
            // Contain the swipe-to-remove action background within the rounded card.
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var membersFooter: String? {
        if !repo.isOwnerOfCurrentGroup {
            return String(localized: "Only the list owner can invite people.")
        } else if let reason = repo.sharingUnavailableReason {
            return reason
        } else if repo.isOwnerOfCurrentGroup {
            return String(localized: "Swipe left on a member to remove them from this list.")
        }
        return nil
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        settingsSection(String(localized: "Preferences")) {
            card {
                Toggle(isOn: familyLiveActivitiesBinding) {
                    Label("Show Live Activities", systemImage: "bolt.horizontal.circle")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                rowDivider

                Toggle(isOn: notificationsBinding) {
                    Label("Shopping notifications", systemImage: "bell.badge")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - More / actions

    private var moreSection: some View {
        settingsSection(String(localized: "More")) {
            card {
                if repo.households.count > 1 || !repo.isOwnerOfCurrentGroup {
                    Button(role: .destructive) {
                        Haptics.selection()
                        confirmLeave = true
                    } label: {
                        rowLabel(repo.isOwnerOfCurrentGroup ? String(localized: "Delete List") : String(localized: "Leave List"),
                                 systemImage: repo.isOwnerOfCurrentGroup ? "trash" : "rectangle.portrait.and.arrow.right",
                                 destructive: true)
                    }
                    .buttonStyle(.plain)
                    rowDivider
                }

                Button(role: .destructive) {
                    Haptics.selection()
                    confirmPurge = true
                } label: {
                    HStack(spacing: 0) {
                        rowLabel(String(localized: "Reset All Data"), systemImage: "trash", destructive: true)
                        if purging { ProgressView().padding(.trailing, 16) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(purging)
            }
        }
    }

    private var familyLiveActivitiesBinding: Binding<Bool> {
        Binding(
            get: { settings.familyLiveActivitiesEnabled },
            set: { newValue in
                settings.familyLiveActivitiesEnabled = newValue
                LiveActivityManager.shared.familyPreferenceChanged()
            }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { settings.notificationsEnabled },
            set: { newValue in
                settings.notificationsEnabled = newValue
                PushNotificationCoordinator.shared.notificationPreferenceChanged()
            }
        )
    }

    // MARK: - Store reminders

    /// Per-list arrival reminder controls. The store itself is shared on the
    /// group; this opt-in is personal, so each member chooses independently.
    @ViewBuilder
    private var storeReminderSection: some View {
        if let house = repo.currentHousehold {
            VStack(alignment: .leading, spacing: 10) {
                card {
                    if house.hasLinkedStore {
                        Toggle(isOn: storeRemindersBinding(for: house.id)) {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Remind me at the store")
                                    if let store = house.storeName,
                                       !store.trimmingCharacters(in: .whitespaces).isEmpty {
                                        Text(store).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "bell.and.waves.left.and.right")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)

                        rowDivider

                        Button {
                            Haptics.tap()
                            showStoreLink = true
                        } label: {
                            rowLabel(String(localized: "Change store"),
                                     systemImage: "mappin.and.ellipse", chevron: true)
                        }
                        .buttonStyle(.plain)

                        rowDivider

                        Button(role: .destructive) {
                            Haptics.warning()
                            repo.unlinkStore()
                        } label: {
                            rowLabel(String(localized: "Remove store"),
                                     systemImage: "mappin.slash", destructive: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            Haptics.tap()
                            showStoreLink = true
                        } label: {
                            rowLabel(String(localized: "Link a store"),
                                     systemImage: "mappin.and.ellipse", chevron: true)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(storeReminderFooter(house))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func storeReminderFooter(_ house: Household) -> String {
        house.hasLinkedStore
            ? String(localized: "You'll get a reminder to start a trip when you arrive. Each member chooses this for themselves.")
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

    @ViewBuilder
    private func memberRow(_ member: HouseholdMember) -> some View {
        let content = HStack(spacing: 12) {
            ProfilePicture(
                imageData: repo.isCurrentUser(member) ? repo.profileImageData : member.profileImageData,
                size: 30
            )
            Text(member.displayName)
            Spacer()
            Text(member.role.localizedName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
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

    private var canSaveGroupName: Bool {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return repo.isOwnerOfCurrentGroup && !trimmed.isEmpty && trimmed != committedGroupName
    }

    @ViewBuilder
    private func commitButton(isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.success()
            action()
        } label: {
            Image(systemName: "checkmark.circle.fill")
                .imageScale(.large)
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .accessibilityLabel("Save")
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

    private func purgeAllData() {
        purging = true
        Task {
            do {
                try await repo.purgeAndRebootstrap()
                groupName = repo.currentHousehold?.name ?? ""
                Haptics.success()
            } catch {
                Haptics.error()
                print("[Settings] purge failed: \(error)")
            }
            purging = false
        }
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
    @State private var showingCopiedConfirmation = false
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

            Text("Shopping is better with friends")
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

                Button(action: copyLink) {
                    Text("Copy Link")
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
        .alert("Link Copied", isPresented: $showingCopiedConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The invite link has been copied.")
        }
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

    /// Mints a single-use invite link and drops it on the clipboard.
    private func copyLink() {
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
                let url: URL
                if #available(iOS 26.0, *) {
                    // Single-use link that can't be reshared once accepted.
                    url = try await repo.prepareOneTimeInviteURL()
                } else {
                    url = try await repo.prepareInviteLink()
                }
                UIPasteboard.general.url = url
                Haptics.success()
                showingCopiedConfirmation = true
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
                withAnimation(.snappy) { sent = true }
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
                            withAnimation(.snappy) {
                                offset = shouldOpen ? -actionWidth : 0
                                openRowId = shouldOpen ? id : nil
                            }
                        }
                )
        }
        .clipped()
        .onChange(of: openRowId) { _, newValue in
            if newValue != id, offset != 0 {
                withAnimation(.snappy) { offset = 0 }
            }
        }
    }

    private func close() {
        withAnimation(.snappy) {
            offset = 0
            openRowId = nil
        }
    }
}
