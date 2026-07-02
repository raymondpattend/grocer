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
            LockScreenView(state: context.state, startedByMemberId: context.attributes.startedByMemberId)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(.green)
                .widgetURL(GroupDeepLink.url(householdId: context.attributes.householdId))
        } dynamicIsland: { context in
            // Keep the `.center` region empty — it renders in the narrow strip
            // beside the camera cutout and clips content. All content lives in
            // leading / trailing / bottom.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("\(context.state.shopperName) is shopping")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } icon: {
                        ShopperAvatarIcon(memberId: context.attributes.startedByMemberId, size: 20)
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
                                Spacer()
                                Text("\(context.state.itemsRemaining) left")
                                    .font(.caption.weight(.semibold))
                            }
                            ProgressView(value: context.state.progress)
                                .tint(.green)
                                .scaleEffect(x: 1, y: 1.15, anchor: .center)
                            if let name = context.state.lastHandledItemName {
                                LastFoodThumbnail(name: name, size: 24)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            } compactLeading: {
                ShopperAvatarIcon(memberId: context.attributes.startedByMemberId, size: 18)
            } compactTrailing: {
                Text("\(context.state.itemsRemaining)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } minimal: {
                ShopperAvatarIcon(memberId: context.attributes.startedByMemberId, size: 18)
            }
            .keylineTint(.green)
            .widgetURL(GroupDeepLink.url(householdId: context.attributes.householdId))
        }
    }

    private func timelineString(_ s: GroceryActivityAttributes.ContentState) -> String {
        "\(s.itemsFound)/\(s.totalItems)"
    }
    private func finalHeadline(_ s: GroceryActivityAttributes.ContentState) -> String {
        s.isCancelled ? String(localized: "Shopping Cancelled") : String(localized: "Shopping Complete")
    }
    private func finalDetail(_ s: GroceryActivityAttributes.ContentState) -> String {
        if s.isCancelled { return String(localized: "No longer active") }
        return String(localized: "\(s.itemsFound) found · \(s.replacedCount) replaced · \(s.outOfStockCount) unavailable")
    }
}

// MARK: - Lock Screen / banner

private struct LockScreenView: View {
    let state: GroceryActivityAttributes.ContentState
    let startedByMemberId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    Text(shopperStatus(state))
                } icon: {
                    ShopperAvatarIcon(memberId: startedByMemberId, size: 22)
                }
                .font(.subheadline.weight(.medium)).foregroundStyle(state.isCompleted || state.isCancelled ? .secondary : .primary)
                Spacer()
                if let store = state.storeName {
                    Text(store).font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if state.isCompleted || state.isCancelled {
                Text(state.isCancelled ? String(localized: "Shopping Cancelled") : String(localized: "Shopping Complete"))
                    .font(.title3.bold())
                if !state.isCancelled {
                    Text(String(localized: "\(state.itemsFound) found · \(state.replacedCount) replaced · \(state.outOfStockCount) unavailable"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("\(state.itemsFound) found")
                    Text("·")
                    Text("\(state.itemsRemaining) left")
                }
                .font(.subheadline).foregroundStyle(.secondary)

                ProgressView(value: state.progress).tint(.green)
                    .scaleEffect(x: 1, y: 1.15, anchor: .center)

                LastFoodThumbnail(name: state.lastHandledItemName, size: 32)
            }
        }
        .padding()
    }

    private func shopperStatus(_ state: GroceryActivityAttributes.ContentState) -> String {
        if state.isCancelled {
            return String(localized: "\(state.shopperName) cancelled shopping")
        }
        return String(localized: "\(state.shopperName) is shopping")
    }
}

// MARK: - Image helpers

/// The active shopper's avatar, loaded synchronously from the App Group cache.
/// Falls back to the cart icon when no avatar has been published — e.g. on a
/// family device whose activity was started via push (the push carries no
/// image data).
private struct ShopperAvatarIcon: View {
    let memberId: String?
    var size: CGFloat = 22

    var body: some View {
        if let memberId,
           let image = WidgetShopperAvatarStore.cachedThumbnail(forMember: memberId, maxPixel: size * 3) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            FAImage("cart.fill").foregroundStyle(.green)
        }
    }
}

