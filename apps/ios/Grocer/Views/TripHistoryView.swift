import SwiftUI

/// A browsable list of finished shopping trips for the current group. Each row
/// pushes a `TripDetailView` showing the items captured during that trip.
struct TripHistoryView: View {
    @Environment(GroceryRepository.self) private var repo

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
                        NavigationLink {
                            TripDetailView(session: trip)
                        } label: {
                            tripRow(trip)
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            Haptics.selection()
                        })
                    }
                }
            }
        }
        .navigationTitle("Trip History")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .swipeBackEnabled()
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
        VStack(alignment: .leading, spacing: 4) {
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

            Text("\(progress.found + progress.replaced) of \(progress.total) found")
                .font(.caption)
                .foregroundStyle(tint)
        }
        .padding(.vertical, 2)
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
