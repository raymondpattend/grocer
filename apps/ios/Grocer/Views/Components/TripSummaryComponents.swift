import SwiftUI

/// Shared building blocks for the single- and combined-trip summary screens
/// (`SessionSummaryView` / `CombinedSessionSummaryView`), which previously
/// duplicated these views byte-for-byte.

/// A compact "value label" stat used in the shopping progress header
/// (e.g. "8 found").
struct TripStat: View {
    let value: String
    let label: String

    init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(value).bold()
            Text(label).foregroundStyle(.secondary)
        }
    }
}

/// A small "12 found" style pill used in the summary hero.
struct TripStatPill: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
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
}

/// The found / replaced / out-of-stock / skipped status badge on a summary row.
struct TripStatusBadge: View {
    let item: GroceryItem

    var body: some View {
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
}

/// A found / not-found card listing items, each with an image, name, optional
/// quantity, and a status badge. Combined trips also pass a per-row group badge
/// (which list the item came from); single trips omit it.
struct TripSummaryItemCard: View {
    struct GroupBadge {
        let name: String
        let icon: String
        let tint: Color
    }

    let title: String
    let systemImage: String
    let iconColor: Color
    let items: [GroceryItem]
    var groupBadge: (GroceryItem) -> GroupBadge? = { _ in nil }

    var body: some View {
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
                    row(item)
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

    private func row(_ item: GroceryItem) -> some View {
        HStack(spacing: 12) {
            ProductImageView(itemName: item.name, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let badge = groupBadge(item) {
                        Label(badge.name, systemImage: badge.icon)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .foregroundStyle(badge.tint)
                    }
                    if let qty = item.quantity, !qty.isEmpty {
                        Text(Quantity.displayString(qty))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            TripStatusBadge(item: item)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The post-trip cleanup toggles: remove found items, keep out-of-stock items.
/// `plural` switches the copy for a combined (multi-list) trip.
struct TripCleanupCard: View {
    @Binding var clearFound: Bool
    @Binding var keepOutOfStock: Bool
    let showClearFound: Bool
    let hasOutOfStock: Bool
    let tint: Color
    let plural: Bool

    private var clearFoundTitle: LocalizedStringKey {
        plural ? "Remove found items from the lists" : "Remove found items from the list"
    }

    private var footer: LocalizedStringKey {
        plural
            ? "Skipped and remaining items always stay on your lists."
            : "Skipped and remaining items always stay on your list."
    }

    var body: some View {
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
                if showClearFound {
                    Toggle(clearFoundTitle, isOn: $clearFound)
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

            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
        }
    }
}
