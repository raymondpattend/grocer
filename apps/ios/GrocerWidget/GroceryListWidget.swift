import AppIntents
import SwiftUI
import WidgetKit

/// How many item rows the medium widget shows.
private let widgetVisibleItemCount = 3
private let widgetVerticalPadding: CGFloat = 10

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
        let entry = await entry(for: configuration)
        // The app nudges WidgetCenter on every change; this is just a fallback so
        // the widget still refreshes if the app hasn't run in a while.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func entry(for configuration: SelectListIntent) async -> GroceryListEntry {
        let lists = WidgetSnapshotStore.load()?.lists ?? []
        // Fall back to the first list if the chosen one is gone or none is set.
        let selected = lists.first { $0.id == configuration.list?.id } ?? lists.first
        guard let selected else {
            return GroceryListEntry(date: Date(), list: nil, images: [:])
        }

        let names = Array(selected.itemNames.prefix(widgetVisibleItemCount))
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
            colorThemeRaw: "green", storeName: nil, pendingCount: 6,
            itemNames: ["Milk", "Eggs", "Bananas", "Sourdough", "Coffee", "Tomatoes"]
        )
    }
}

// MARK: - Widget

struct GroceryListWidget: Widget {
    let kind = "GroceryListWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectListIntent.self, provider: GroceryListProvider()) { entry in
            GroceryListWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Grocery List")
        .description("See a list's items at a glance, with photos.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - View

struct GroceryListWidgetView: View {
    let entry: GroceryListEntry

    var body: some View {
        widgetContent
            .padding(.vertical, widgetVerticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var widgetContent: some View {
        Group {
            if let list = entry.list {
                content(for: list)
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder
    private func content(for list: WidgetListSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(list)

            if list.itemNames.isEmpty {
                Spacer(minLength: 0)
                Text("Nothing on the list")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer(minLength: 0)
            } else {
                itemList(list)
                Spacer(minLength: 0)
            }
        }
    }

    private func header(_ list: WidgetListSummary) -> some View {
        HStack(spacing: 6) {
            Image(systemName: list.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(widgetThemeColor(list.colorThemeRaw))
            Text(list.name)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("^[\(list.pendingCount) item](inflect: true)")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func itemList(_ list: WidgetListSummary) -> some View {
        let shown = Array(list.itemNames.prefix(widgetVisibleItemCount))
        let remaining = list.pendingCount - shown.count
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, name in
                HStack(spacing: 10) {
                    thumb(name)
                    Text(name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            if remaining > 0 {
                Text("+ \(remaining) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 38)
            }
        }
    }

    /// A small food photo (or a basket placeholder while it loads).
    @ViewBuilder
    private func thumb(_ name: String) -> some View {
        let side: CGFloat = 28
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Group {
            if let image = entry.images[name] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.gray.opacity(0.18)
                    Image(systemName: "basket.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: side * 0.4))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "cart")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open Grocer to pick a list")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Medium", as: .systemMedium) {
    GroceryListWidget()
} timeline: {
    GroceryListEntry(date: .now, list: .placeholder, images: [:])
}
#endif
