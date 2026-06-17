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
                List {
                    ForEach(trips) { trip in
                        Button {
                            Haptics.selection()
                            selectedTrip = trip
                        } label: {
                            tripRow(trip)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
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

    @ViewBuilder
    private func tripRow(_ trip: ShoppingSession) -> some View {
        let progress = repo.tripProgress(for: trip)
        let itemPreview = repo.tripItems(for: trip).prefix(3).map(\.name).joined(separator: ", ")
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(trip.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.headline)
                    Spacer()
                    if trip.status == .cancelled {
                        Text("Cancelled")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    if let store = trip.storeName, !store.isEmpty {
                        Label(store, systemImage: "storefront")
                            .labelStyle(.titleAndIcon)
                    }
                    if !trip.startedByDisplayName.isEmpty {
                        if trip.storeName?.isEmpty == false { Text("·") }
                        Text(trip.startedByDisplayName)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if !itemPreview.isEmpty {
                    Text(itemPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("\(progress.found + progress.replaced) of \(progress.total) found")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
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
                         outcome: .outOfStock, replacementItemName: nil,
                         requestedByMemberId: "m1", requestedByDisplayName: "Ray", createdAt: .now),
    ]
    return NavigationStack {
        TripHistoryView()
            .environment(GroceryRepository.makePreview(
                households: [household], sessions: [session], tripItems: tripItems
            ))
    }
}
#endif
