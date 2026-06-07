import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity UI for an active family grocery trip. Renders the Lock Screen
/// / banner presentation and all Dynamic Island presentations.
///
/// Content is driven by `GroceryActivityAttributes.ContentState`, updated
/// either locally (shopper's device) or via APNs pushes from the Worker API.
struct GroceryLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GroceryActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.green)
        } dynamicIsland: { context in
            // Keep the `.center` region empty — it renders in the narrow strip
            // beside the camera cutout and clips content. All content lives in
            // leading / trailing / bottom.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.state.storeName ?? "Grocery Trip")
                            .font(.caption).lineLimit(1)
                    } icon: {
                        Image(systemName: "cart.fill").foregroundStyle(.green)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timelineString(context.state))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.isCompleted || context.state.isCancelled {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finalHeadline(context.state))
                                .font(.subheadline.weight(.semibold))
                            Text(finalDetail(context.state))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 6) {
                            HStack {
                                Text("\(context.state.shopperName) is shopping")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text("\(context.state.itemsRemaining) left")
                                    .font(.caption.weight(.semibold))
                            }
                            ProgressView(value: context.state.progress)
                                .tint(.green)
                            if let last = lastHandledLine(context.state) {
                                Text(last).font(.caption2).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "cart.fill").foregroundStyle(.green)
            } compactTrailing: {
                Text("\(context.state.itemsRemaining)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } minimal: {
                Image(systemName: "cart.fill").foregroundStyle(.green)
            }
            .keylineTint(.green)
        }
    }

    private func timelineString(_ s: GroceryActivityAttributes.ContentState) -> String {
        "\(s.itemsFound)/\(s.totalItems)"
    }
    private func lastHandledLine(_ s: GroceryActivityAttributes.ContentState) -> String? {
        guard let name = s.lastHandledItemName, let status = s.lastHandledItemStatus else { return nil }
        return "Last: \(name) \(status.lowercased())"
    }
    private func finalHeadline(_ s: GroceryActivityAttributes.ContentState) -> String {
        s.isCancelled ? "Shopping Cancelled" : "Shopping Complete"
    }
    private func finalDetail(_ s: GroceryActivityAttributes.ContentState) -> String {
        if s.isCancelled { return "No longer active" }
        return "\(s.itemsFound) found · \(s.replacedCount) replaced · \(s.outOfStockCount) unavailable"
    }
}

// MARK: - Lock Screen / banner

private struct LockScreenView: View {
    let state: GroceryActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Grocery Trip", systemImage: "cart.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Spacer()
                if let store = state.storeName {
                    Text(store).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if state.isCompleted || state.isCancelled {
                Text(state.isCancelled ? "Shopping Cancelled" : "Shopping Complete")
                    .font(.title3.bold())
                Text(state.isCancelled
                     ? "No longer active"
                     : "\(state.itemsFound) found · \(state.replacedCount) replaced · \(state.outOfStockCount) unavailable")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("\(state.shopperName) is shopping")
                    .font(.subheadline.weight(.medium))
                HStack {
                    Text("\(state.itemsFound) found")
                    Text("·")
                    Text("\(state.itemsRemaining) left")
                }
                .font(.subheadline).foregroundStyle(.secondary)

                ProgressView(value: state.progress).tint(.green)

                if let name = state.lastHandledItemName, let status = state.lastHandledItemStatus {
                    Text("Last: \(name) \(status.lowercased())")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}
