import PhotosUI
import SwiftUI
import UIKit

/// Top-level navigation. Defaults to the planning list; the shopper can drill
/// into the focused Shopping Session screen when one is active.
struct RootView: View {
    /// Flip to `true` while debugging to show onboarding even after groups exist.
    static var forceShowOnboardingForDebug = false

    @Environment(GroceryRepository.self) private var repo
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if shouldShowOnboarding {
                NavigationStack {
                    OnboardingView()
                }
            } else {
                NavigationStack {
                    GroceryListView()
                }
            }
        }
        .background(KeyboardWarmer())
        .onAppear {
            repo.startForegroundRefreshLoop()
        }
        .onDisappear {
            repo.stopForegroundRefreshLoop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                repo.startForegroundRefreshLoop()
                Task { await repo.refreshAfterActivation() }
            } else {
                repo.stopForegroundRefreshLoop()
            }
        }
        .sheet(isPresented: Binding(
            get: { repo.joinedHouseholdId != nil },
            set: { if !$0 { repo.dismissJoinedHousehold() } }
        )) {
            JoinedGroupSheet()
        }
    }

    private var shouldShowOnboarding: Bool {
        Self.forceShowOnboardingForDebug || (repo.hasCompletedInitialLoad && repo.households.isEmpty)
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
                        Text(member.role.rawValue)
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
#Preview("Joined Group") {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SyncStatusBar(state: repo.syncState)
        }
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
                    Text("This is how your group will see you.")
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
                Button(action: continueToCreateGroup) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)
                .disabled(!canContinue || !repo.hasCompletedInitialLoad)

                Button("Join an Existing Group", action: onJoinExisting)
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
        let savedName = settings.displayName == "Me" ? "" : settings.displayName
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
                    Label("Ask a group owner to send an invite from Settings.", systemImage: "person.crop.circle.badge.plus")
                    Label("Open the invite link on this iPhone.", systemImage: "link")
                    Label("Grocer will add the shared group after iCloud accepts it.", systemImage: "icloud.and.arrow.down")
                }
            }
            .navigationTitle("Join a Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
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

#Preview("Onboarding Create Group") {
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

/// Small sync status pill shown when offline / syncing.
struct SyncStatusBar: View {
    let state: GroceryRepository.SyncState

    var body: some View {
        switch state {
        case .idle, .syncing:
            EmptyView()
        case .offline, .error:
            label("Offline — changes will sync later", systemImage: "icloud.slash", tint: .gray)
        }
        // Errors are not handled here because they are often unreliable or inaccurate
    }

    private func label(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}

struct CategoryHeader: View {
    let category: GroceryCategory
    var body: some View {
        Label(category.rawValue, systemImage: category.systemImage)
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
