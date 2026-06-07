import PhotosUI
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var showFeedback = false
    @State private var apiHealthy: Bool?
    @State private var displayName = ""
    @State private var groupName = ""
    @State private var shareError: String?
    @State private var preparingShare = false
    @State private var confirmLeave = false
    @State private var confirmPurge = false
    @State private var purging = false
    @State private var selectedProfilePhoto: PhotosPickerItem?

    var body: some View {
        Form {
            profileSection
            groupSection
            membersSection
            liveActivitiesSection
            notificationsSection
            diagnosticsSection
            actionsSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    commitPendingChanges()
                    dismiss()
                }
            }
        }
        .task { apiHealthy = await APIClient.shared.health() }
        .onAppear {
            displayName = repo.displayName
            groupName = repo.currentHousehold?.name ?? ""
        }
        .onChange(of: repo.currentHousehold?.id) { _, _ in
            groupName = repo.currentHousehold?.name ?? ""
        }
        .onChange(of: selectedProfilePhoto) { _, newItem in
            loadProfilePhoto(newItem)
        }
        .onDisappear {
            commitPendingChanges()
        }
        .alert("Couldn’t start sharing", isPresented: Binding(
            get: { shareError != nil }, set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(shareError ?? "") }
        .confirmationDialog("Leave this group?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave Group", role: .destructive) { repo.leaveCurrentGroup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’ll stop seeing this group’s lists on this device.")
        }
        .confirmationDialog("Delete all data?", isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive) { purgeAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all groups, lists, and items from iCloud. A fresh default group will be created.")
        }
        .sheet(isPresented: $showFeedback) { NavigationStack { FeedbackView() } }
    }

    private func canRemove(_ member: HouseholdMember) -> Bool {
        repo.isOwnerOfCurrentGroup && member.role != .owner
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

    private var profileSection: some View {
        Section("Profile") {
            HStack(alignment: .center, spacing: 16) {
                PhotosPicker(selection: $selectedProfilePhoto, matching: .images) {
                    ProfilePicture(imageData: repo.profileImageData, size: 72)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Change profile photo")

                HStack {
                    TextField("Your Name", text: $displayName)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit { commitDisplayName() }
                    commitButton(isEnabled: canSaveDisplayName) {
                        commitDisplayName()
                    }
                }
            }
        }
    }

    private var groupSection: some View {
        Section("Group") {
            HStack {
                TextField("Group Name", text: $groupName)
                    .submitLabel(.done)
                    .onSubmit { commitGroupName() }
                commitButton(isEnabled: canSaveGroupName) {
                    commitGroupName()
                }
            }
        }
    }

    private var membersSection: some View {
        Section {
            Button {
                inviteMember()
            } label: {
                HStack {
                    Label("Invite to Group", systemImage: "person.crop.circle.badge.plus")
                    if preparingShare { Spacer(); ProgressView() }
                }
            }
            .disabled(!repo.canShare || preparingShare)

            ForEach(repo.currentMembers) { member in
                memberRow(member)
                .swipeActions {
                    removeMemberSwipeAction(for: member)
                }
            }
        } header: {
            Text("Members")
        } footer: {
            if let reason = repo.sharingUnavailableReason {
                Text(reason)
            } else if repo.isOwnerOfCurrentGroup {
                Text("Swipe a member to remove them from this group.")
            }
        }
    }

    private var liveActivitiesSection: some View {
        Section {
            Toggle("Show Live Activities",
                   isOn: familyLiveActivitiesBinding)
        } header: {
            Text("Live Activities")
        } footer: {
            Text("When enabled, active group grocery trips can appear on your Lock Screen or Dynamic Island so you can follow shopping progress.")
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle("Group shopping notifications", isOn: notificationsBinding)
        } header: {
            Text("Notifications")
        } footer: {
            Text("Get an alert when someone in this group starts or ends a shopping trip.")
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            HStack {
                Text("API status")
                Spacer()
                switch apiHealthy {
                case .some(true): Label("Healthy", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .some(false): Label("Unreachable", systemImage: "xmark.circle.fill").foregroundStyle(.orange)
                case .none: ProgressView()
                }
            }
            LabeledContent("Sync", value: syncLabel)
            LabeledContent("CloudKit", value: repo.usingCloudKit ? "Active" : "Disabled")
            LabeledContent("Container", value: CloudKitService.shared.container != nil ? "OK" : "nil")
            LabeledContent("Groups", value: "\(repo.households.count)")
            LabeledContent("Members", value: "\(repo.members.count)")
            LabeledContent("Lists", value: "\(repo.lists.count)")
            LabeledContent("Items", value: "\(repo.items.count)")
            LabeledContent("App version", value: settings.appVersion)

            Button("Force Refresh") {
                Task {
                    do {
                        try await repo.refresh()
                    } catch {
                        print("[Settings] force refresh failed: \(error)")
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button { showFeedback = true } label: {
                Label("Send Feedback", systemImage: "envelope")
            }
            if repo.households.count > 1 || !repo.isOwnerOfCurrentGroup {
                Button(role: .destructive) { confirmLeave = true } label: {
                    Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            Button(role: .destructive) { confirmPurge = true } label: {
                HStack {
                    Label("Reset All Data", systemImage: "trash")
                    if purging { Spacer(); ProgressView() }
                }
            }
            .disabled(purging)
        }
    }

    private func memberRow(_ member: HouseholdMember) -> some View {
        HStack(spacing: 12) {
            ProfilePicture(
                imageData: repo.isCurrentUser(member) ? repo.profileImageData : member.profileImageData,
                size: 32
            )
            Text(member.displayName)
            Spacer()
            Text(member.role.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func removeMemberSwipeAction(for member: HouseholdMember) -> some View {
        if canRemove(member) {
            Button(role: .destructive) {
                repo.removeMember(member)
            } label: {
                Label("Remove", systemImage: "person.badge.minus")
            }
        }
    }

    private var canSaveDisplayName: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != repo.displayName
    }

    private var canSaveGroupName: Bool {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != (repo.currentHousehold?.name ?? "")
    }

    @ViewBuilder
    private func commitButton(isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            groupName = repo.currentHousehold?.name ?? ""
            return
        }
        repo.renameGroup(trimmed)
        groupName = trimmed
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

    private func inviteMember() {
        if let reason = repo.sharingUnavailableReason {
            shareError = reason
            return
        }
        preparingShare = true
        Task {
            defer { preparingShare = false }
            do {
                let (share, container) = try await repo.prepareShare()
                ShareSheetPresenter.present(share: share, container: container)
            } catch {
                shareError = error.localizedDescription
            }
        }
    }

    private func purgeAllData() {
        purging = true
        Task {
            do {
                try await repo.purgeAndRebootstrap()
                groupName = repo.currentHousehold?.name ?? ""
            } catch {
                print("[Settings] purge failed: \(error)")
            }
            purging = false
        }
    }

    private var syncLabel: String {
        switch repo.syncState {
        case .idle: return repo.usingCloudKit ? "iCloud synced" : "Local only"
        case .syncing: return "Syncing…"
        case .offline: return "Offline"
        case .error(let m): return m
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
                if ok { message = "" }
            }
        }
    }
}
