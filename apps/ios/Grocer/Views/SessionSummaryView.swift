import PostHog
import SwiftUI

/// Shown after the shopper taps Finish Shopping. Splits the trip into what was
/// found and what wasn't, then lets the user decide how to clean up the list.
struct SessionSummaryView: View {
    @Environment(GroceryRepository.self) private var repo

    let session: ShoppingSession
    /// The session-ending work kicked off when the shopper tapped Finish
    /// Shopping on the previous screen. Done waits on this (almost always
    /// already complete) rather than starting it itself.
    let endingTask: Task<Void, Never>?
    let onDone: () -> Void

    @State private var clearFound = true
    @State private var keepOutOfStock = true
    @State private var isFinishing = false

    private var progress: SessionProgress { repo.progress(for: session) }

    private var tint: Color {
        repo.households.first { $0.id == session.householdId }?.tint ?? .green
    }

    private var foundItems: [GroceryItem] {
        repo.handledItems(session: session)
            .filter { $0.status == .found || $0.status == .replaced }
    }

    private var notFoundItems: [GroceryItem] {
        let misses = repo.handledItems(session: session)
            .filter { $0.status == .outOfStock || $0.status == .skipped }
        let stillNeeded = repo.pendingShoppingGroups(session: session).flatMap { $0.items }
        return misses + stillNeeded
    }

    private var hasOutOfStock: Bool {
        repo.handledItems(session: session).contains { $0.status == .outOfStock }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroSection

                if !foundItems.isEmpty {
                    TripSummaryItemCard(
                        title: String(localized: "Found"),
                        systemImage: "checkmark.circle.fill",
                        iconColor: .grocerGreen,
                        items: foundItems
                    )
                }

                if !notFoundItems.isEmpty {
                    TripSummaryItemCard(
                        title: String(localized: "Not Found"),
                        systemImage: "xmark.circle.fill",
                        iconColor: .secondary,
                        items: notFoundItems
                    )
                }

                if !foundItems.isEmpty || hasOutOfStock {
                    TripCleanupCard(
                        clearFound: $clearFound,
                        keepOutOfStock: $keepOutOfStock,
                        showClearFound: !foundItems.isEmpty,
                        hasOutOfStock: hasOutOfStock,
                        tint: tint,
                        plural: false
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 100)
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                Task { await finishTrip() }
            } label: {
                HStack(spacing: 8) {
                    if isFinishing { ProgressView() }
                    Text(doneButtonTitle)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .grocerGlassButton(prominent: true)
            .tint(tint)
            .controlSize(.large)
            .padding()
            .disabled(isFinishing)
        }
        .interactiveDismissDisabled(isFinishing)
        .postHogScreenView("Session Summary")
    }

    private var doneButtonTitle: String {
        isFinishing ? String(localized: "Finishing...") : String(localized: "Done")
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 80, height: 80)
                FAImage("checkmark.seal.fill", size: 38)
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Shopping Complete")
                    .font(.title2.bold())
                if let store = session.storeName {
                    Text(store)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                TripStatPill(value: "\(foundItems.count)", label: String(localized: "found"), color: .grocerGreen)
                if !notFoundItems.isEmpty {
                    TripStatPill(value: "\(notFoundItems.count)", label: String(localized: "not found"), color: .grocerSlate)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 1)
        }
    }

    // MARK: - Finish

    private func finishTrip() async {
        guard !isFinishing else { return }
        Haptics.success()
        isFinishing = true
        PostHogSDK.shared.capture("shopping_trip_finished", properties: [
            "items_found": progress.found,
            "items_replaced": progress.replaced,
            "items_out_of_stock": progress.outOfStock,
            "items_skipped": progress.skipped,
            "total_items": progress.total,
            "store_name": session.storeName ?? "unknown",
        ])
        // Wait out the ending work started on the previous screen, then apply and
        // *durably persist* the cleanup choices before dismissing. Awaiting here
        // (with Done disabled and dismissal blocked) is what keeps a suspend/kill
        // right after the tap from silently dropping the shopper's choices.
        await endingTask?.value
        await repo.completeTripCleanup(session, clearCompleted: clearFound, keepOutOfStock: keepOutOfStock)
        onDone()
    }
}
