import XCTest
@testable import Grocer

/// Pure-logic tests for the custom ("My Order") list organization: the
/// `customOrder` comparator and the fractional `sortOrder(between:and:)` helper
/// that `GroceryRepository.reorderPendingItems` uses to reposition a dragged item.
final class CustomOrderingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - sortOrder(between:and:)

    func testSortOrderBetweenTwoNeighborsIsMidpoint() {
        XCTAssertEqual(GroceryItem.sortOrder(between: 1000, and: 2000), 1500)
    }

    func testSortOrderPastLeadingEdgeStepsBelow() {
        XCTAssertEqual(GroceryItem.sortOrder(between: nil, and: 1000), 1000 - GroceryItem.sortOrderStep)
    }

    func testSortOrderPastTrailingEdgeStepsAbove() {
        XCTAssertEqual(GroceryItem.sortOrder(between: 1000, and: nil), 1000 + GroceryItem.sortOrderStep)
    }

    func testSortOrderForEmptyListIsFirstStep() {
        XCTAssertEqual(GroceryItem.sortOrder(between: nil, and: nil), GroceryItem.sortOrderStep)
    }

    // MARK: - customOrder comparator

    func testCustomOrderSortsBySortOrderAscending() {
        let items = [
            makeItem(id: "a", sortOrder: 3000),
            makeItem(id: "b", sortOrder: 1000),
            makeItem(id: "c", sortOrder: 2000),
        ]
        XCTAssertEqual(items.sorted(by: GroceryItem.customOrder).map(\.id), ["b", "c", "a"])
    }

    func testCustomOrderPlacesUnplacedItemsLast() {
        let items = [
            makeItem(id: "unplaced", sortOrder: nil),
            makeItem(id: "placed", sortOrder: 5000),
        ]
        XCTAssertEqual(items.sorted(by: GroceryItem.customOrder).map(\.id), ["placed", "unplaced"])
    }

    func testCustomOrderFallsBackToCreationDateForUnplacedItems() {
        let items = [
            makeItem(id: "newer", sortOrder: nil, createdAt: date.addingTimeInterval(60)),
            makeItem(id: "older", sortOrder: nil, createdAt: date),
        ]
        XCTAssertEqual(items.sorted(by: GroceryItem.customOrder).map(\.id), ["older", "newer"])
    }

    /// Moving an item to the front mirrors `reorderPendingItems`: compute its new
    /// neighbors after the move, take the fractional midpoint, and re-sort. Only the
    /// moved item's `sortOrder` changes.
    func testFractionalMoveToFrontRewritesOnlyMovedItem() {
        var items = [
            makeItem(id: "a", sortOrder: 1024),
            makeItem(id: "b", sortOrder: 2048),
            makeItem(id: "c", sortOrder: 3072),
        ]

        var ordered = items
        let movedId = ordered[2].id
        ordered.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let pos = ordered.firstIndex { $0.id == movedId }!
        let before = pos > 0 ? ordered[pos - 1].sortOrder : nil
        let after = pos < ordered.count - 1 ? ordered[pos + 1].sortOrder : nil
        let value = GroceryItem.sortOrder(between: before, and: after)

        XCTAssertEqual(value, 1024 - GroceryItem.sortOrderStep)

        if let idx = items.firstIndex(where: { $0.id == movedId }) { items[idx].sortOrder = value }
        XCTAssertEqual(items.map(\.sortOrder), [1024, 2048, value]) // a, b unchanged
        XCTAssertEqual(items.sorted(by: GroceryItem.customOrder).map(\.id), ["c", "a", "b"])
    }

    /// Moving an item between two others lands it on their midpoint.
    func testFractionalMoveBetweenNeighborsUsesMidpoint() {
        var items = [
            makeItem(id: "a", sortOrder: 1024),
            makeItem(id: "b", sortOrder: 2048),
            makeItem(id: "c", sortOrder: 3072),
        ]

        var ordered = items
        let movedId = ordered[0].id // move "a" to between "b" and "c"
        ordered.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        let pos = ordered.firstIndex { $0.id == movedId }!
        let before = pos > 0 ? ordered[pos - 1].sortOrder : nil
        let after = pos < ordered.count - 1 ? ordered[pos + 1].sortOrder : nil
        let value = GroceryItem.sortOrder(between: before, and: after)

        XCTAssertEqual(value, 2560) // (2048 + 3072) / 2

        if let idx = items.firstIndex(where: { $0.id == movedId }) { items[idx].sortOrder = value }
        XCTAssertEqual(items.sorted(by: GroceryItem.customOrder).map(\.id), ["b", "a", "c"])
    }

    private func makeItem(id: String, sortOrder: Double?, createdAt: Date? = nil) -> GroceryItem {
        GroceryItem(
            id: id,
            householdId: "home",
            listId: "list",
            name: id,
            quantity: nil,
            category: .other,
            notes: nil,
            requestedByMemberId: "member",
            requestedByDisplayName: "Ray",
            status: .needed,
            priority: .normal,
            replacementPreference: nil,
            replacementItemName: nil,
            createdAt: createdAt ?? date,
            updatedAt: createdAt ?? date,
            completedAt: nil,
            deletedAt: nil,
            activeSessionId: nil,
            photoData: nil,
            sortOrder: sortOrder
        )
    }
}
