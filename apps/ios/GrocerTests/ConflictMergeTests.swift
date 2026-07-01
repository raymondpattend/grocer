import CloudKit
import XCTest
@testable import Grocer

/// Behavioural tests for the CloudKit `.serverRecordChanged` conflict merge.
/// These exercise `mergeCloudFields` directly on `CKRecord`s, verifying that a
/// field-scoped local write preserves a concurrent editor's independent server
/// fields instead of clobbering them — the P0 the guardrail previously
/// documented as a known gap.
final class ConflictMergeTests: XCTestCase {
    private func itemRecord(_ recordName: String = "item-1") -> CKRecord {
        CKRecord(recordType: CK.RecordType.item, recordID: CKRecord.ID(recordName: recordName))
    }

    func testFieldScopedMergePreservesConcurrentIndependentEdit() {
        // Server carries a partner's concurrent quantity edit; this device only
        // changed shopping status and still holds a *stale* quantity it must not
        // force back onto the server.
        let server = itemRecord()
        server[CK.Field.itemName] = "Milk"
        server[CK.Field.quantity] = "2 gallons" // partner's newer edit
        server[CK.Field.status] = ItemStatus.needed.rawValue

        let local = itemRecord()
        local[CK.Field.itemName] = "Milk"
        local[CK.Field.quantity] = "1 gallon" // stale local value
        local[CK.Field.status] = ItemStatus.found.rawValue

        mergeCloudFields(from: local, changedKeys: [CK.Field.status], onto: server)

        XCTAssertEqual(server[CK.Field.status] as? String, ItemStatus.found.rawValue,
                       "local's status change should win")
        XCTAssertEqual(server[CK.Field.quantity] as? String, "2 gallons",
                       "partner's concurrent quantity edit must survive the merge")
    }

    func testFieldScopedMergeClearsFieldsInsideTheChangedSet() {
        // deletedAt is in the changed set but nil locally → the merge should
        // clear the server's value (e.g. a status reset un-deleting an item).
        let server = itemRecord()
        server[CK.Field.deletedAt] = Date()
        server[CK.Field.status] = ItemStatus.removed.rawValue

        let local = itemRecord()
        local[CK.Field.status] = ItemStatus.needed.rawValue
        // deletedAt intentionally left unset (nil) on the local record.

        mergeCloudFields(from: local, changedKeys: [CK.Field.status, CK.Field.deletedAt], onto: server)

        XCTAssertEqual(server[CK.Field.status] as? String, ItemStatus.needed.rawValue)
        XCTAssertNil(server[CK.Field.deletedAt], "a nil value in the changed set clears the server field")
    }

    func testFieldScopedMergeLeavesUntouchedServerFieldsAlone() {
        // A field neither in the changed set nor on the local record is left
        // exactly as the server had it.
        let server = itemRecord()
        server[CK.Field.notes] = "on sale Tuesday"
        server[CK.Field.status] = ItemStatus.needed.rawValue

        let local = itemRecord()
        local[CK.Field.status] = ItemStatus.skipped.rawValue

        mergeCloudFields(from: local, changedKeys: [CK.Field.status], onto: server)

        XCTAssertEqual(server[CK.Field.notes] as? String, "on sale Tuesday")
        XCTAssertEqual(server[CK.Field.status] as? String, ItemStatus.skipped.rawValue)
    }

    func testNilChangedKeysAppliesEveryPresentLocalField() {
        // The full-record fallback (changedKeys == nil) copies every field
        // present on the local record, matching the pre-merge behaviour used by
        // the direct-save path.
        let server = itemRecord()
        server[CK.Field.quantity] = "2 gallons"
        server[CK.Field.status] = ItemStatus.needed.rawValue

        let local = itemRecord()
        local[CK.Field.quantity] = "1 gallon"
        local[CK.Field.status] = ItemStatus.found.rawValue

        mergeCloudFields(from: local, changedKeys: nil, onto: server)

        XCTAssertEqual(server[CK.Field.quantity] as? String, "1 gallon")
        XCTAssertEqual(server[CK.Field.status] as? String, ItemStatus.found.rawValue)
    }
}
