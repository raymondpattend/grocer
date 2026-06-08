import SwiftUI
import UIKit

/// Top-level navigation. Defaults to the planning list; the shopper can drill
/// into the focused Shopping Session screen when one is active.
struct RootView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            GroceryListView()
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

// MARK: - Shared small components

/// Small sync status pill shown when offline / syncing.
struct SyncStatusBar: View {
    let state: GroceryRepository.SyncState

    var body: some View {
        switch state {
        case .idle, .syncing:
            EmptyView()
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
