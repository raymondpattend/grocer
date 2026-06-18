import SwiftUI
import UIKit

/// Shared taptic feedback for discrete UI actions.
enum Haptics {
    private static var lastFeedbackAt = Date.distantPast

    /// A light tap for ordinary button presses and navigation.
    static func tap() {
        impact(.light, intensity: 0.7)
    }

    /// A selection tick for toggles, pickers, and expandable rows.
    static func selection() {
        play(minimumSpacing: 0.04) {
            let generator = UISelectionFeedbackGenerator()
            generator.prepare()
            generator.selectionChanged()
        }
    }

    /// A success notification when an item/action is committed.
    static func success() {
        notification(.success)
    }

    /// A warning notification for destructive or risky actions.
    static func warning() {
        notification(.warning)
    }

    /// A failure notification for actions that could not complete.
    static func error() {
        notification(.error)
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle,
                               intensity: CGFloat,
                               minimumSpacing: TimeInterval = 0.04) {
        play(minimumSpacing: minimumSpacing) {
            let generator = UIImpactFeedbackGenerator(style: style)
            generator.prepare()
            generator.impactOccurred(intensity: intensity)
        }
    }

    private static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        play(minimumSpacing: 0.04) {
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(type)
        }
    }

    private static func play(minimumSpacing: TimeInterval,
                             _ feedback: @escaping () -> Void) {
        let work = {
            let now = Date()
            guard now.timeIntervalSince(lastFeedbackAt) >= minimumSpacing else { return }
            lastFeedbackAt = now
            feedback()
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

// MARK: - Haptic navigation back button

/// A drop-in replacement for the system navigation back button that plays a
/// light haptic before popping. Pair with `.navigationBarBackButtonHidden(true)`
/// and `.swipeBackEnabled()` (so the interactive swipe-to-pop gesture, which the
/// system disables once the default button is hidden, keeps working).
struct HapticBackButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            Haptics.tap()
            dismiss()
        } label: {
            // Matches the native back chevron weight, centered in a square 44pt
            // hit area so taps anywhere on the button register (not just on the
            // glyph). The square keeps the system's glass background a circle.
            Image(systemName: "chevron.backward")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel(Text("Back"))
    }
}

extension View {
    /// Re-enables the interactive swipe-from-edge pop gesture, which UIKit
    /// disables when a custom leading bar button hides the default back button.
    func swipeBackEnabled() -> some View {
        background(SwipeBackEnabler())
    }
}

/// Restores `interactivePopGestureRecognizer` after the default back button is
/// replaced. The custom delegate only allows the swipe when there's something to
/// pop, avoiding a stuck navigation bar at the stack root.
private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = Controller()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }

    final class Controller: UIViewController {
        weak var coordinator: Coordinator?

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            guard let nav = navigationController else { return }
            coordinator?.navigationController = nav
            nav.interactivePopGestureRecognizer?.isEnabled = true
            nav.interactivePopGestureRecognizer?.delegate = coordinator
        }
    }
}

extension AppAppearance {
    /// SwiftUI color scheme to force, or `nil` to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var localizedName: String {
        switch self {
        case .system: return String(localized: "System")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }
}

extension Color {
    /// Toned-down accent palette. The stock system hues read as neon against the
    /// app's glass surfaces, so green / teal / red are softened, and the flat gray
    /// theme is replaced with a refined slate blue-gray.
    static let grocerGreen = Color(red: 0.30, green: 0.64, blue: 0.42)
    static let grocerTeal = Color(red: 0.27, green: 0.56, blue: 0.60)
    static let grocerRed = Color(red: 0.80, green: 0.33, blue: 0.33)
    static let grocerSlate = Color(red: 0.40, green: 0.44, blue: 0.52)
}

/// Maps the model-level `ListColorTheme` (UI-free) to SwiftUI colors.
extension ListColorTheme {
    var color: Color {
        switch self {
        case .green: return .grocerGreen
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .grocerRed
        case .orange: return .orange
        case .yellow: return .yellow
        case .teal: return .grocerTeal
        case .mint: return .mint
        case .brown: return .brown
        case .gray: return .grocerSlate
        }
    }

    var displayName: String { localizedName }
}

extension Household {
    var tint: Color { colorTheme.color }
}

extension ItemPriority {
    var markerColor: Color {
        switch self {
        case .low: return .grocerGreen
        case .normal: return Color(.systemGray4)
        case .high: return .grocerRed
        }
    }
}

/// The app's standard navigation title: a small Liquid Glass capsule shown in
/// place of the system inline title. Drop into a navigation bar with
/// `.toolbar { ToolbarItem(placement: .principal) { GrocerGlassTitle("Settings") } }`.
struct GrocerGlassTitle: View {
    private let title: LocalizedStringKey
    @ScaledMetric(relativeTo: Font.TextStyle.headline) private var titleFontSize: CGFloat = 18.7

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: titleFontSize, weight: .semibold))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .grocerLiquidGlass(in: Capsule())
            // Purely a label — taps pass through to nothing.
            .allowsHitTesting(false)
    }
}

struct PriorityCircle: View {
    let priority: ItemPriority
    var size: CGFloat = 9
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        ZStack {
            Circle()
                .fill(priority.markerColor)
                .frame(width: size, height: size)
            if differentiateWithoutColor, let symbol = prioritySymbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.6, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .accessibilityLabel(String(localized: "\(priority.localizedName) priority"))
    }

    private var prioritySymbol: String? {
        switch priority {
        case .high: return "exclamationmark"
        case .low: return "arrow.down"
        case .normal: return nil
        }
    }
}

struct PriorityLabel: View {
    let priority: ItemPriority
    @ScaledMetric(relativeTo: Font.TextStyle.caption2) private var labelFontSize: CGFloat = 10
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var chipColor: Color? {
        switch priority {
        case .low: return Color(.systemGray)
        case .normal: return nil
        case .high: return .grocerRed
        }
    }

    var body: some View {
        if let color = chipColor {
            Text(priority.localizedName.uppercased())
                .font(.system(size: labelFontSize, weight: .semibold))
                .foregroundColor(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(color, lineWidth: colorSchemeContrast == .increased ? 1.5 : 1)
                )
                .accessibilityLabel(String(localized: "\(priority.localizedName) priority"))
        }
    }
}
