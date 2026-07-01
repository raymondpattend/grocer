import SwiftUI

// Reusable shimmer skeleton primitives. Kept in the design system (not Services)
// so the loading placeholders can be shared by any view.

/// A rounded-rect skeleton block with a sweeping shimmer gradient.
struct ShimmerRect: View {
    var cornerRadius: CGFloat = 8
    @State private var phase: CGFloat = -1.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(.systemGray5))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(reduceMotion ? 0 : 0.4), .clear],
                            startPoint: UnitPoint(x: phase, y: 0.5),
                            endPoint: UnitPoint(x: phase + 1, y: 0.5)
                        )
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
    }
}

/// A circular skeleton block with a sweeping shimmer.
struct ShimmerCircle: View {
    @State private var phase: CGFloat = -1.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Color(.systemGray5))
            .overlay {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(reduceMotion ? 0 : 0.4), .clear],
                            startPoint: UnitPoint(x: phase, y: 0.5),
                            endPoint: UnitPoint(x: phase + 1, y: 0.5)
                        )
                    )
            }
            .clipShape(Circle())
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
    }
}
