import PhotosUI
import SwiftUI
import UIKit

/// Top-level navigation. Defaults to the Home grid of groups; tapping a group
/// drills into its planning list, and the shopper can drill further into the
/// focused Shopping Session screen when one is active.
struct RootView: View {
    /// Flip to `true` while debugging to show onboarding even after groups exist.
    static var forceShowOnboardingForDebug = false

    @Environment(GroceryRepository.self) private var repo
    @Environment(AppUpdateGate.self) private var appUpdateGate
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var showDebug = false

    var body: some View {
        Group {
            if shouldShowOnboarding {
                NavigationStack {
                    OnboardingView()
                }
            } else {
                // HomeView owns its NavigationStack (it drives the push path
                // for the zoom transition into a group's list).
                HomeView()
            }
        }
        .background(KeyboardWarmer())
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 4) {
                CloudIssueChip(issue: repo.cloudIssue)
            }
        }
        .onShake { showDebug = true }
        .sheet(isPresented: $showDebug) {
            DebugView()
        }
        .onAppear {
            repo.startForegroundRefreshLoop()
        }
        .task {
            await appUpdateGate.refresh()
        }
        .onDisappear {
            repo.stopForegroundRefreshLoop()
        }
        .onOpenURL { url in
            guard let householdId = GroupDeepLink.householdId(from: url) else { return }
            GroupNavigationCoordinator.shared.openGroup(householdId: householdId)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                repo.startForegroundRefreshLoop()
                Task {
                    await appUpdateGate.refresh()
                    await repo.refreshAfterActivation()
                    await sendRetentionHeartbeat()
                }
            } else {
                repo.stopForegroundRefreshLoop()
                // Queue a background catch-up sync for changes that arrive (or
                // whose silent push gets throttled) while we're not foreground.
                AppDelegate.scheduleBackgroundRefresh()
            }
        }
        .sheet(isPresented: Binding(
            get: { repo.joinedHouseholdId != nil },
            set: { if !$0 { repo.dismissJoinedHousehold() } }
        )) {
            JoinedGroupSheet()
        }
        .overlay {
            // While CloudKit accepts the invite (before the joined sheet is
            // ready) show a blocking spinner so the tap feels responsive.
            if repo.isAcceptingInvite && repo.joinedHouseholdId == nil {
                AcceptingInviteOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: repo.isAcceptingInvite)
        .fullScreenCover(item: Binding(
            get: { appUpdateGate.requiredUpdate },
            set: { _ in }
        )) { update in
            RequiredAppUpdateView(update: update) {
                openURL(update.updateURL)
            }
            .interactiveDismissDisabled(true)
        }
    }

    private var shouldShowOnboarding: Bool {
        Self.forceShowOnboardingForDebug || (repo.hasCompletedInitialLoad && repo.households.isEmpty)
    }

    /// Tells the backend the app was opened, so the retention cron can measure
    /// inactivity. Debounced to ~once/hour and skipped before any group exists.
    private func sendRetentionHeartbeat() async {
        let settings = SettingsStore.shared
        if let last = settings.lastHeartbeatAt, Date().timeIntervalSince(last) < 3600 {
            return
        }
        let householdId = settings.selectedHouseholdId.isEmpty
            ? repo.households.first?.id
            : settings.selectedHouseholdId
        guard let householdId, !householdId.isEmpty else { return }

        settings.lastHeartbeatAt = Date()
        await APIClient.shared.reportActive(
            HeartbeatPayload(
                householdId: householdId,
                memberId: settings.memberIdOrDevice,
                deviceId: settings.deviceId
            )
        )
    }
}

