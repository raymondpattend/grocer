import PostHog
import SwiftUI

/// Lets the shopper pick which same-store lists to shop together before starting
/// a combined trip. Every candidate is pre-selected; the shopper can untick any
/// they don't want. Starting requires at least two lists.
struct MultiListSelectionSheet: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    /// Current group first, then the other groups that share its store.
    let candidates: [Household]
    var tint: Color = .green
    let onStart: ([GroceryList]) -> Void

    @State private var selectedIds: Set<String>

    init(candidates: [Household], tint: Color = .green, onStart: @escaping ([GroceryList]) -> Void) {
        self.candidates = candidates
        self.tint = tint
        self.onStart = onStart
        _selectedIds = State(initialValue: Set(candidates.map(\.id)))
    }

    private var storeName: String? {
        candidates.lazy
            .compactMap { $0.storeName?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private var selectedCount: Int { selectedIds.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    ForEach(candidates) { house in
                        card(house)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Shop Together")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { Haptics.tap(); dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                startButton
            }
            .tint(tint)
            .postHogScreenView("Multi List Selection")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.15)).frame(width: 64, height: 64)
                Image(systemName: "cart.fill.badge.plus")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .accessibilityHidden(true)

            Text("Shopping at the same store?")
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var headerSubtitle: String {
        if let store = storeName {
            return String(localized: "You have ^[\(candidates.count) list](inflect: true) for \(store). Shop them as one trip so you only walk the aisles once — items merge by aisle and each keeps its own list.")
        }
        return String(localized: "Shop ^[\(candidates.count) list](inflect: true) as one trip so you only walk the aisles once — items merge by aisle and each keeps its own list.")
    }

    // MARK: - Candidate card (with item preview)

    private func card(_ house: Household) -> some View {
        let items = repo.list(for: house).map { repo.pendingItems(forList: $0.id) } ?? []
        let isSelected = selectedIds.contains(house.id)
        return Button {
            Haptics.selection()
            if isSelected {
                selectedIds.remove(house.id)
            } else {
                selectedIds.insert(house.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(house.tint.opacity(0.15)).frame(width: 40, height: 40)
                        Image(systemName: house.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(house.tint)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(house.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("^[\(items.count) item](inflect: true)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? tint : Color(.systemGray3))
                }

                if !items.isEmpty {
                    Text(previewText(items))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("Nothing on this list yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.6) : Color(.separator).opacity(0.4),
                                  lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// A short, comma-joined preview of the first few item names, with a tail
    /// count so a long list doesn't dominate the card.
    private func previewText(_ items: [GroceryItem]) -> String {
        let shown = items.prefix(4).map(\.name)
        let remainder = items.count - shown.count
        let joined = shown.joined(separator: ", ")
        return remainder > 0 ? "\(joined) +\(remainder) more" : joined
    }

    // MARK: - Start

    private var startButton: some View {
        Button { start() } label: {
            Text(selectedCount >= 2
                 ? String(localized: "Shop ^[\(selectedCount) list](inflect: true) Together")
                 : String(localized: "Select at least 2 lists"))
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .grocerGlassButton(prominent: true)
        .tint(tint)
        .controlSize(.large)
        .disabled(selectedCount < 2)
        .opacity(selectedCount < 2 ? 0.55 : 1)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func start() {
        let lists = candidates
            .filter { selectedIds.contains($0.id) }
            .compactMap { repo.list(for: $0) }
        guard lists.count >= 2 else { return }
        Haptics.success()
        PostHogSDK.shared.capture("combined_trip_started", properties: [
            "list_count": lists.count,
        ])
        dismiss()
        onStart(lists)
    }
}

/// Banner shown on the planning screen when a combined trip is in progress, so
/// the shopper can hop back into the merged view after leaving or relaunching.
struct CombinedSessionBanner: View {
    let listCount: Int
    let progress: SessionProgress
    var shoppers: [HouseholdMember] = []
    var tint: Color = .green
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(tint.opacity(0.2)).frame(width: 48, height: 48)
                    Image(systemName: "cart.fill.badge.plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Combined trip · ^[\(listCount) list](inflect: true)")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(String(localized: "\(progress.found) found · \(progress.remaining) left"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Combined trip, \(listCount) lists, \(progress.found) found, \(progress.remaining) left"))
        .accessibilityHint(String(localized: "Opens combined shopping"))
    }
}
