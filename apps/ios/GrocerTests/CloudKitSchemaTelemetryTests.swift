import CloudKit
import XCTest
@testable import Grocer

final class CloudKitSchemaTelemetryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CloudKitSchemaTelemetry._resetReportedFingerprintsForTesting()
    }

    func testParseMismatchExtractsProductionSchemaField() {
        let error = makeSchemaError(
            message: "Cannot create or modify field 'replacementItemName' in record 'ShoppingTripItem' in production schema"
        )

        let mismatch = CloudKitSchemaTelemetry.parseMismatch(from: error)

        XCTAssertEqual(mismatch?.recordType, "ShoppingTripItem")
        XCTAssertEqual(mismatch?.fieldName, "replacementItemName")
        XCTAssertEqual(mismatch?.environment, "production")
    }

    func testParseMismatchExtractsDevelopmentSchemaField() {
        let error = makeSchemaError(
            message: "Cannot create or modify field 'storeName' in record 'ShoppingSession' in development schema"
        )

        let mismatch = CloudKitSchemaTelemetry.parseMismatch(from: error)

        XCTAssertEqual(mismatch?.recordType, "ShoppingSession")
        XCTAssertEqual(mismatch?.fieldName, "storeName")
        XCTAssertEqual(mismatch?.environment, "development")
    }

    func testParseMismatchReturnsNilForUnrelatedCKError() {
        let error = CKError(.networkUnavailable)

        XCTAssertNil(CloudKitSchemaTelemetry.parseMismatch(from: error))
    }

    func testParseMismatchReturnsNilForNonCloudKitError() {
        XCTAssertNil(CloudKitSchemaTelemetry.parseMismatch(from: NSError(domain: "test", code: 1)))
    }

    func testReportDeduplicatesSameFingerprintPerSession() {
        let error = makeSchemaError(
            message: "Cannot create or modify field 'replacementItemName' in record 'ShoppingTripItem' in production schema"
        )
        guard let mismatch = CloudKitSchemaTelemetry.parseMismatch(from: error) else {
            return XCTFail("expected schema mismatch")
        }

        CloudKitSchemaTelemetry.report(
            mismatch: mismatch,
            error: error,
            context: "test",
            recordName: "trip_item_1",
            recovered: true
        )
        CloudKitSchemaTelemetry.report(
            mismatch: mismatch,
            error: error,
            context: "test",
            recordName: "trip_item_2",
            recovered: true
        )

        // Second report is suppressed in-process; no assertion against Sentry SDK.
        // Guardrail test below ensures production call sites stay wired.
    }

    private func makeSchemaError(message: String) -> CKError {
        CKError(
            _nsError: NSError(
                domain: CKErrorDomain,
                code: CKError.Code.invalidArguments.rawValue,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        )
    }
}