private struct RequiredAppUpdateView: View {
    let update: RequiredAppUpdate
    let openUpdate: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 10) {
                Text("App Update Required")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text("This version of Grocer is no longer supported. Install the latest update to keep using the app.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Haptics.selection()
                openUpdate()
            } label: {
                Label("Update App", systemImage: "arrow.up.forward.app.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.green)

            Text("Current build \(update.currentBuild). Required build \(update.minimumSupportedBuild).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - Accepting Invite Overlay

/// Blocking spinner shown while a CloudKit share invite is being accepted, so
/// the "Join" tap feels responsive before the joined-group sheet appears.
private struct AcceptingInviteOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)

                Text("Joining list\u{2026}")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .environment(\.colorScheme, .dark)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Joining list"))
    }
}

// MARK: - Joined Group Sheet

private struct JoinedGroupSheet: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    private var household: Household? {
        repo.joinedHouseholdId.flatMap { id in repo.households.first { $0.id == id } }
    }

    private var groupMembers: [HouseholdMember] {
        guard let id = repo.joinedHouseholdId else { return [] }
        return repo.members
            .filter { $0.householdId == id }
            .sorted(by: HouseholdMember.stableDisplayOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                if let household {
                    groupIcon(household)

                    VStack(spacing: 8) {
                        Text("You\u{2019}ve joined \u{201c}\(household.name)\u{201d}")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)

                        if let store = household.storeName {
                            Text(store)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !groupMembers.isEmpty {
                        membersRow
                    }
                }
            }
            .padding(.horizontal, 32)

            Spacer()

            Button {
                Haptics.tap()
                repo.dismissJoinedHousehold()
                dismiss()
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(household?.tint ?? .green)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .presentationDetents([.medium])
    }

    private func groupIcon(_ household: Household) -> some View {
        Image(systemName: household.icon)
            .font(.system(size: 32, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 72, height: 72)
            .background(household.tint.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: household.tint.opacity(0.3), radius: 12, y: 6)
    }

    private var membersRow: some View {
        VStack(spacing: 12) {
            Text("Members")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(groupMembers) { member in
                    HStack(spacing: 12) {
                        memberAvatar(member)
                        Text(member.displayName)
                            .font(.body)
                        Spacer()
                        Text(member.role.localizedName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if member.id != groupMembers.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func memberAvatar(_ member: HouseholdMember) -> some View {
        Group {
            if let data = member.profileImageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
    }
}

#if DEBUG
#Preview("Joined List") {
    @Previewable @State var isPresented = true
    Color.clear
        .sheet(isPresented: $isPresented) {
            JoinedGroupSheetPreview()
        }
}

private struct JoinedGroupSheetPreview: View {
    var body: some View {
        let household = Household(
            id: "preview", name: "Family Groceries", ownerMemberId: "m1",
            storeName: "Whole Foods", icon: "cart.fill",
            colorTheme: .green, createdAt: .now, updatedAt: .now
        )
        let members = [
            HouseholdMember(id: "m1", householdId: "preview", displayName: "Sarah",
                            role: .owner, joinedAt: .now),
            HouseholdMember(id: "m2", householdId: "preview", displayName: "You",
                            role: .member, joinedAt: .now),
        ]
        JoinedGroupSheet()
            .grocerPreviewEnvironment(
                repository: GrocerPreview.repository(
                    households: [household],
                    members: members,
                    joinedHouseholdId: "preview"
                )
            )
    }
}
#endif

/// Forces iOS to initialize its keyboard infrastructure at app launch so the
/// first TextField focus doesn't stall while the system cold-starts the
/// keyboard process.
///
/// A short delay lets the window hierarchy settle before we trigger the
/// warm-up. `becomeFirstResponder` is followed by resign on the *next* run-loop
/// pass so the keyboard process fully spins up before we tear it down.
private struct KeyboardWarmer: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.isUserInteractionEnabled = false
        container.alpha = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let window = container.window else { return }
            let field = UITextField(frame: CGRect(x: -1, y: -1, width: 1, height: 1))
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.inputAssistantItem.leadingBarButtonGroups = []
            field.inputAssistantItem.trailingBarButtonGroups = []
            window.addSubview(field)
            field.becomeFirstResponder()
            DispatchQueue.main.async {
                field.resignFirstResponder()
                field.removeFromSuperview()
            }
        }

        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Onboarding

private enum OnboardingSheet: Identifiable {
    case profile
    case createGroup
    case joinHelp

    var id: Self { self }
}

private struct OnboardingView: View {
    @Environment(GroceryRepository.self) private var repo

    @State private var activeSheet: OnboardingSheet?

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .green, location: 0),
                    .init(color: .black, location: 0.85),
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack {
                Spacer()

                VStack(spacing: 0) {
                    onboardingLogo
                    Text("Your Grocery List.\nWith Magic Powers.")
                        .foregroundStyle(.white)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 80)
                }

                Button {
                    Haptics.selection()
                    activeSheet = .profile
                } label: {
                    Text("Continue")
                        .fontWeight(.medium)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .profile:
                OnboardingProfileSheet(
                    onContinue: {
                        activeSheet = .createGroup
                    },
                    onJoinExisting: {
                        activeSheet = .joinHelp
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            case .createGroup:
                NavigationStack {
                    GroupEditorView(group: nil)
                }
            case .joinHelp:
                JoinExistingGroupHelpView()
            }
        }
    }

    private var onboardingLogo: some View {
        Group {
            if let image = UIImage(named: "AppIcon") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            } else {
                Image(systemName: "cart.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 160, height: 160)
                    .background(.green.opacity(0.35), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
        }
        .frame(width: 160, height: 160)
        .scaleEffect(0.55)
        .accessibilityHidden(true)
    }
}

private struct OnboardingProfileSheet: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(SettingsStore.self) private var settings

    @State private var displayName = ""
    @State private var selectedProfilePhoto: PhotosPickerItem?
    @FocusState private var nameFieldFocused: Bool

    var onContinue: () -> Void
    var onJoinExisting: () -> Void

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinue: Bool {
        !trimmedDisplayName.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Text("Your Profile")
                        .font(.title2.bold())
                    Text("This is how list members will see you.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                PhotosPicker(selection: $selectedProfilePhoto, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        OnboardingProfilePicture(imageData: settings.profileImageData, size: 96)
                        Image(systemName: "camera.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose profile photo")

                TextField("Your Name", text: $displayName)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.continue)
                    .multilineTextAlignment(.center)
                    .font(.title3)
                    .focused($nameFieldFocused)
                    .onSubmit(continueToCreateGroup)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            Spacer()

            VStack(spacing: 16) {
                Button {
                    Haptics.selection()
                    continueToCreateGroup()
                } label: {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)
                .disabled(!canContinue || !repo.hasCompletedInitialLoad)

                Button("Join an Existing List") {
                    Haptics.selection()
                    onJoinExisting()
                }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear(perform: loadProfile)
        .onChange(of: selectedProfilePhoto) { _, newItem in
            loadProfilePhoto(newItem)
        }
    }

    private func loadProfile() {
        guard displayName.isEmpty else { return }
        let savedName = (settings.displayName == String(localized: "Me") || settings.displayName == "Me")
            ? ""
            : settings.displayName
        displayName = savedName
    }

    private func continueToCreateGroup() {
        guard canContinue else { return }
        repo.updateDisplayName(trimmedDisplayName)
        displayName = trimmedDisplayName
        nameFieldFocused = false
        onContinue()
    }

    private func loadProfilePhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            let imageData: Data?
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                imageData = image.onboardingProfileImageData()
            } else {
                imageData = nil
            }

            await MainActor.run {
                if let imageData {
                    repo.updateProfileImageData(imageData)
                }
                selectedProfilePhoto = nil
            }
        }
    }
}

private struct OnboardingProfilePicture: View {
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
                    .foregroundStyle(Color(.systemFill))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct JoinExistingGroupHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Ask a list owner to send an invite from Settings.", systemImage: "person.crop.circle.badge.plus")
                    Label("Open the invite link on this iPhone.", systemImage: "link")
                    Label("Grocer will add the shared list after iCloud accepts it.", systemImage: "icloud.and.arrow.down")
                }
            }
            .navigationTitle("Join a List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.tap()
                        dismiss()
                    }
                }
            }
        }
    }
}