/// Thumbnail of the most recently handled item's food image, loaded
/// synchronously from the shared product-image cache. Renders nothing when the
/// image isn't cached locally.
private struct LastFoodThumbnail: View {
    let name: String?
    var size: CGFloat = 28

    var body: some View {
        if let name, let image = WidgetImageStore.cachedThumbnail(for: name, maxPixel: size * 3) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

// MARK: - Previews

#if DEBUG
private extension GroceryActivityAttributes {
    static var preview: GroceryActivityAttributes {
        GroceryActivityAttributes(
            householdId: "preview-household",
            sessionId: "preview-session"
        )
    }
}

private extension GroceryActivityAttributes.ContentState {
    static var previewActive: GroceryActivityAttributes.ContentState {
        GroceryActivityAttributes.ContentState(
            storeName: "Meijer",
            shopperName: "Sam",
            status: "Active",
            itemsFound: 7,
            itemsRemaining: 5,
            totalItems: 12,
            outOfStockCount: 1,
            replacedCount: 1,
            lastHandledItemName: "Honeycrisp Apples",
            lastHandledItemStatus: "Found"
        )
    }

    static var previewReplaced: GroceryActivityAttributes.ContentState {
        GroceryActivityAttributes.ContentState(
            storeName: "Costco",
            shopperName: "Maya",
            status: "Active",
            itemsFound: 10,
            itemsRemaining: 2,
            totalItems: 12,
            outOfStockCount: 1,
            replacedCount: 2,
            lastHandledItemName: "Oat Milk",
            lastHandledItemStatus: "Replaced"
        )
    }

    static var previewCompleted: GroceryActivityAttributes.ContentState {
        GroceryActivityAttributes.ContentState(
            storeName: "Trader Joe's",
            shopperName: "Sam",
            status: "Completed",
            itemsFound: 11,
            itemsRemaining: 0,
            totalItems: 12,
            outOfStockCount: 1,
            replacedCount: 2,
            lastHandledItemName: nil,
            lastHandledItemStatus: nil
        )
    }

    static var previewCancelled: GroceryActivityAttributes.ContentState {
        GroceryActivityAttributes.ContentState(
            storeName: nil,
            shopperName: "Maya",
            status: "Cancelled",
            itemsFound: 3,
            itemsRemaining: 7,
            totalItems: 10,
            outOfStockCount: 0,
            replacedCount: 0,
            lastHandledItemName: "Sourdough",
            lastHandledItemStatus: "Skipped"
        )
    }
}

#Preview("Lock Screen", as: .content, using: GroceryActivityAttributes.preview) {
    GroceryLiveActivity()
} contentStates: {
    GroceryActivityAttributes.ContentState.previewActive
    GroceryActivityAttributes.ContentState.previewReplaced
    GroceryActivityAttributes.ContentState.previewCompleted
    GroceryActivityAttributes.ContentState.previewCancelled
}

#Preview("Dynamic Island Expanded", as: .dynamicIsland(.expanded), using: GroceryActivityAttributes.preview) {
    GroceryLiveActivity()
} contentStates: {
    GroceryActivityAttributes.ContentState.previewActive
    GroceryActivityAttributes.ContentState.previewReplaced
    GroceryActivityAttributes.ContentState.previewCompleted
    GroceryActivityAttributes.ContentState.previewCancelled
}

#Preview("Dynamic Island Compact", as: .dynamicIsland(.compact), using: GroceryActivityAttributes.preview) {
    GroceryLiveActivity()
} contentStates: {
    GroceryActivityAttributes.ContentState.previewActive
    GroceryActivityAttributes.ContentState.previewReplaced
    GroceryActivityAttributes.ContentState.previewCompleted
}

#Preview("Dynamic Island Minimal", as: .dynamicIsland(.minimal), using: GroceryActivityAttributes.preview) {
    GroceryLiveActivity()
} contentStates: {
    GroceryActivityAttributes.ContentState.previewActive
    GroceryActivityAttributes.ContentState.previewCompleted
}
#endif
