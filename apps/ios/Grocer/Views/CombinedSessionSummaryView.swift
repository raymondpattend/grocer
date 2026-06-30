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
                    itemCard(
                        title: String(localized: "Found"),
                        systemImage: "checkmark.circle.fill",
                        iconColor: .grocerGreen,
                        items: foundItems
                    )
                }

                if !notFoundItems.isEmpty {
                    itemCard(
                        title: String(localized: "Not Found"),
                        systemImage: "xmark.circle.fill",
                        iconColor: .secondary,
                        items: notFoundItems
                    )
                }

                if !foundItems.isEmpty || hasOutOfStock {
                    cleanupCard
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
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 38))
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
                statPill("\(foundItems.count)", label: String(localized: "found"), color: .grocerGreen)
                if !notFoundItems.isEmpty {
                    statPill("\(notFoundItems.count)", label: String(localized: "not found"), color: .grocerSlate)
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

    private func statPill(_ value: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.1), in: Capsule())
    }

    // MARK: - Retry card (partial finish)

    private var retryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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

    // MARK: - Item Cards

    private func itemCard(title: String, systemImage: String, iconColor: Color, items: [GroceryItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).foregroundStyle(iconColor)
                Text(title)
                Text("·")
                Text("\(items.count)")
                Spacer()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    itemRow(item)
                    if index < items.count - 1 {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 1)
            }
        }
    }

    private func itemRow(_ item: GroceryItem) -> some View {
        HStack(spacing: 12) {
            ProductImageView(itemName: item.name, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let house = repo.households.first(where: { $0.id == item.householdId }) {
                        Label(house.name, systemImage: house.icon)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(house.tint)
                    }
                    if let qty = item.quantity, !qty.isEmpty {
                        Text(Quantity.displayString(qty))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            statusBadge(item)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusBadge(_ item: GroceryItem) -> some View {
        let (label, color): (String, Color) = {
            switch item.status {
            case .found: return (String(localized: "Found"), .grocerGreen)
            case .replaced:
                let name = item.replacementItemName ?? String(localized: "alternative")
                return (String(localized: "Replaced · \(name)"), .blue)
            case .outOfStock: return (String(localized: "Out of stock"), .grocerRed)
            case .skipped: return (String(localized: "Skipped"), .orange)
            default: return (String(localized: "Not Found"), .secondary)
            }
        }()

        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .lineLimit(1)
    }

    // MARK: - Cleanup Card

    private var cleanupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                Text("Cleanup")
                Spacer()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)

            VStack(spacing: 0) {
                if !foundItems.isEmpty {
                    Toggle("Remove found items from the lists", isOn: $clearFound)
                        .font(.subheadline)
                        .tint(tint)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .onChange(of: clearFound) { _, _ in Haptics.selection() }
                    if hasOutOfStock {
                        Divider().padding(.leading, 14)
                    }
                }
                if hasOutOfStock {
                    Toggle("Keep out-of-stock items for next trip", isOn: $keepOutOfStock)
                        .font(.subheadline)
                        .tint(tint)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .onChange(of: keepOutOfStock) { _, _ in Haptics.selection() }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 1)
            }

            Text("Skipped and remaining items always stay on your lists.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
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
            await repo.completeCombinedTripCleanup(
                sessionIds: sessionIds,
                clearCompleted: clearFound,
                keepOutOfStock: keepOutOfStock
            )
        }
        isFinishing = false
        if failed.isEmpty {
            onDone()
        } else {
            Haptics.warning()
        }
    }
}