#if DEBUG
// MARK: - Onboarding Previews

#Preview("Onboarding Hero") {
    NavigationStack {
        OnboardingView()
    }
    .grocerPreviewEnvironment()
}

#Preview("Onboarding Profile Sheet") {
    @Previewable @State var isPresented = true
    Color.clear
        .sheet(isPresented: $isPresented) {
            OnboardingProfileSheet(onContinue: {}, onJoinExisting: {})
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .grocerPreviewEnvironment()
        }
}

#Preview("Onboarding Create List") {
    @Previewable @State var isPresented = true
    Color.clear
        .sheet(isPresented: $isPresented) {
            NavigationStack {
                GroupEditorView(group: nil)
            }
            .grocerPreviewEnvironment()
        }
}

#Preview("Root — Onboarding") {
    RootView()
        .grocerPreviewEnvironment()
}
#endif

private extension UIImage {
    func onboardingProfileImageData(maxPixelSize: CGFloat = 512,
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

// MARK: - Shared small components

/// Compact status chip floated at the very top of the app, shown *only* for
/// severe problems (iCloud signed out, offline, or a sync error). Minor states
/// like "saving" or pending writes are intentionally silent. Tapping the chip
/// explains the cause and how to fix it.
struct CloudIssueChip: View {
    let issue: GroceryRepository.CloudIssue?

    @State private var detailIssue: CloudIssuePresentation?

    var body: some View {
        Group {
            if let issue {
                Button {
                    Haptics.tap()
                    detailIssue = CloudIssuePresentation(issue: issue)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Self.icon(for: issue))
                        Text(Self.title(for: issue))
                            .fontWeight(.semibold)
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                    .foregroundStyle(Self.tint(for: issue))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Self.tint(for: issue).opacity(0.35), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityLabel(Text(Self.title(for: issue)))
                .accessibilityHint(Text("Shows how to fix this"))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: issue) { _, newIssue in
            guard detailIssue != nil else { return }
            detailIssue = newIssue.map(CloudIssuePresentation.init(issue:))
        }
        .sheet(item: $detailIssue) { presentation in
            CloudIssueDetailSheet(issue: presentation.issue)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private struct CloudIssuePresentation: Identifiable, Equatable {
        let issue: GroceryRepository.CloudIssue

        var id: String {
            switch issue {
            case .iCloudUnavailable:
                return "icloud-unavailable"
            case .offline:
                return "offline"
            case .syncError(let message):
                return "sync-error-\(message)"
            }
        }
    }

    static func icon(for issue: GroceryRepository.CloudIssue) -> String {
        switch issue {
        case .iCloudUnavailable: return "exclamationmark.icloud"
        case .offline: return "icloud.slash"
        case .syncError: return "exclamationmark.icloud"
        }
    }

    static func title(for issue: GroceryRepository.CloudIssue) -> String {
        switch issue {
        case .iCloudUnavailable: return String(localized: "iCloud")
        case .offline: return String(localized: "Offline")
        case .syncError: return String(localized: "Sync issue")
        }
    }

    static func tint(for issue: GroceryRepository.CloudIssue) -> Color {
        switch issue {
        case .iCloudUnavailable: return .orange
        case .offline: return .secondary
        case .syncError: return .red
        }
    }
}

/// Explains a `CloudIssue` and how to resolve it, with a shortcut to Settings for
/// iCloud account problems.
private struct CloudIssueDetailSheet: View {
    let issue: GroceryRepository.CloudIssue

    @Environment(GroceryRepository.self) private var repo
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)

            Image(systemName: CloudIssueChip.icon(for: issue))
                .font(.system(size: 44, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(CloudIssueChip.tint(for: issue))

            Text(heading)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(explanation)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            Spacer()

            if showsOpenSettings {
                Button {
                    Haptics.selection()
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text("Open Settings")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .grocerGlassButton(prominent: true)
                .controlSize(.large)
            } else {
                Button {
                    Haptics.selection()
                    retry()
                } label: {
                    HStack(spacing: 8) {
                        if isRetrying { ProgressView().controlSize(.small) }
                        Text(isRetrying ? "Checking…" : "Try Again")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .grocerGlassButton(prominent: true)
                .controlSize(.large)
                .disabled(isRetrying)
            }

            Button(role: .cancel) {
                Haptics.tap()
                dismiss()
            } label: {
                Text("Close")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .grocerGlassButton()
            .controlSize(.large)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
    }

    private func retry() {
        isRetrying = true
        Task {
            await repo.retryCloudConnection()
            isRetrying = false
            if repo.cloudIssue == nil { dismiss() }
        }
    }

    private var heading: String {
        switch issue {
        case .iCloudUnavailable: return String(localized: "iCloud is unavailable")
        case .offline: return String(localized: "You're offline")
        case .syncError: return String(localized: "Sync needs attention")
        }
    }

    private var explanation: String {
        switch issue {
        case .iCloudUnavailable:
            return String(localized: "Grocer keeps your lists in sync through iCloud. Open Settings, tap your name, and make sure you're signed in to iCloud with iCloud Drive turned on for Grocer.")
        case .offline:
            return String(localized: "Your changes are saved on this device and will sync automatically once you're back online. Check your Wi‑Fi or cellular connection.")
        case .syncError(let message):
            let base = String(localized: "Something went wrong while syncing. Pull down to refresh to try again.")
            return message.isEmpty ? base : "\(base)\n\n\(message)"
        }
    }

    private var showsOpenSettings: Bool {
        if case .iCloudUnavailable = issue { return true }
        return false
    }
}

struct CategoryHeader: View {
    let category: GroceryCategory
    var count: Int?
    var body: some View {
        HStack(spacing: 6) {
            Label(category.localizedName, systemImage: category.systemImage)
            if let count {
                Text("•")
                Text("^[\(count) item](inflect: true)")
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(nil)
    }
}

/// Shimmer placeholder shown while the initial iCloud fetch is in progress,
/// preventing "No groups yet" from flashing before data arrives.
/// Matches the card-based ScrollView layout of the real list.
struct GroceryListSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            // Quick-add skeleton
            skeletonQuickAdd
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            // Category group 1 (3 items)
            skeletonGroup(headerWidth: 72, itemCount: 3)
                .padding(.bottom, 12)

            // Category group 2 (2 items)
            skeletonGroup(headerWidth: 56, itemCount: 2)
                .padding(.bottom, 12)
        }
    }

    private var skeletonQuickAdd: some View {
        HStack(spacing: 10) {
            ShimmerCircle()
                .frame(width: 24, height: 24)
            ShimmerRect(cornerRadius: 4)
                .frame(height: 16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func skeletonGroup(headerWidth: CGFloat, itemCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ShimmerRect(cornerRadius: 3)
                .frame(width: headerWidth, height: 12)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .padding(.top, 4)

            VStack(spacing: 0) {
                ForEach(0..<itemCount, id: \.self) { index in
                    skeletonItemRow
                    if index < itemCount - 1 {
                        Divider().padding(.leading, 76)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private var skeletonItemRow: some View {
        HStack(spacing: 12) {
            ShimmerRect(cornerRadius: 10)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                ShimmerRect(cornerRadius: 4)
                    .frame(width: 110, height: 14)
                ShimmerRect(cornerRadius: 3)
                    .frame(width: 70, height: 10)
            }

            Spacer()

            ShimmerCircle()
                .frame(width: 28, height: 28)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
