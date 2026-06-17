import SwiftUI

/// Device-local app preferences, reachable from Settings → Preferences.
///
/// Each setting is its own standalone card with the title baked in — matching
/// the reference design — rather than separate gray section headers.
struct PreferencesView: View {
    @Environment(SettingsStore.self) private var settings

    /// Prominent in-card title. Uses the standard system font (bold).
    private let titleFont = Font.system(size: 22, weight: .bold)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                liveActivitiesCard
                notificationsCard
                appearanceCard
                appIconCard
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
    }

    // MARK: - Cards

    private var liveActivitiesCard: some View {
        featureCard {
            VStack(alignment: .leading, spacing: 18) {
                liveActivityPreview
                toggleHeader(
                    String(localized: "Live Activities"),
                    subtitle: String(localized: "Show the current shopping trip on your Lock Screen and Dynamic Island."),
                    isOn: liveActivitiesBinding
                )
            }
        }
    }

    private var notificationsCard: some View {
        toggleCard(
            String(localized: "Shopping notifications"),
            subtitle: String(localized: "Get a heads-up when someone starts a trip or changes the shared list."),
            isOn: notificationsBinding
        )
    }

    private var appearanceCard: some View {
        featureCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("Appearance")
                    .font(titleFont)
                HStack(spacing: 12) {
                    ForEach(AppAppearance.allCases) { option in
                        appearanceTile(option)
                    }
                }
            }
        }
    }

    private var appIconCard: some View {
        featureCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("App Icon")
                    .font(titleFont)
                HStack(spacing: 14) {
                    appIconPreview
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default")
                            .font(.body.weight(.semibold))
                        Text("More icons coming soon.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Appearance picker

    private var liveActivityPreview: some View {
        Image("LiveActivityPreview")
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private var appIconPreview: some View {
        Image("PreferencesAppIcon")
            .resizable()
            .scaledToFill()
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func appearanceTile(_ option: AppAppearance) -> some View {
        let isSelected = settings.appearance == option
        return Button {
            Haptics.selection()
            settings.appearance = option
        } label: {
            VStack(spacing: 10) {
                appearancePreview(option)
                    .frame(height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color(.separator).opacity(0.4),
                                          lineWidth: isSelected ? 2.5 : 1)
                    }
                Text(option.localizedName)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func appearancePreview(_ option: AppAppearance) -> some View {
        switch option {
        case .light:
            previewContent(background: .white, ink: Color.black.opacity(0.12))
        case .dark:
            previewContent(background: Color(white: 0.12), ink: Color.white.opacity(0.22))
        case .system:
            ZStack {
                previewContent(background: .white, ink: Color.black.opacity(0.12))
                previewContent(background: Color(white: 0.12), ink: Color.white.opacity(0.22))
                    .clipShape(DiagonalSplit())
            }
        }
    }

    private func previewContent(background: Color, ink: Color) -> some View {
        background.overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 14, height: 14)
                RoundedRectangle(cornerRadius: 2.5).fill(ink).frame(width: 36, height: 6)
                RoundedRectangle(cornerRadius: 2.5).fill(ink).frame(width: 24, height: 6)
            }
            .padding(11)
        }
    }

    // MARK: - Bindings

    private var liveActivitiesBinding: Binding<Bool> {
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

    // MARK: - Building blocks

    /// A standalone setting card: large rounded surface with generous padding.
    @ViewBuilder
    private func featureCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
            }
    }

    private func toggleCard(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        featureCard {
            toggleHeader(title, subtitle: subtitle, isOn: isOn)
        }
    }

    private func toggleHeader(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(titleFont)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }
}

/// Diagonal mask used for the "System" appearance preview — covers the right
/// portion so a light layer underneath shows through on the left.
private struct DiagonalSplit: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX * 0.56, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX * 0.44, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#if DEBUG
#Preview("Preferences") {
    NavigationStack {
        PreferencesView()
            .grocerPreviewEnvironment()
    }
}
#endif
