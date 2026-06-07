import SwiftUI

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
