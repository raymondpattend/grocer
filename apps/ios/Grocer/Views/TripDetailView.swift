import SwiftUI

/// Detail of a single finished trip: when/where/who, outcome tallies, and the
/// captured `ShoppingTripItem` snapshots grouped by outcome.
struct TripDetailView: View {
    @Environment(GroceryRepository.self) private var repo

    let session: ShoppingSession

    private var items: [ShoppingTripItem] { repo.tripItems(for: session) }
    private var progress: SessionProgress { repo.tripProgress(for: session) }

    var body: some View {
        List {
            headerSection

            if items.isEmpty {
                Section {
                    Text("No items were recorded for this trip.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Summary") {
                    summaryRow(String(localized: "Found"), progress.found, systemImage: "checkmark.circle.fill", tint: .green)
                    summaryRow(String(localized: "Replaced"), progress.replaced, systemImage: "arrow.triangle.2.circlepath.circle.fill", tint: .blue)
                    summaryRow(String(localized: "Out of stock"), progress.outOfStock, systemImage: "xmark.circle.fill", tint: .red)
                    summaryRow(String(localized: "Skipped"), progress.skipped, systemImage: "arrow.uturn.forward.circle.fill", tint: .orange)
                    summaryRow(String(localized: "Not found"), progress.remaining, systemImage: "circle.dashed", tint: .secondary)
                }

                ForEach(Self.outcomeGroups) { group in
                    let groupItems = items.filter { $0.outcome == group.outcome }
                    if !groupItems.isEmpty {
                        Section(group.title) {
                            ForEach(groupItems) { item in
                                itemRow(item, group: group)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Trip")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { HapticBackButton() }
        }
    }

    private var headerSection: some View {
        Section {
            LabeledContent("When", value: session.startedAt.formatted(date: .abbreviated, time: .shortened))
            if let store = session.storeName, !store.isEmpty {
                LabeledContent("Store", value: store)
            }
            if !session.startedByDisplayName.isEmpty {
                LabeledContent("Shopper", value: session.startedByDisplayName)
            }
            if session.status == .cancelled {
                LabeledContent("Status", value: SessionStatus.cancelled.localizedName)
            }
        }
    }

    private func summaryRow(_ title: String, _ count: Int, systemImage: String, tint: Color) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)
            Spacer()
            Text("\(count)").bold().monospacedDigit()
        }
    }

    private func itemRow(_ item: ShoppingTripItem, group: OutcomeGroup) -> some View {
        HStack(spacing: 12) {
            Image(systemName: group.systemImage)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, group.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                if let detail = detailText(for: item) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func detailText(for item: ShoppingTripItem) -> String? {
        var parts: [String] = []
        if let quantity = item.quantity, !quantity.isEmpty { parts.append(quantity) }
        if item.outcome == .replaced, let replacement = item.replacementItemName, !replacement.isEmpty {
            parts.append("→ \(replacement)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Outcome grouping

    struct OutcomeGroup: Identifiable {
        let outcome: ItemStatus
        let title: String
        let systemImage: String
        let tint: Color
        var id: String { outcome.rawValue }
    }

    /// Display order of outcome buckets in the detail list.
    static let outcomeGroups: [OutcomeGroup] = [
        OutcomeGroup(outcome: .found, title: String(localized: "Found"), systemImage: "checkmark.circle.fill", tint: .green),
        OutcomeGroup(outcome: .replaced, title: String(localized: "Replaced"), systemImage: "arrow.triangle.2.circlepath.circle.fill", tint: .blue),
        OutcomeGroup(outcome: .outOfStock, title: String(localized: "Out of Stock"), systemImage: "xmark.circle.fill", tint: .red),
        OutcomeGroup(outcome: .skipped, title: String(localized: "Skipped"), systemImage: "arrow.uturn.forward.circle.fill", tint: .orange),
        OutcomeGroup(outcome: .needed, title: String(localized: "Not Found"), systemImage: "circle.dashed", tint: .gray),
        OutcomeGroup(outcome: .removed, title: String(localized: "Removed"), systemImage: "trash.circle.fill", tint: .gray),
    ]
}

#if DEBUG
#Preview {
    let household = Household(
        id: "h1", name: "Home", ownerMemberId: "m1", storeName: "Trader Joe's",
        icon: "house.fill", colorTheme: .green, createdAt: .now, updatedAt: .now,
        recordZoneName: nil, recordOwnerName: nil
    )
    let session = ShoppingSession(
        id: "s1", householdId: "h1", listId: "l1",
        startedByMemberId: "m1", startedByDisplayName: "Ray",
        storeName: "Trader Joe's", startedAt: .now.addingTimeInterval(-3600),
        endedAt: .now, updatedAt: .now, status: .completed
    )
    let tripItems = [
        ShoppingTripItem(id: "s1_i1", householdId: "h1", sessionId: "s1", itemId: "i1",
                         name: "Bananas", quantity: "1 bunch", category: .produce,
                         outcome: .found, replacementItemName: nil,
                         requestedByMemberId: "m1", requestedByDisplayName: "Ray", createdAt: .now),
        ShoppingTripItem(id: "s1_i2", householdId: "h1", sessionId: "s1", itemId: "i2",
                         name: "Oat Milk", quantity: nil, category: .dairy,
                         outcome: .replaced, replacementItemName: "Almond Milk",
                         requestedByMemberId: "m1", requestedByDisplayName: "Ray", createdAt: .now),
        ShoppingTripItem(id: "s1_i3", householdId: "h1", sessionId: "s1", itemId: "i3",
                         name: "Eggs", quantity: "1 dozen", category: .dairy,
                         outcome: .needed, replacementItemName: nil,
                         requestedByMemberId: "m1", requestedByDisplayName: "Ray", createdAt: .now),
    ]
    return NavigationStack {
        TripDetailView(session: session)
            .environment(GroceryRepository.makePreview(
                households: [household], sessions: [session], tripItems: tripItems
            ))
    }
}
#endif
