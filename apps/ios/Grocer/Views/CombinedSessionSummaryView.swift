import PostHog
import SwiftUI

/// Summary for a combined (multi-list) trip. Mirrors `SessionSummaryView` but
/// unions found / not-found across every session and finishes them together.
/// Each session writes to a different CloudKit zone, so a finish can partially
/// fail — the view surfaces which lists didn't finish and offers a targeted retry.
struct CombinedSessionSummaryView: View {
    @Environment(GroceryRepository.self) private var repo

    let sessionIds: [String]
    /// The session-ending work kicked off when the shopper tapped Finish
    /// Shopping on the previous screen. Done waits on this (almost always
    /// already complete) rather than starting it itself; a retry only
    /// re-attempts ending for whichever lists didn't land.
    let endingTask: Task<[String], Never>?
    let onDone: () -> Void

    @State private var clearFound = true
    @State private var keepOutOfStock = true
    @State private var isFinishing = false
    @State private var failedSessionIds: [String] = []

    private let tint: Color = .green

    private var progress: SessionProgress {
        repo.combinedProgress(sessionIds: sessionIds)
    }

    private var foundItems: [GroceryItem] {
        repo.combinedHandledItems(sessionIds: sessionIds)
            .filter { $0.status == .found || $0.status == .replaced }
    }

    private var notFoundItems: [GroceryItem] {
        let misses = repo.combinedHandledItems(sessionIds: sessionIds)
            .filter { $0.status == .outOfStock || $0.status == .skipped }
        let stillNeeded = repo.combinedPendingGroups(sessionIds: sessionIds).flatMap { $0.items }
        return misses + stillNeeded
    }

    private var hasOutOfStock: Bool {
        repo.combinedHandledItems(sessionIds: sessionIds).contains { $0.status == .outOfStock }
    }

    private var listCount: Int { sessionIds.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                heroSection

                if !failedSessionIds.isEmpty {
                    retryCard
                }

                if !foundItems.isEmpty {
                    TripSummaryItemCard(
                        title: String(localized: "Found"),
                        systemImage: "checkmark.circle.fill",
                        iconColor: .grocerGreen,
                        items: foundItems,
                        groupBadge: groupBadge
                    )
                }

                if !notFoundItems.isEmpty {
                    TripSummaryItemCard(
                        title: String(localized: "Not Found"),
                        systemImage: "xmark.circle.fill",
                        iconColor: .secondary,
                        items: notFoundItems,
                        groupBadge: groupBadge
                    )
                }

                if !foundItems.isEmpty || hasOutOfStock {
                    TripCleanupCard(
                        clearFound: $clearFound,
                        keepOutOfStock: $keepOutOfStock,
                        showClearFound: !foundItems.isEmpty,
                        hasOutOfStock: hasOutOfStock,
                        tint: tint,
                        plural: true
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
            .padding(.horizontal)
            .padding(.top, 8)
            .disabled(isFinishing)
        }
        .interactiveDismissDisabled(isFinishing)
        .postHogScreenView("Combined Session Summary")
    }

    private var doneButtonTitle: String {
        if isFinishing { return String(localized: "Finishing...") }
        if !failedSessionIds.isEmpty { return String(localized: "Retry") }
        return String(localized: "Done")
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
                Text("^[\(listCount) list](inflect: true) · \(storeLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

    private var storeLabel: String {
        let stores = Set(sessionIds.compactMap { id -> String? in
            let trimmed = repo.session(id: id)?.storeName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        })
        if stores.count == 1, let only = stores.first { return only }
        if stores.isEmpty { return String(localized: "your trip") }
        return String(localized: "multiple stores")
    }

    /// The per-row "which list" badge for the shared summary item card.
    private func groupBadge(for item: GroceryItem) -> TripSummaryItemCard.GroupBadge? {
        guard let house = repo.households.first(where: { $0.id == item.householdId }) else { return nil }
        return .init(name: house.name, icon: house.icon, tint: house.tint)
    }

    // MARK: - Retry card (partial finish)

    private var retryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                FAImage("exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't finish ^[\(failedSessionIds.count) list](inflect: true)")
                Spacer()
            }
            .font(.subheadline.weight(.semibold))

            ForEach(failedSessionIds, id: \.self) { id in
                if let name = repo.session(id: id).flatMap({ session in
                    repo.households.first { $0.id == session.householdId }?.name
                }) {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("These trips are still active. Tap Retry to finish them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        }
    }

    // MARK: - Finish

    private func finishTrip() async {
        guard !isFinishing else { return }
        Haptics.success()
        isFinishing = true
        // On a retry, only the lists that previously failed to end are re-attempted.
        let targets = failedSessionIds.isEmpty ? sessionIds : failedSessionIds
        PostHogSDK.shared.capture("combined_trip_finished", properties: [
            "list_count": targets.count,
            "items_found": progress.found,
            "items_replaced": progress.replaced,
            "items_out_of_stock": progress.outOfStock,
            "items_skipped": progress.skipped,
            "total_items": progress.total,
        ])
        let failed: [String]
        if failedSessionIds.isEmpty, let endingTask {
            failed = await endingTask.value
        } else {
            failed = await repo.finishCombinedShopping(sessionIds: targets)
        }
        failedSessionIds = failed
        if failed.isEmpty {
            // Ending landed; now apply and *durably persist* the cleanup choices
            // before dismissing. Keep Done disabled and dismissal blocked through
            // it so a suspend/kill right after the tap can't drop the choices.
            await repo.completeCombinedTripCleanup(
                sessionIds: sessionIds,
                clearCompleted: clearFound,
                keepOutOfStock: keepOutOfStock
            )
            isFinishing = false
            onDone()
        } else {
            isFinishing = false
            Haptics.warning()
        }
    }
}
