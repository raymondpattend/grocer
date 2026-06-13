import ActivityKit
import Foundation

/// Live Activity attributes shared between the app target and the widget
/// extension target. The `ContentState` shape is mirrored on the backend in
/// packages/shared/src/schemas.ts (`LiveActivityContentSchema`) so APNs
/// `content-state` payloads decode directly into this type.
///
/// IMPORTANT: the type name `GroceryActivityAttributes` must match
/// `ACTIVITY_ATTRIBUTES_TYPE` in apps/api/src/services/apns.ts, because the
/// APNs `start` push carries `attributes-type` to tell ActivityKit which
/// attributes to instantiate.
struct GroceryActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var storeName: String?
        var shopperName: String
        var status: String          // SessionStatus rawValue
        var itemsFound: Int
        var itemsRemaining: Int
        var totalItems: Int
        var outOfStockCount: Int
        var replacedCount: Int
        var lastHandledItemName: String?
        var lastHandledItemStatus: String?

        var progress: Double {
            guard totalItems > 0 else { return 0 }
            let handled = totalItems - itemsRemaining
            return min(1, max(0, Double(handled) / Double(totalItems)))
        }

        // String literals (not SessionStatus) so this file stays self-contained
        // and compiles in the widget extension target without the app's models.
        var isCompleted: Bool { status == "Completed" }
        var isCancelled: Bool { status == "Cancelled" }
    }

    // Static attributes — set once when the activity starts.
    var householdId: String
    var sessionId: String
    /// `ShoppingSession.startedByMemberId`. Lets the widget look up the shopper's
    /// avatar in the App Group cache (keyed by member id) so family devices that
    /// have synced the roster can render it. Optional so activities started by an
    /// older build (without this field) still decode.
    var startedByMemberId: String?
}
