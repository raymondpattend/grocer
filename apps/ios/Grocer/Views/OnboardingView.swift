import PhotosUI
import PostHog
import SwiftUI
import UIKit

// MARK: - Onboarding

private enum OnboardingSheet: Identifiable {
    case profile
    case createGroup
    case joinHelp

    var id: Self { self }
}

/// First-run hero shown by `RootView` while the account has no groups yet.
/// Walks a new shopper through naming themselves and creating (or joining)
/// their first list.
struct OnboardingView: View {
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
        .postHogScreenView("Onboarding")
    }

    private var onboardingLogo: some View {
        Group {
            if let image = UIImage(named: "AppIcon") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            } else {
                FAImage("cart.fill", size: 72)
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
                        FAImage("camera.circle.fill", relativeTo: .title3)
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
        .postHogScreenView("Onboarding Profile")
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
                FAImage("person.crop.circle.fill", size: size)
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
                    FALabel("Ask a list owner to send an invite from Settings.", icon: "person.crop.circle.badge.plus")
                    FALabel("Open the invite link on this iPhone.", icon: "link")
                    FALabel("Grocer will add the shared list after iCloud accepts it.", icon: "icloud.and.arrow.down")
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
            .postHogScreenView("Join List Help")
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
#endif
