import PostHog
import SwiftUI

/// Shown after the shopper taps Finish Shopping. Splits the trip into what was
/// found and what wasn't, then lets the user decide how to clean up the list.
struct SessionSummaryView: View {
    @Environment(GroceryRepository.self) private var repo

    let session: ShoppingSession
    let onDone: () -> Void

    @State private var clearFound = true
    @State private var keepOutOfStock = true
    @State private var finished = false

    private var progress: SessionProgress { repo.progress(for: session) }

    private var tint: Color {
        repo.households.first { $0.id == session.householdId }?.tint ?? .green
    }

    /// Items the shopper got — found outright or via a replacement.
    private var foundItems: [GroceryItem] {
        repo.handledItems(session: session)
            .filter { $0.status == .found || $0.status == .replaced }
    }

    /// Everything that didn't make it into the cart: out-of-stock, skipped, and
    /// whatever was still on the list when the trip ended.
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
        List {
            headerSection

            if !foundItems.isEmpty {
                Section {
                    ForEach(foundItems) { itemRow($0) }
                } header: {
                    sectionHeader(String(localized: "Found"), count: foundItems.count,
                                  systemImage: "checkmark.circle.fill", tint: .green)
                }
            }

            if !notFoundItems.isEmpty {
                Section {
                    ForEach(notFoundItems) { itemRow($0) }
                } header: {
                    sectionHeader(String(localized: "Not found"), count: notFoundItems.count,
                                  systemImage: "xmark.circle.fill", tint: .secondary)
                }
            }

            optionsSection
        }
        .navigationTitle("Trip Summary")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom) {
            Button {
                finishTrip()
            } label: {
                Text("Done")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .grocerGlassButton(prominent: true)
            .tint(tint)
            .controlSize(.large)
            .padding()
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(tint)
                Text("Shopping Complete")
                    .font(.title2.bold())
                if let store = session.storeName {
                    Text(store).foregroundStyle(.secondary)
                }
                Text("\(foundItems.count) found · \(notFoundItems.count) not found")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        Section {
            if !foundItems.isEmpty {
                Toggle("Remove found items from the list", isOn: $clearFound)
                    .onChange(of: clearFound) { _, _ in Haptics.selection() }
            }
            if hasOutOfStock {
                Toggle("Keep out-of-stock items for next trip", isOn: $keepOutOfStock)
                    .onChange(of: keepOutOfStock) { _, _ in Haptics.selection() }
            }
        } header: {
            Text("Cleanup")
        } footer: {
            Text("Skipped and remaining items always stay on your list.")
        }
    }

    // MARK: - Rows

    private func sectionHeader(_ title: String, count: Int, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(title)
            Text("•")
            Text("\(count)")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(nil)
    }

    private func itemRow(_ item: GroceryItem) -> some View {
        HStack(spacing: 12) {
            ProductImageView(itemName: item.name, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let qty = item.quantity, !qty.isEmpty {
                    Text(Quantity.displayString(qty))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            statusBadge(item)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusBadge(_ item: GroceryItem) -> some View {
        let (label, color): (String, Color) = {
            switch item.status {
            case .found: return (String(localized: "Found"), .green)
            case .replaced:
                let name = item.replacementItemName ?? String(localized: "alternative")
                return (String(localized: "Replaced · \(name)"), .blue)
            case .outOfStock: return (String(localized: "Out of stock"), .red)
            case .skipped: return (String(localized: "Skipped"), .orange)
            default: return (String(localized: "Left on list"), .secondary)
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

    // MARK: - Finish

    private func finishTrip() {
        Haptics.success()
        if !finished {
            finished = true
            PostHogSDK.shared.capture("shopping_trip_finished", properties: [
                "items_found": progress.found,
                "items_replaced": progress.replaced,
                "items_out_of_stock": progress.outOfStock,
                "items_skipped": progress.skipped,
                "total_items": progress.total,
                "store_name": session.storeName ?? "unknown",
            ])
            // Finish runs without blocking; the APNs end push is fire-and-forget.
            Task { await repo.finishShopping(session, clearCompleted: clearFound, keepOutOfStock: keepOutOfStock) }
        }
        onDone()
    }
}
