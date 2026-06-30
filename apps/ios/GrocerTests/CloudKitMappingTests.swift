import CloudKit
import XCTest
@testable import Grocer

final class CloudKitMappingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testHouseholdRoundTripsCoreFieldsAndZoneMetadata() throws {
        let record = CKRecord(recordType: CK.RecordType.household, recordID: recordID("house"))
        let household = Household(
            id: "house",
            name: "Family",
            ownerMemberId: "owner",
            storeName: "Market",
            icon: "basket.fill",
            colorTheme: .teal,
            createdAt: date,
            updatedAt: date,
            recordZoneName: nil,
            recordOwnerName: nil
        )

        household.apply(to: record)
        let decoded = try XCTUnwrap(Household(record: record))

        XCTAssertEqual(decoded.id, "house")
        XCTAssertEqual(decoded.name, "Family")
        XCTAssertEqual(decoded.storeName, "Market")
        XCTAssertEqual(decoded.icon, "basket.fill")
        XCTAssertEqual(decoded.colorTheme, .teal)
        XCTAssertEqual(decoded.recordZoneName, CK.householdZoneName)
        XCTAssertEqual(decoded.recordOwnerName, CKCurrentUserDefaultName)
    }

    func testHouseholdDefaultsUnknownAppearanceValues() throws {
        let record = CKRecord(recordType: CK.RecordType.household, recordID: recordID("house"))
        record[CK.Field.name] = "Family" as CKRecordValue
        record[CK.Field.ownerMemberId] = "owner" as CKRecordValue
        record[CK.Field.icon] = "not-a-real-symbol" as CKRecordValue
        record[CK.Field.colorTheme] = "neon" as CKRecordValue

        let decoded = try XCTUnwrap(Household(record: record))

        XCTAssertEqual(decoded.icon, "not-a-real-symbol")
        XCTAssertEqual(decoded.colorTheme, .default)
    }

    func testMemberCompositeRecordNameDecodesToPlainMemberId() throws {
        let record = CKRecord(recordType: CK.RecordType.member, recordID: recordID("member_home"))
        record[CK.Field.householdId] = "home" as CKRecordValue
        record[CK.Field.displayName] = "Ray" as CKRecordValue
        record[CK.Field.iCloudUserRecordName] = "member" as CKRecordValue
        record[CK.Field.role] = MemberRole.member.rawValue as CKRecordValue
        record[CK.Field.joinedAt] = date as CKRecordValue

        let decoded = try XCTUnwrap(HouseholdMember(record: record))

        XCTAssertEqual(decoded.id, "member")
        XCTAssertEqual(decoded.householdId, "home")
        XCTAssertEqual(decoded.displayName, "Ray")
        XCTAssertEqual(decoded.role, .member)
    }

    func testLegacyMemberRecordNameStillDecodes() throws {
        let record = CKRecord(recordType: CK.RecordType.member, recordID: recordID("member"))
        record[CK.Field.householdId] = "home" as CKRecordValue
        record[CK.Field.displayName] = "Ray" as CKRecordValue
        record[CK.Field.role] = MemberRole.owner.rawValue as CKRecordValue
        record[CK.Field.joinedAt] = date as CKRecordValue

        let decoded = try XCTUnwrap(HouseholdMember(record: record))

        XCTAssertEqual(decoded.id, "member")
        XCTAssertEqual(decoded.role, .owner)
    }

    func testGroceryItemDefaultsPriorityAndPreservesSoftDeleteFields() throws {
        let record = CKRecord(recordType: CK.RecordType.item, recordID: recordID("item"))
        record[CK.Field.householdId] = "home" as CKRecordValue
        record[CK.Field.listId] = "list" as CKRecordValue
        record[CK.Field.itemName] = "Milk" as CKRecordValue
        record[CK.Field.category] = GroceryCategory.dairy.rawValue as CKRecordValue
        record[CK.Field.status] = ItemStatus.removed.rawValue as CKRecordValue
        record[CK.Field.requestedByMemberId] = "member" as CKRecordValue
        record[CK.Field.requestedByDisplayName] = "Ray" as CKRecordValue
        record[CK.Field.createdAt] = date as CKRecordValue
        record[CK.Field.updatedAt] = date as CKRecordValue
        record[CK.Field.completedAt] = date as CKRecordValue
        record[CK.Field.deletedAt] = date as CKRecordValue
        record[CK.Field.activeSessionId] = "trip" as CKRecordValue

        let decoded = try XCTUnwrap(GroceryItem(record: record))

        XCTAssertEqual(decoded.priority, .normal)
        XCTAssertEqual(decoded.status, .removed)
        XCTAssertEqual(decoded.completedAt, date)
        XCTAssertEqual(decoded.deletedAt, date)
        XCTAssertEqual(decoded.activeSessionId, "trip")
    }

    func testGroceryItemMigratesLegacyPriorityValues() throws {
        let record = CKRecord(recordType: CK.RecordType.item, recordID: recordID("item"))
        record[CK.Field.householdId] = "home" as CKRecordValue
        record[CK.Field.listId] = "list" as CKRecordValue
        record[CK.Field.itemName] = "Milk" as CKRecordValue
        record[CK.Field.category] = GroceryCategory.dairy.rawValue as CKRecordValue
        record[CK.Field.status] = ItemStatus.needed.rawValue as CKRecordValue
        record[CK.Field.requestedByMemberId] = "member" as CKRecordValue
        record[CK.Field.requestedByDisplayName] = "Ray" as CKRecordValue
        record[CK.Field.createdAt] = date as CKRecordValue
        record[CK.Field.updatedAt] = date as CKRecordValue

        // The former "High" level is now surfaced as `.critical`.
        record[CK.Field.priority] = "High" as CKRecordValue
        XCTAssertEqual(try XCTUnwrap(GroceryItem(record: record)).priority, .critical)

        // The removed "Low" level collapses onto `.normal`.
        record[CK.Field.priority] = "Low" as CKRecordValue
        XCTAssertEqual(try XCTUnwrap(GroceryItem(record: record)).priority, .normal)
    }

    func testShoppingTripItemApplyCanOmitReplacementItemName() throws {
        let record = CKRecord(recordType: CK.RecordType.tripItem, recordID: recordID("trip_item"))
        let tripItem = ShoppingTripItem(
            id: "trip_item",
            householdId: "home",
            sessionId: "trip",
            itemId: "item",
            name: "Milk",
            quantity: "1",
            category: .dairy,
            outcome: .replaced,
            replacementItemName: "Oat milk",
            requestedByMemberId: "member",
            requestedByDisplayName: "Ray",
            createdAt: date
        )

        tripItem.apply(to: record, includeReplacementItemName: false)

        XCTAssertNil(record[CK.Field.replacementItemName])
        XCTAssertEqual(record[CK.Field.status] as? String, ItemStatus.replaced.rawValue)
    }

    func testGroceryItemApplyWritesMutableFields() throws {
        let record = CKRecord(recordType: CK.RecordType.item, recordID: recordID("item"))
        let item = GroceryItem(
            id: "item",
            householdId: "home",
            listId: "list",
            name: "Coffee",
            quantity: "1 bag",
            category: .drinks,
            notes: "Whole bean",
            requestedByMemberId: "member",
            requestedByDisplayName: "Ray",
            status: .replaced,
            priority: .critical,
            replacementPreference: "Any dark roast",
            replacementItemName: "Espresso roast",
            createdAt: date,
            updatedAt: date,
            completedAt: date,
            deletedAt: nil,
            activeSessionId: "trip"
        )

        item.apply(to: record)

        XCTAssertEqual(record[CK.Field.itemName] as? String, "Coffee")
        XCTAssertEqual(record[CK.Field.quantity] as? String, "1 bag")
        XCTAssertEqual(record[CK.Field.category] as? String, GroceryCategory.drinks.rawValue)
        XCTAssertEqual(record[CK.Field.status] as? String, ItemStatus.replaced.rawValue)
        XCTAssertEqual(record[CK.Field.priority] as? String, ItemPriority.critical.rawValue)
        XCTAssertEqual(record[CK.Field.replacementPreference] as? String, "Any dark roast")
        XCTAssertEqual(record[CK.Field.replacementItemName] as? String, "Espresso roast")
        XCTAssertEqual(record[CK.Field.completedAt] as? Date, date)
        XCTAssertNil(record[CK.Field.deletedAt])
        XCTAssertEqual(record[CK.Field.activeSessionId] as? String, "trip")
    }

    func testGroceryItemRoundTripsPhotoAsset() throws {
        let record = CKRecord(recordType: CK.RecordType.item, recordID: recordID("item"))
        let photo = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03])
        var item = makeItem()
        item.photoData = photo

        item.apply(to: record)
        XCTAssertNotNil(record[CK.Field.photo] as? CKAsset)

        let decoded = try XCTUnwrap(GroceryItem(record: record))
        XCTAssertEqual(decoded.photoData, photo)
    }

    func testGroceryItemWithoutPhotoDecodesNil() throws {
        let record = CKRecord(recordType: CK.RecordType.item, recordID: recordID("item"))
        let item = makeItem() // photoData defaults to nil

        item.apply(to: record)
        XCTAssertNil(record[CK.Field.photo])

        let decoded = try XCTUnwrap(GroceryItem(record: record))
        XCTAssertNil(decoded.photoData)
    }

    func testHouseholdRoundTripsListSortMode() throws {
        let record = CKRecord(recordType: CK.RecordType.household, recordID: recordID("house"))
        var household = makeHousehold()
        household.listSortMode = .custom

        household.apply(to: record)
        XCTAssertEqual(record[CK.Field.listSortMode] as? String, ListSortMode.custom.rawValue)

        let decoded = try XCTUnwrap(Household(record: record))
        XCTAssertEqual(decoded.listSortMode, .custom)
        XCTAssertEqual(decoded.sortMode, .custom)
    }

    func testHouseholdDefaultsSortModeToCategoryWhenFieldAbsent() throws {
        let record = CKRecord(recordType: CK.RecordType.household, recordID: recordID("house"))
        record[CK.Field.name] = "Family" as CKRecordValue
        record[CK.Field.ownerMemberId] = "owner" as CKRecordValue

        let decoded = try XCTUnwrap(Household(record: record))
        XCTAssertNil(decoded.listSortMode)
        XCTAssertEqual(decoded.sortMode, .category)
    }

    func testHouseholdApplyCanOmitListSortMode() throws {
        let record = CKRecord(recordType: CK.RecordType.household, recordID: recordID("house"))
        var household = makeHousehold()
        household.listSortMode = .custom

        household.apply(to: record, includeListSortMode: false)
        XCTAssertNil(record[CK.Field.listSortMode])
    }

    func testGroceryItemRoundTripsSortOrder() throws {
        let record = CKRecord(recordType: CK.RecordType.item, recordID: recordID("item"))
        var item = makeItem()
        item.sortOrder = 4096

        item.apply(to: record)
        XCTAssertEqual(record[CK.Field.sortOrder] as? Double, 4096)

        let decoded = try XCTUnwrap(GroceryItem(record: record))
        XCTAssertEqual(decoded.sortOrder, 4096)
    }

    func testGroceryItemApplyCanOmitSortOrder() throws {
        let record = CKRecord(recordType: CK.RecordType.item, recordID: recordID("item"))
        var item = makeItem()
        item.sortOrder = 4096

        item.applyMetadata(to: record, includeSortOrder: false)
        XCTAssertNil(record[CK.Field.sortOrder])
    }

    func testGroceryItemWithoutSortOrderDecodesNil() throws {
        let record = CKRecord(recordType: CK.RecordType.item, recordID: recordID("item"))
        let item = makeItem() // sortOrder defaults to nil

        item.apply(to: record)
        XCTAssertNil(record[CK.Field.sortOrder])

        let decoded = try XCTUnwrap(GroceryItem(record: record))
        XCTAssertNil(decoded.sortOrder)
    }

    /// Minimal valid group for mapping tests.
    private func makeHousehold() -> Household {
        Household(
            id: "house",
            name: "Family",
            ownerMemberId: "owner",
            storeName: "Market",
            icon: "basket.fill",
            colorTheme: .teal,
            createdAt: date,
            updatedAt: date,
            recordZoneName: nil,
            recordOwnerName: nil
        )
    }

    /// Minimal valid item for mapping tests.
    private func makeItem() -> GroceryItem {
        GroceryItem(
            id: "item",
            householdId: "home",
            listId: "list",
            name: "Milk",
            quantity: "1",
            category: .dairy,
            notes: nil,
            requestedByMemberId: "member",
            requestedByDisplayName: "Ray",
            status: .needed,
            priority: .normal,
            replacementPreference: nil,
            replacementItemName: nil,
            createdAt: date,
            updatedAt: date,
            completedAt: nil,
            deletedAt: nil,
            activeSessionId: nil
        )
    }

    func testItemEventMetadataRoundTripsAsData() throws {
        let record = CKRecord(recordType: CK.RecordType.event, recordID: recordID("event"))
        let event = ItemEvent(
            id: "event",
            householdId: "home",
            itemId: "item",
            sessionId: "trip",
            type: .itemReplaced,
            createdByMemberId: "member",
            createdByDisplayName: "Ray",
            createdAt: date,
            metadata: ["name": "Milk", "replacement": "Oat milk"]
        )

        event.apply(to: record)
        let decoded = try XCTUnwrap(ItemEvent(record: record))

        XCTAssertEqual(decoded.type, .itemReplaced)
        XCTAssertEqual(decoded.metadata, ["name": "Milk", "replacement": "Oat milk"])
    }

    func testInvalidRequiredFieldsFailDecodeInsteadOfProducingPartialModels() {
        let record = CKRecord(recordType: CK.RecordType.item, recordID: recordID("item"))
        record[CK.Field.householdId] = "home" as CKRecordValue
        record[CK.Field.listId] = "list" as CKRecordValue
        record[CK.Field.itemName] = "Milk" as CKRecordValue
        record[CK.Field.category] = "Not a Category" as CKRecordValue
        record[CK.Field.status] = ItemStatus.needed.rawValue as CKRecordValue

        XCTAssertNil(GroceryItem(record: record))
    }

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(
            recordName: name,
            zoneID: CKRecordZone.ID(zoneName: CK.householdZoneName, ownerName: CKCurrentUserDefaultName)
        )
    }
}
