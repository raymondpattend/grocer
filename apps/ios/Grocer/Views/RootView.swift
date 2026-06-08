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
    }

    private var shouldShowOnboarding: Bool {
        Self.forceShowOnboardingForDebug || (repo.hasCompletedInitialLoad && repo.households.isEmpty)
    }
}

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

private struct OnboardingView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(SettingsStore.self) private var settings

    @State private var displayName = ""
    @State private var selectedProfilePhoto: PhotosPickerItem?
    @State private var hasConfirmedProfile = false
    @State private var showCreateGroup = false
    @State private var showJoinHelp = false

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSaveProfile: Bool {
        !trimmedDisplayName.isEmpty
    }

    private var profileIsDirty: Bool {
        trimmedDisplayName != repo.displayName && !trimmedDisplayName.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                profilePanel
                if hasConfirmedProfile {
                    groupChoicePanel
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Welcome")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SyncStatusBar(state: repo.syncState)
        }
        .onAppear(perform: loadProfile)
        .onChange(of: selectedProfilePhoto) { _, newItem in
            loadProfilePhoto(newItem)
        }
        .sheet(isPresented: $showCreateGroup) {
            NavigationStack {
                GroupEditorView(group: nil)
            }
        }
        .sheet(isPresented: $showJoinHelp) {
            JoinExistingGroupHelpView()
        }
        .animation(.default, value: hasConfirmedProfile)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            appIcon
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up Grocer")
                    .font(.largeTitle.bold())
                Text("Add the profile your group will see.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 18)
    }

    private var appIcon: some View {
        Group {
            if let image = UIImage(named: "AppIcon") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Image(systemName: "cart.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.green, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(width: 72, height: 72)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .accessibilityHidden(true)
    }

    private var profilePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Profile")
                .font(.headline)

            HStack(alignment: .center, spacing: 16) {
                PhotosPicker(selection: $selectedProfilePhoto, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        OnboardingProfilePicture(imageData: settings.profileImageData, size: 88)
                        Image(systemName: "camera.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.green, in: Circle())
                            .overlay {
                                Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2)
                            }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose profile photo")

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Your name", text: $displayName)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .font(.title3.weight(.semibold))
                        .onSubmit(saveProfile)
                        .padding(.horizontal, 12)
                        .frame(height: 48)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text("Choose a photo and enter your name.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if hasConfirmedProfile {
                HStack(spacing: 10) {
                    Label(profileIsDirty ? "Unsaved changes" : "Profile saved",
                          systemImage: profileIsDirty ? "pencil.circle" : "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(profileIsDirty ? .orange : .green)

                    Spacer()

                    if profileIsDirty {
                        Button("Save", action: saveProfile)
                            .font(.subheadline.weight(.semibold))
                            .disabled(!canSaveProfile)
                    }
                }
            } else {
                Button(action: saveProfile) {
                    Label("Continue", systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)
                .disabled(!canSaveProfile)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var groupChoicePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Group")
                .font(.headline)

            VStack(spacing: 12) {
                Button {
                    saveProfile()
                    showCreateGroup = true
                } label: {
                    Label("Create Group", systemImage: "person.2.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)
                .disabled(!canSaveProfile || !repo.hasCompletedInitialLoad)

                Button {
                    saveProfile()
                    showJoinHelp = true
                } label: {
                    Label("Learn How to Join", systemImage: "link")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!canSaveProfile)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func loadProfile() {
        guard displayName.isEmpty else { return }
        let savedName = settings.displayName == "Me" ? "" : settings.displayName
        displayName = savedName
        hasConfirmedProfile = !savedName.isEmpty
    }

    private func saveProfile() {
        guard canSaveProfile else { return }
        repo.updateDisplayName(trimmedDisplayName)
        displayName = trimmedDisplayName
        hasConfirmedProfile = true
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
