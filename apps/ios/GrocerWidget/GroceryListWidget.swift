import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Palette

/// Colors for the home-screen widget. The background mirrors the app-icon green;
/// text/markers use a dark "ink" that matches the icon's near-black cart so it
/// reads well on the green.
private enum WidgetPalette {
    /// The app-icon background green (sampled from AppIcon.png: rgb 104,206,103).
    static let green = Color(red: 104 / 255, green: 206 / 255, blue: 103 / 255)
    /// Subtle lighter/darker shades for the gentle top→bottom gradient.
    static let greenTop = Color(red: 120 / 255, green: 214 / 255, blue: 117 / 255)
    static let greenBottom = Color(red: 82 / 255, green: 186 / 255, blue: 90 / 255)
    /// Dark green-black used for text and bullets — echoes the icon's cart.
    static let ink = Color(red: 0.09, green: 0.18, blue: 0.11)

    static var background: LinearGradient {
        LinearGradient(colors: [greenTop, greenBottom], startPoint: .top, endPoint: .bottom)
    }
}

/// How many items each family shows before the fade hides the rest.
private let smallItemLimit = 6
private let mediumItemLimit = 12

// MARK: - Timeline

struct GroceryListEntry: TimelineEntry {
    let date: Date
    let list: WidgetListSummary?
}

struct GroceryListProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GroceryListEntry {
        GroceryListEntry(date: Date(), list: .placeholder)
    }

    func snapshot(for configuration: SelectListIntent, in context: Context) async -> GroceryListEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SelectListIntent, in context: Context) async -> Timeline<GroceryListEntry> {
        // The app nudges WidgetCenter on every change; this hourly reload is just a
        // fallback so the widget still refreshes if the app hasn't run in a while.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        return Timeline(entries: [entry(for: configuration)], policy: .after(next))
    }

    private func entry(for configuration: SelectListIntent) -> GroceryListEntry {
        let lists = WidgetSnapshotStore.load()?.lists ?? []
        // Fall back to the first list if the chosen one is gone or none is set.
        let selected = lists.first { $0.id == configuration.list?.id } ?? lists.first
        return GroceryListEntry(date: Date(), list: selected)
    }
}

extension WidgetListSummary {
    static var placeholder: WidgetListSummary {
        WidgetListSummary(
            id: "preview", name: "Groceries", icon: "cart.fill",
            colorThemeRaw: "green", storeName: nil, pendingCount: 11,
            itemNames: ["Milk", "Eggs", "Bananas", "Sourdough", "Coffee", "Tomatoes",
                        "Spinach", "Chicken", "Olive Oil", "Yogurt", "Avocados"]
        )
    }
}

// MARK: - Widget

struct GroceryListWidget: Widget {
    let kind = "GroceryListWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectListIntent.self, provider: GroceryListProvider()) { entry in
            GroceryListWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetPalette.background }
        }
        .configurationDisplayName("Grocery List")
        .description("See a list's items at a glance, and jump in to add more.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - View

struct GroceryListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GroceryListEntry

    var body: some View {
        Group {
            if let list = entry.list {
                content(for: list)
                    // Tapping the tile opens the list. On medium the Add button is
                    // its own Link and overrides this within its region.
                    .widgetURL(GroupDeepLink.url(householdId: list.id))
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder
    private func content(for list: WidgetListSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(list)
            ZStack(alignment: family == .systemSmall ? .bottom : .bottomLeading) {
                items(list)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .mask(fadeMask)
                addButton(list)
            }
        }
    }

    // MARK: Header

    private func header(_ list: WidgetListSummary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(list.name)
                .font(.headline.weight(.bold))
                .foregroundStyle(WidgetPalette.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            logo
        }
    }

    /// The app-icon logo, shown small in the top-right corner.
    private var logo: some View {
        let side: CGFloat = family == .systemSmall ? 24 : 28
        return Group {
            if let image = UIImage(named: "WidgetAppIcon") {
                Image(uiImage: image).resizable()
            } else {
                // Fallback if the asset is missing: a cart on the icon green.
                Image(systemName: "cart.fill")
                    .resizable().scaledToFit().padding(side * 0.24)
                    .foregroundStyle(WidgetPalette.ink)
                    .background(WidgetPalette.green)
            }
        }
        .scaledToFit()
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.27, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
        .accessibilityHidden(true)
    }

    // MARK: Items

    @ViewBuilder
    private func items(_ list: WidgetListSummary) -> some View {
        if list.itemNames.isEmpty {
            Text("Nothing on the list")
                .font(.subheadline)
                .foregroundStyle(WidgetPalette.ink.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if family == .systemSmall {
            itemColumn(Array(list.itemNames.prefix(smallItemLimit)))
        } else {
            let capped = Array(list.itemNames.prefix(mediumItemLimit))
            let split = Int(ceil(Double(capped.count) / 2))
            HStack(alignment: .top, spacing: 16) {
                itemColumn(Array(capped[0..<split]))
                itemColumn(Array(capped[split...]))
            }
        }
    }

    private func itemColumn(_ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                HStack(spacing: 7) {
                    Circle()
                        .fill(WidgetPalette.ink.opacity(0.5))
                        .frame(width: 5, height: 5)
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(WidgetPalette.ink)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Items fade toward the bottom so the list looks like it continues behind the
    /// Add button.
    private var fadeMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.6),
                .init(color: .black.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: Add button

    /// On small widgets only `.widgetURL` is tappable, so the button is purely
    /// visual there; on medium it's its own Link into the list.
    @ViewBuilder
    private func addButton(_ list: WidgetListSummary) -> some View {
        if family != .systemSmall, let url = GroupDeepLink.url(householdId: list.id) {
            Link(destination: url) { addButtonLabel }
        } else {
            addButtonLabel
        }
    }

    private var addButtonLabel: some View {
        let fullWidth = family == .systemSmall
        return HStack(spacing: 5) {
            Image(systemName: "plus")
                .font(.subheadline.weight(.bold))
            Text("Add")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.vertical, fullWidth ? 9 : 7)
        .padding(.horizontal, fullWidth ? 0 : 16)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .background(Color.black, in: Capsule())
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            logo
            Text("Open Grocer to set up your list")
                .font(.caption)
                .foregroundStyle(WidgetPalette.ink.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Small", as: .systemSmall) {
    GroceryListWidget()
} timeline: {
    GroceryListEntry(date: .now, list: .placeholder)
    GroceryListEntry(date: .now, list: WidgetListSummary(
        id: "empty", name: "Weeknight", icon: "cart.fill",
        colorThemeRaw: "green", storeName: nil, pendingCount: 0, itemNames: []))
}

#Preview("Medium", as: .systemMedium) {
    GroceryListWidget()
} timeline: {
    GroceryListEntry(date: .now, list: .placeholder)
}
#endif
