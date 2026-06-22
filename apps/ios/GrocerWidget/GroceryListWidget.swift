import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Palette

/// Colors for the home-screen widget. The background is a slightly-darkened take
/// on the app-icon green; text uses a near-black "ink" that echoes the icon's
/// cart and stays legible across the gradient.
private enum WidgetPalette {
    /// Gentle top→bottom gradient, a touch darker than the flat icon green.
    static let greenTop = Color(red: 96 / 255, green: 188 / 255, blue: 100 / 255)
    static let greenBottom = Color(red: 52 / 255, green: 144 / 255, blue: 70 / 255)
    /// Dark green-black used for text and the thumbnail fallback glyph.
    static let ink = Color(red: 0.06, green: 0.14, blue: 0.08)

    static var background: LinearGradient {
        LinearGradient(colors: [greenTop, greenBottom], startPoint: .top, endPoint: .bottom)
    }
}

/// How many items each family shows before the rest are clipped.
private let smallItemLimit = 5
private let mediumItemLimit = 7
/// Space the left column reserves at its bottom for the Add button, so the two
/// never overlap (and the right column can show one more item than the left).
private let addButtonReserve: CGFloat = 34

// MARK: - Timeline

struct GroceryListEntry: TimelineEntry {
    let date: Date
    let list: WidgetListSummary?
    /// item name → loaded product image (only items that resolved an image).
    let images: [String: UIImage]
}

struct GroceryListProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GroceryListEntry {
        GroceryListEntry(date: Date(), list: .placeholder, images: [:])
    }

    func snapshot(for configuration: SelectListIntent, in context: Context) async -> GroceryListEntry {
        await entry(for: configuration)
    }

    func timeline(for configuration: SelectListIntent, in context: Context) async -> Timeline<GroceryListEntry> {
        // The app nudges WidgetCenter on every change; this hourly reload is just a
        // fallback so the widget still refreshes if the app hasn't run in a while.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        return Timeline(entries: [await entry(for: configuration)], policy: .after(next))
    }

    private func entry(for configuration: SelectListIntent) async -> GroceryListEntry {
        let lists = WidgetSnapshotStore.load()?.lists ?? []
        // Fall back to the first list if the chosen one is gone or none is set.
        let selected = lists.first { $0.id == configuration.list?.id } ?? lists.first
        guard let selected else {
            return GroceryListEntry(date: Date(), list: nil, images: [:])
        }

        let names = Array(selected.itemNames.prefix(mediumItemLimit))
        var images: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for name in names {
                group.addTask { (name, await WidgetImageStore.loadOrFetch(for: name)) }
            }
            for await (name, image) in group {
                if let image { images[name] = image }
            }
        }
        return GroceryListEntry(date: Date(), list: selected, images: images)
    }
}

extension WidgetListSummary {
    static var placeholder: WidgetListSummary {
        WidgetListSummary(
            id: "preview", name: "Groceries", icon: "cart.fill",
            colorThemeRaw: "green", storeName: nil, pendingCount: 9,
            itemNames: ["Milk", "Eggs", "Bananas", "Sourdough", "Coffee",
                        "Tomatoes", "Spinach", "Avocados"]
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
        // We own the insets (see `.padding` in the view) so the green fills the
        // tile and the content keeps a consistent margin on every edge.
        .contentMarginsDisabled()
    }
}

// MARK: - View

struct GroceryListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GroceryListEntry

    private var isSmall: Bool { family == .systemSmall }

    var body: some View {
        Group {
            if let list = entry.list {
                content(for: list)
                    // On small, the whole tile is the only tap target, so it opens
                    // the Add modal (the Add button is the focal CTA). On medium the
                    // tile opens the list and the Add button is its own Link.
                    .widgetURL(isSmall ? GroupDeepLink.addURL(householdId: list.id)
                                       : GroupDeepLink.url(householdId: list.id))
            } else {
                emptyState
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 12))
    }

    @ViewBuilder
    private func content(for list: WidgetListSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(list)
            if isSmall {
                smallArea(list)
                addButton(list)
            } else {
                mediumArea(list)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Small: a single fading column. Overlaid on a flexible, zero-min `Color.clear`
    /// so the items can't push the header/button past the widget edges, and the
    /// column fills the area so the fade only shows up once items actually overflow.
    private func smallArea(_ list: WidgetListSummary) -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                Group {
                    if list.itemNames.isEmpty {
                        emptyItemsText
                    } else {
                        itemColumn(Array(list.itemNames.prefix(smallItemLimit)), thumb: 22)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .mask(fadeMask)
            }
            .clipped()
    }

    /// Medium: two columns. The Add button sits at the bottom-left, so the right
    /// column has room for one more item than the left. The button is overlaid
    /// outside the fade (always crisp), and the left column reserves space beneath
    /// it so the two never overlap. The fade only appears when a column overflows.
    private func mediumArea(_ list: WidgetListSummary) -> some View {
        let capped = Array(list.itemNames.prefix(mediumItemLimit))
        let leftCount = capped.count / 2
        let left = Array(capped.prefix(leftCount))
        let right = Array(capped.dropFirst(leftCount))
        return Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                Group {
                    if list.itemNames.isEmpty {
                        emptyItemsText
                    } else {
                        HStack(alignment: .top, spacing: 14) {
                            itemColumn(left, thumb: 18)
                                .padding(.bottom, addButtonReserve)
                            itemColumn(right, thumb: 18)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .mask(fadeMask)
            }
            .overlay(alignment: .bottomLeading) { addButton(list) }
            .clipped()
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
        }
    }

    // MARK: Items

    private var emptyItemsText: some View {
        Text("Nothing on the list")
            .font(.subheadline)
            .foregroundStyle(WidgetPalette.ink.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func itemColumn(_ names: [String], thumb side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                HStack(spacing: 8) {
                    thumbnail(name, side: side)
                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(WidgetPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A small food photo, or a tasteful tile while it loads / isn't cached.
    @ViewBuilder
    private func thumbnail(_ name: String, side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.35, style: .continuous)
        Group {
            if let image = entry.images[name] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.28)
                    Image(systemName: "basket.fill")
                        .font(.system(size: side * 0.46))
                        .foregroundStyle(WidgetPalette.ink.opacity(0.5))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
//        .overlay(shape.strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
    }

    /// Softens only the very bottom edge, so items that fit stay crisp and any
    /// overflow trails off gently instead of being hard-cut or ghosted.
    private var fadeMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.9),
                .init(color: .black.opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: Add button

    /// Small widgets allow only one tap target (the tile's `widgetURL`), so the
    /// button is visual there; medium widgets get a real Link into the Add modal.
    @ViewBuilder
    private func addButton(_ list: WidgetListSummary) -> some View {
        if !isSmall, let url = GroupDeepLink.addURL(householdId: list.id) {
            Link(destination: url) { addButtonLabel }
        } else {
            addButtonLabel
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var addButtonLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.footnote.weight(.heavy))
            Text("Add")
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: isSmall ? .infinity : nil)
        .frame(height: 30)
        .padding(.horizontal, isSmall ? 0 : 18)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
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
    GroceryListEntry(date: .now, list: .placeholder, images: [:])
    GroceryListEntry(date: .now, list: WidgetListSummary(
        id: "empty", name: "Weeknight", icon: "cart.fill",
        colorThemeRaw: "green", storeName: nil, pendingCount: 0, itemNames: []),
        images: [:])
}

#Preview("Medium", as: .systemMedium) {
    GroceryListWidget()
} timeline: {
    GroceryListEntry(date: .now, list: .placeholder, images: [:])
}
#endif
