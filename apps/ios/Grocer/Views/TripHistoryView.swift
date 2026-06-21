import SwiftUI

/// A browsable list of finished shopping trips for the current group. Each row
/// pushes a `TripDetailView` showing the items captured during that trip.
struct TripHistoryView: View {
    @Environment(GroceryRepository.self) private var repo
    @State private var selectedTrip: ShoppingSession?

    private var trips: [ShoppingSession] { repo.currentCompletedTrips }
    private var tint: Color { repo.currentHousehold?.tint ?? .green }

    var body: some View {
        Group {
            if trips.isEmpty {
                ContentUnavailableView(
                    "No Trips Yet",
                    systemImage: "cart",
                    description: Text("Finished shopping trips for this list will show up here.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        ForEach(groupedTrips, id: \.label) { group in
                            tripSection(group)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle("Trip History")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled()
        .navigationDestination(item: $selectedTrip) { trip in
            TripDetailView(session: trip)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { HapticBackButton() }
            ToolbarItem(placement: .principal) {
                GrocerGlassTitle("Trip History")
            }
        }
    }

    // MARK: - Time grouping

    private struct TripGroup {
        let label: String
        let trips: [ShoppingSession]
    }

    private var groupedTrips: [TripGroup] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: .now)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
        let monthAgo = calendar.date(byAdding: .month, value: -1, to: startOfToday) ?? startOfToday

        var buckets: [(String, [ShoppingSession])] = [
            ("Today", []),
            ("Last 7 Days", []),
            ("This Month", []),
            ("Earlier", []),
        ]
        for trip in trips {
            if trip.startedAt >= startOfToday {
                buckets[0].1.append(trip)
            } else if trip.startedAt >= weekAgo {
                buckets[1].1.append(trip)
            } else if trip.startedAt >= monthAgo {
                buckets[2].1.append(trip)
            } else {
                buckets[3].1.append(trip)
            }
        }
        return buckets
            .filter { !$0.1.isEmpty }
            .map { TripGroup(label: $0.0, trips: $0.1) }
    }

    // MARK: - Section

    private func tripSection(_ group: TripGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(group.trips.enumerated()), id: \.element.id) { index, trip in
                    Button {
                        Haptics.selection()
                        selectedTrip = trip
                    } label: {
                        tripRow(trip)
                    }
                    .buttonStyle(.plain)

                    if index < group.trips.count - 1 {
                        // Inset past icon (16 padding + 40 icon + 14 gap = 70)
                        Divider().padding(.leading, 70)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func tripRow(_ trip: ShoppingSession) -> some View {
        let progress = repo.tripProgress(for: trip)
        let isCancelled = trip.status == .cancelled

        HStack(spacing: 14) {
            iconBadge(isCancelled: isCancelled)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(trip.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if isCancelled {
                        Text("Cancelled")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color(.systemGray5), in: Capsule())
                    }
                }

                if trip.storeName?.isEmpty == false || !trip.startedByDisplayName.isEmpty {
                    HStack(spacing: 5) {
                        if let store = trip.storeName, !store.isEmpty {
                            Image(systemName: "storefront")
                                .font(.caption2.weight(.medium))
                            Text(store)
                        }
                        if !trip.startedByDisplayName.isEmpty {
                            if trip.storeName?.isEmpty == false {
                                Text("·").foregroundStyle(.tertiary)
                            }
                            Text(trip.startedByDisplayName)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !isCancelled && progress.total > 0 {
                    outcomePills(progress)
                        .padding(.top, 3)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(for: trip, progress: progress))
    }

    private func iconBadge(isCancelled: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCancelled ? Color(.systemGray5) : tint.opacity(0.14))
                .frame(width: 40, height: 40)
            Image(systemName: isCancelled ? "cart.badge.minus" : "cart.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isCancelled ? Color(.systemGray2) : tint)
        }
    }

    // MARK: - Outcome pills

    private func outcomePills(_ progress: SessionProgress) -> some View {
        HStack(spacing: 5) {
            if progress.found > 0 {
                outcomePill(count: progress.found, color: .green, symbol: "checkmark")
            }
            if progress.replaced > 0 {
                outcomePill(count: progress.replaced, color: .blue, symbol: "arrow.triangle.2.circlepath")
            }
            if progress.outOfStock > 0 {
                outcomePill(count: progress.outOfStock, color: .red, symbol: "xmark")
            }
            if progress.skipped > 0 {
                outcomePill(count: progress.skipped, color: .orange, symbol: "arrow.uturn.forward")
            }
            Spacer(minLength: 0)
        }
    }

    private func outcomePill(count: Int, color: Color, symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.10), in: Capsule())
    }

    private func rowAccessibilityLabel(for trip: ShoppingSession, progress: SessionProgress) -> String {
        var parts: [String] = [trip.startedAt.formatted(date: .abbreviated, time: .shortened)]
        if let store = trip.storeName, !store.isEmpty { parts.append(store) }
        if !trip.startedByDisplayName.isEmpty { parts.append(trip.startedByDisplayName) }
        if trip.status == .cancelled {
            parts.append(String(localized: "Cancelled"))
        } else if progress.total > 0 {
            parts.append("\(progress.found + progress.replaced) of \(progress.total) found")
        }
        return parts.joined(separator: ", ")
    }
}

#if DEBUG
#Preview {
    let household = Household(
        id: "h1", name: "Home", ownerMemberId: "m1", storeName: "Trader Joe's",
        icon: "house.fill", colorTheme: .green, createdAt: .now, updatedAt: .now,
        recordZoneName: nil, recordOwnerName: nil
    )
    let sessions: [ShoppingSession] = [
        ShoppingSession(
            id: "s1", householdId: "h1", listId: "l1",
            startedByMemberId: "m1", startedByDisplayName: "Ray",
            storeName: "Trader Joe's", startedAt: .now.addingTimeInterval(-3600),
            endedAt: .now, updatedAt: .now, status: .completed
        ),
        ShoppingSession(
            id: "s2", householdId: "h1", listId: "l1",
            startedByMemberId: "m1", startedByDisplayName: "Ray",
            storeName: "Whole Foods", startedAt: .now.addingTimeInterval(-86400 * 3),
            endedAt: .now.addingTimeInterval(-86400 * 3 + 2400), updatedAt: .now, status: .completed
        ),
        ShoppingSession(
            id: "s3", householdId: "h1", listId: "l1",
            startedByMemberId: "m1", startedByDisplayName: "Ray",
            storeName: nil, startedAt: .now.addingTimeInterval(-86400 * 12),
            endedAt: .now.addingTimeInterval(-86400 * 12 + 1800), updatedAt: .now, status: .cancelled
        ),
    ]
    let tripItems = [
        ShoppingTripItem(id: "s1_i1", householdId: "h1", sessionId: "s1", itemId: "i1",
                         name: "Bananas", quantity: "1 bunch", category: .produce,
                         outcome: .found, replacementItemName: nil,
                         requestedByMemberId: "m1", requestedByDisplayName: "Ray", createdAt: .now),
        ShoppingTripItem(id: "s1_i2", householdId: "h1", sessionId: "s1", itemId: "i2",
                         name: "Oat Milk", quantity: nil, category: .dairy,
                         outcome: .outOfStock, replacementItemName: nil,
                         requestedByMemberId: "m1", requestedByDisplayName: "Ray", createdAt: .now),
        ShoppingTripItem(id: "s1_i3", householdId: "h1", sessionId: "s1", itemId: "i3",
                         name: "Sourdough", quantity: "1 loaf", category: .bakery,
                         outcome: .replaced, replacementItemName: "Multigrain",
                         requestedByMemberId: "m1", requestedByDisplayName: "Ray", createdAt: .now),
        ShoppingTripItem(id: "s2_i1", householdId: "h1", sessionId: "s2", itemId: "i4",
                         name: "Eggs", quantity: "1 dozen", category: .dairy,
                         outcome: .found, replacementItemName: nil,
                         requestedByMemberId: "m1", requestedByDisplayName: "Ray", createdAt: .now),
    ]
    return NavigationStack {
        TripHistoryView()
            .environment(GroceryRepository.makePreview(
                households: [household], sessions: sessions, tripItems: tripItems
            ))
    }
}
#endif
