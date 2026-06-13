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

/// Maps the model-level `ListColorTheme` (UI-free) to SwiftUI colors.
extension ListColorTheme {
    var color: Color {
        switch self {
        case .green: return .green
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .teal: return .teal
        case .mint: return .mint
        case .brown: return .brown
        case .gray: return .gray
        }
    }

    var displayName: String { rawValue.capitalized }
}

extension Household {
    var tint: Color { colorTheme.color }
}

extension ItemPriority {
    var markerColor: Color {
        switch self {
        case .low: return .green
        case .normal: return Color(.systemGray4)
        case .high: return .red
        }
    }
}

struct PriorityCircle: View {
    let priority: ItemPriority
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(priority.markerColor)
            .frame(width: size, height: size)
            .accessibilityLabel("\(priority.rawValue) priority")
    }
}

struct PriorityLabel: View {
    let priority: ItemPriority

    var body: some View {
        Label {
            Text(priority.rawValue)
        } icon: {
            PriorityCircle(priority: priority)
                .accessibilityHidden(true)
        }
    }
}
