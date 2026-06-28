import PostHog
import SwiftUI

// MARK: - App Settings feature screens
//
// The old combined "Preferences" screen is split into one screen per feature —
// Live Activities, Notifications, and App Appearance — each reachable from
// Settings → App Settings. They share the card style and chrome below.

/// Prominent in-card title used across the feature screens.
private let featureTitleFont = Font.system(.title2, design: .default, weight: .bold)

/// A standalone setting card: large rounded surface with generous padding.
private struct FeatureCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
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
}

/// Shared chrome for the feature screens: scrolling grouped background plus the
/// haptic back button that the rest of Settings uses.
private struct FeatureScreenChrome: ViewModifier {
    func body(content: Content) -> some View {
        ScrollView {
            content
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
}

/// Framed lock-screen / notification preview image used atop the toggle cards.
private func featurePreviewImage(_ name: String) -> some View {
    Image(name)
        .resizable()
        .scaledToFit()
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
        }
        .accessibilityHidden(true)
}

/// Title + subtitle on the left, toggle on the right.
private func featureToggleHeader(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
    HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(featureTitleFont)
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

// MARK: - Live Activities

struct LiveActivitiesSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(spacing: 16) {
            FeatureCard {
                VStack(alignment: .leading, spacing: 18) {
                    featurePreviewImage("LiveActivityPreview")
                    featureToggleHeader(
                        String(localized: "Live Activities"),
                        subtitle: String(localized: "Show the current shopping trip on your Lock Screen and Dynamic Island."),
                        isOn: liveActivitiesBinding
                    )
                }
            }
        }
        .modifier(FeatureScreenChrome())
        .postHogScreenView("Live Activities")
    }

    private var liveActivitiesBinding: Binding<Bool> {
        Binding(
            get: { settings.familyLiveActivitiesEnabled },
            set: { newValue in
                settings.familyLiveActivitiesEnabled = newValue
                LiveActivityManager.shared.familyPreferenceChanged()
            }
        )
    }
}

// MARK: - Notifications

struct NotificationsSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(spacing: 16) {
            FeatureCard {
                VStack(alignment: .leading, spacing: 18) {
                    featurePreviewImage("NotificationPreview")
                    featureToggleHeader(
                        String(localized: "Shopping notifications"),
                        subtitle: String(localized: "Get a heads-up when someone starts a trip or changes the shared list."),
                        isOn: notificationsBinding
                    )
                }
            }
        }
        .modifier(FeatureScreenChrome())
        .postHogScreenView("Notifications")
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
}

// MARK: - App Appearance

struct AppearanceSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(SubscriptionStore.self) private var subscriptions

    /// Live home-screen icon selection. Source of truth is
    /// `UIApplication.alternateIconName`; mirrored here so tiles update at once.
    @State private var selectedIcon: AppIcon = .default
    /// Presented when a non-Pro user taps a Pro-only icon.
    @State private var showProPaywall = false

    var body: some View {
        VStack(spacing: 16) {
            appearanceCard
            appIconCard
        }
        .modifier(FeatureScreenChrome())
        .onAppear { selectedIcon = AppIconManager.current }
        .fullScreenCover(isPresented: $showProPaywall) {
            GrocerProPaywallView()
        }
        .postHogScreenView("App Appearance")
    }

    private var appearanceCard: some View {
        FeatureCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("Appearance")
                    .font(featureTitleFont)
                HStack(spacing: 12) {
                    ForEach(AppAppearance.allCases) { option in
                        appearanceTile(option)
                    }
                }
            }
        }
    }

    private var appIconCard: some View {
        FeatureCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("App Icon")
                    .font(featureTitleFont)
                HStack(spacing: 12) {
                    ForEach(AppIcon.allCases) { option in
                        appIconTile(option)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func appIconTile(_ option: AppIcon) -> some View {
        let isSelected = selectedIcon == option
        let isLocked = option.requiresPro && !subscriptions.hasGrocerPro
        return Button {
            Haptics.selection()
            if isLocked {
                showProPaywall = true
            } else {
                selectedIcon = option
                Task { await AppIconManager.set(option) }
            }
        } label: {
            VStack(spacing: 10) {
                Image(option.previewImageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .saturation(isLocked ? 0 : 1)
                    .opacity(isLocked ? 0.55 : 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color(.separator).opacity(0.4),
                                          lineWidth: isSelected ? 2.5 : 1)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Color.accentColor, in: Circle())
                                .padding(4)
                        }
                    }
                    .accessibilityHidden(true)
                Text(option.localizedName)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.localizedName)
        .accessibilityValue(isLocked ? Text("Grocer Pro required") : Text(""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Appearance picker

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
                    .accessibilityHidden(true)
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
#Preview("Live Activities") {
    NavigationStack {
        LiveActivitiesSettingsView()
            .grocerPreviewEnvironment()
    }
}

#Preview("Notifications") {
    NavigationStack {
        NotificationsSettingsView()
            .grocerPreviewEnvironment()
    }
}

#Preview("App Appearance") {
    NavigationStack {
        AppearanceSettingsView()
            .grocerPreviewEnvironment()
    }
}
#endif
