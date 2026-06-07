import SwiftUI

/// Top-level navigation. Defaults to the planning list; the shopper can drill
/// into the focused Shopping Session screen when one is active.
struct RootView: View {
    @Environment(GroceryRepository.self) private var repo

    var body: some View {
        NavigationStack {
            GroceryListView()
        }
    }
}

// MARK: - Shared small components

/// Small sync status pill shown when offline / syncing.
struct SyncStatusBar: View {
    let state: GroceryRepository.SyncState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .syncing:
            label("Syncing…", systemImage: "arrow.triangle.2.circlepath", tint: .secondary)
        case .offline:
            label("Offline — changes will sync later", systemImage: "icloud.slash", tint: .orange)
        case .error(let message):
            label(message, systemImage: "exclamationmark.icloud", tint: .orange)
        }
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
struct GroceryListSkeleton: View {
    @State private var shimmer = false

    var body: some View {
        Section {
            skeletonRow(titleWidth: 100)
        }

        Section {
            ForEach(0..<3, id: \.self) { _ in
                skeletonItemRow()
            }
        } header: {
            skeletonPill(width: 80)
        }

        Section {
            ForEach(0..<2, id: \.self) { _ in
                skeletonItemRow()
            }
        } header: {
            skeletonPill(width: 60)
        }
    }

    private func skeletonItemRow() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: .random(in: 90...160), height: 14)
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
                .frame(width: .random(in: 100...180), height: 10)
        }
        .padding(.vertical, 4)
        .shimmering(active: shimmer)
        .onAppear { shimmer = true }
    }

    private func skeletonRow(titleWidth: CGFloat) -> some View {
        HStack {
            Circle()
                .fill(.quaternary)
                .frame(width: 22, height: 22)
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: titleWidth, height: 14)
        }
        .shimmering(active: shimmer)
        .onAppear { shimmer = true }
    }

    private func skeletonPill(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.quaternary)
            .frame(width: width, height: 12)
            .shimmering(active: shimmer)
            .onAppear { shimmer = true }
    }
}

private struct ShimmerModifier: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0.4 + 0.3 * sin(phase) : 1)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                       value: phase)
            .onAppear { if active { phase = .pi } }
            .onChange(of: active) { _, on in if on { phase = .pi } }
    }
}

private extension View {
    func shimmering(active: Bool) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}
