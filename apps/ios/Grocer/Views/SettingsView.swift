import PhotosUI
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(SettingsStore.self) private var settings
    @Environment(SubscriptionStore.self) private var subscriptions
    @Environment(\.dismiss) private var dismiss

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

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                profileHeader
                proCard
                generalSection
                membersSection
                preferencesSection
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Haptics.selection()
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .accessibilityLabel("Back")
            }
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
            repo.isOwnerOfCurrentGroup ? "Delete this group?" : "Leave this group?",
            isPresented: $confirmLeave,
            titleVisibility: .visible
        ) {
            Button(repo.isOwnerOfCurrentGroup ? "Delete Group" : "Leave Group", role: .destructive) {
                Haptics.warning()
                repo.leaveCurrentGroup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(repo.isOwnerOfCurrentGroup
                 ? "As the owner, this deletes the group and its list for everyone."
                 : "You’ll stop seeing this group’s lists on this device.")
        }
        .confirmationDialog("Delete all data?", isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive) {
                Haptics.warning()
                purgeAllData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all groups, lists, and items from iCloud. You can create or join a group again afterward.")
        }
        .sheet(isPresented: $showInviteIntro) {
            InviteToGroupSheet()
        }
        .sheet(item: $editingGroup) { group in
            NavigationStack { GroupEditorView(group: group) }
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
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Grocer")
                        .font(.title2.weight(.bold))
                    Text("Pro")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.yellow, in: Capsule())
                }

                Text(subscriptions.hasGrocerPro
                     ? subscriptions.displayStatus
                     : "Get Pro to unlock all features")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Button {
                    Haptics.selection()
                    showProPaywall = true
                } label: {
                    Text(subscriptions.hasGrocerPro ? "View Plans" : "Try for free")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(.systemBackground))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(Color.primary, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }

    // MARK: - General

    private var generalSection: some View {
        settingsSection("Group") {
            card {
                if repo.isOwnerOfCurrentGroup {
                    HStack(spacing: 14) {
                        Image(systemName: "person.2.fill")
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                        TextField("Group Name", text: $groupName)
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
                        Text("Group")
                        Spacer()
                        Text(repo.currentHousehold?.name ?? "Group")
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
                        rowLabel("Customize Group", systemImage: "paintbrush", chevron: true)
                    }
                    .buttonStyle(.plain)
                }

                rowDivider

                NavigationLink {
                    TripHistoryView()
                } label: {
                    rowLabel("Trip History", systemImage: "clock.arrow.circlepath", chevron: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Members

    private var membersSection: some View {
        let canInvite = repo.isOwnerOfCurrentGroup && repo.canShare
        return settingsSection("Members", footer: membersFooter) {
            card {
                Button {
                    Haptics.selection()
                    showInviteIntro = true
                } label: {
                    rowLabel("Invite to Group", systemImage: "person.crop.circle.badge.plus",
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
            return "Only the group owner can invite people."
        } else if let reason = repo.sharingUnavailableReason {
            return reason
        } else if repo.isOwnerOfCurrentGroup {
            return "Swipe left on a member to remove them from this group."
        }
        return nil
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        settingsSection("Preferences") {
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
        settingsSection("More") {
            card {
                if repo.households.count > 1 || !repo.isOwnerOfCurrentGroup {
                    Button(role: .destructive) { confirmLeave = true } label: {
                        rowLabel(repo.isOwnerOfCurrentGroup ? "Delete Group" : "Leave Group",
                                 systemImage: repo.isOwnerOfCurrentGroup ? "trash" : "rectangle.portrait.and.arrow.right",
                                 destructive: true)
                    }
                    .buttonStyle(.plain)
                    rowDivider
                }

                Button(role: .destructive) { confirmPurge = true } label: {
                    HStack(spacing: 0) {
                        rowLabel("Reset All Data", systemImage: "trash", destructive: true)
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

    @ViewBuilder
    private func memberRow(_ member: HouseholdMember) -> some View {
        let content = HStack(spacing: 12) {
            ProfilePicture(
                imageData: repo.isCurrentUser(member) ? repo.profileImageData : member.profileImageData,
                size: 30
            )
            Text(member.displayName)
            Spacer()
            Text(member.role.rawValue)
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
    @Environment(\.dismiss) private var dismiss

    @State private var preparingShare = false
    @State private var shareError: String?
    @State private var showingContacts = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                closeButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            hero
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)

            VStack(alignment: .leading, spacing: 16) {
                Text("Group Sharing")
                    .font(.largeTitle.bold())

                Text("Add family and friends to share your grocery lists, see who\u{2019}s shopping in real time, and get live updates when items are added or a trip wraps up.")

                Text("It\u{2019}s free, and saves you from ever texting \u{201c}what do we still need?\u{201d} again.")
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)

            Text("Pick people from your contacts and we\u{2019}ll text them an invite link. You can remove members at any time from Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom) {
          VStack(spacing: 0) {
            Button {
                Haptics.selection()
                if let reason = repo.sharingUnavailableReason {
                    shareError = reason
                } else {
                    showingContacts = true
                }
            } label: {
                Text("Choose Contacts")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if #available(iOS 26.0, *) {
                Button("Get a link instead", action: copyInviteLink)
                    .font(.subheadline)
                    .disabled(preparingShare)
                    .padding(.bottom, 12)
            }
          }
        }
        .sheet(isPresented: $showingContacts) {
            InviteContactsView()
        }
        .alert("Couldn\u{2019}t start sharing", isPresented: Binding(
            get: { shareError != nil }, set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(shareError ?? "") }
    }

    /// Secondary escape hatch for recipients who won't resolve via iCloud:
    /// mint a single-use link and hand it to the system share sheet.
    @available(iOS 26.0, *)
    private func copyInviteLink() {
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
                let url = try await repo.prepareOneTimeInviteURL()
                Haptics.success()
                ShareSheetPresenter.presentInvite(url: url)
            } catch {
                Haptics.error()
                shareError = error.localizedDescription
            }
        }
    }

    private var hero: some View {
        Image("SharePromo")
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .modifier(GlassCircleBackground())
        }
        .accessibilityLabel("Close")
    }
}

#if DEBUG
#Preview("Invite to Group") {
    @Previewable @State var isPresented = true
    Color.clear
        .sheet(isPresented: $isPresented) {
            InviteToGroupSheet()
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
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
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
