import SwiftUI

struct AuditLogView: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    @State private var filter: AuditLogFilter = .all
    @State private var searchText = ""

    private var tint: Color { repo.currentHousehold?.tint ?? .green }

    var body: some View {
        List {
            if groupedEvents.isEmpty {
                Section {
                    ContentUnavailableView(emptyTitle, systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            } else {
                ForEach(groupedEvents) { section in
                    Section(section.title) {
                        ForEach(section.events) { event in
                            AuditLogRow(presentation: presentation(for: event))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Audit Log")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search audit log")
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Filter", selection: $filter) {
                ForEach(AuditLogFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .refreshable { await repo.manualRefresh() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var emptyTitle: String {
        repo.currentAuditEvents.isEmpty ? "No Audit Events" : "No Matching Events"
    }

    private var visibleEvents: [ItemEvent] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return repo.currentAuditEvents.filter { event in
            guard filter.matches(event) else { return false }
            guard !query.isEmpty else { return true }
            return searchableText(for: event).localizedCaseInsensitiveContains(query)
        }
    }

    private var groupedEvents: [AuditLogSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visibleEvents) { event in
            calendar.startOfDay(for: event.createdAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            AuditLogSection(
                day: day,
                title: sectionTitle(for: day),
                events: (grouped[day] ?? []).sorted { $0.createdAt > $1.createdAt }
            )
        }
    }

    private func presentation(for event: ItemEvent) -> AuditLogPresentation {
        AuditLogPresentation(
            event: event,
            item: item(for: event),
            session: session(for: event),
            groupTint: tint
        )
    }

    private func searchableText(for event: ItemEvent) -> String {
        let presentation = presentation(for: event)
        var pieces = [
            presentation.title,
            presentation.detail,
            event.createdByDisplayName,
            event.type.rawValue,
            item(for: event)?.category.rawValue,
            item(for: event)?.quantity,
            session(for: event)?.storeName,
        ].compactMap { $0 }
        pieces.append(contentsOf: event.metadata.values)
        return pieces.joined(separator: " ")
    }

    private func item(for event: ItemEvent) -> GroceryItem? {
        guard let itemId = event.itemId else { return nil }
        return repo.items.first { $0.id == itemId }
    }

    private func session(for event: ItemEvent) -> ShoppingSession? {
        guard let sessionId = event.sessionId else { return nil }
        return repo.sessions.first { $0.id == sessionId }
    }

    private func sectionTitle(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }
}

private struct AuditLogSection: Identifiable {
    let day: Date
    let title: String
    let events: [ItemEvent]

    var id: Date { day }
}

private enum AuditLogFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case items = "Items"
    case trips = "Trips"

    var id: String { rawValue }

    func matches(_ event: ItemEvent) -> Bool {
        switch self {
        case .all:
            return true
        case .items:
            return !event.type.isTripEvent
        case .trips:
            return event.type.isTripEvent
        }
    }
}

private struct AuditLogPresentation {
    let event: ItemEvent
    let icon: String
    let iconTint: Color
    let title: String
    let detail: String?

    init(event: ItemEvent, item: GroceryItem?, session: ShoppingSession?, groupTint: Color) {
        self.event = event

        let itemName = item?.name ?? event.metadata["name"] ?? "Item"
        let replacement = event.metadata["replacement"].nilIfBlank ?? (item?.replacementItemName).nilIfBlank
        let itemDetail = Self.itemDetail(for: item)
        let store = (session?.storeName).nilIfBlank ?? event.metadata["store"].nilIfBlank

        switch event.type {
        case .itemAdded:
            icon = "plus.circle.fill"
            iconTint = .green
            title = "Added \(itemName)"
            detail = itemDetail
        case .itemEdited:
            icon = "pencil.circle.fill"
            iconTint = .blue
            title = "Edited \(itemName)"
            detail = itemDetail
        case .itemFound:
            icon = "checkmark.circle.fill"
            iconTint = .green
            title = "Found \(itemName)"
            detail = itemDetail
        case .itemReplaced:
            icon = "arrow.triangle.2.circlepath.circle.fill"
            iconTint = .blue
            title = "Replaced \(itemName)"
            detail = replacement.map { "Replacement: \($0)" } ?? itemDetail
        case .itemOutOfStock:
            icon = "xmark.circle.fill"
            iconTint = .red
            title = "Marked \(itemName) unavailable"
            detail = (item?.replacementPreference).nilIfBlank.map { "Preference: \($0)" } ?? itemDetail
        case .itemSkipped:
            icon = "arrow.uturn.forward.circle.fill"
            iconTint = .orange
            title = "Skipped \(itemName)"
            detail = itemDetail
        case .itemRemoved:
            icon = "trash.circle.fill"
            iconTint = .red
            title = "Removed \(itemName)"
            detail = itemDetail
        case .sessionStarted:
            icon = "cart.fill"
            iconTint = groupTint
            title = "Started shopping"
            detail = store.map { "Store: \($0)" }
        case .sessionCompleted:
            icon = "checkmark.seal.fill"
            iconTint = .green
            title = "Completed shopping"
            detail = Self.durationDetail(for: session)
        case .sessionCancelled:
            icon = "xmark.octagon.fill"
            iconTint = .red
            title = "Cancelled shopping"
            detail = Self.durationDetail(for: session)
        }
    }

    private static func itemDetail(for item: GroceryItem?) -> String? {
        guard let item else { return nil }
        let pieces = [item.quantity, item.category.rawValue, item.notes]
            .compactMap { $0.nilIfBlank }
        return pieces.isEmpty ? nil : pieces.joined(separator: " - ")
    }

    private static func durationDetail(for session: ShoppingSession?) -> String? {
        guard let session, let endedAt = session.endedAt else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        guard let duration = formatter.string(from: session.startedAt, to: endedAt) else { return nil }
        return "Duration: \(duration)"
    }
}

private struct AuditLogRow: View {
    let presentation: AuditLogPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(presentation.iconTint.opacity(0.14))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: presentation.icon)
                        .font(.headline)
                        .foregroundStyle(presentation.iconTint)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let detail = presentation.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Text(actorName)
                    Text(presentation.event.createdAt.formatted(.dateTime.hour().minute()))
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var actorName: String {
        presentation.event.createdByDisplayName.nilIfBlank ?? "Unknown"
    }
}

private extension ItemEventType {
    var isTripEvent: Bool {
        switch self {
        case .sessionStarted, .sessionCompleted, .sessionCancelled:
            return true
        case .itemAdded, .itemEdited, .itemFound, .itemReplaced,
             .itemOutOfStock, .itemSkipped, .itemRemoved:
            return false
        }
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
