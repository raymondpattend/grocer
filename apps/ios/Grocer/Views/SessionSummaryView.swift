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
        .toolbar {
            ToolbarItem(placement: .principal) {
                GrocerGlassTitle("Trip Summary")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom) {
            Button {
                Task { await finishTrip() }
            } label: {
                HStack(spacing: 8) {
                    if isFinishing { ProgressView() }
                    Text(isFinishing ? "Finishing..." : "Done")
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
                if let store = session.storeName {
                    Text(store)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
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
                if let qty = item.quantity, !qty.isEmpty {
                    Text(Quantity.displayString(qty))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Toggle("Remove found items from the list", isOn: $clearFound)
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

            Text("Skipped and remaining items always stay on your list.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
        }
    }

    // MARK: - Finish

    private func finishTrip() async {
        guard !finished, !isFinishing else { return }
        Haptics.success()
        finished = true
        isFinishing = true
        PostHogSDK.shared.capture("shopping_trip_finished", properties: [
            "items_found": progress.found,
            "items_replaced": progress.replaced,
            "items_out_of_stock": progress.outOfStock,
            "items_skipped": progress.skipped,
            "total_items": progress.total,
            "store_name": session.storeName ?? "unknown",
        ])
        await repo.finishShopping(session, clearCompleted: clearFound, keepOutOfStock: keepOutOfStock)
        isFinishing = false
        onDone()
    }
}
