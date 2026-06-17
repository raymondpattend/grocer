import XCTest
@testable import Grocer

final class PurchaseIdentityTests: XCTestCase {
    private let keychainUID = "123e4567-e89b-42d3-a456-426614174000"
    private let cloudUID = "223e4567-e89b-42d3-a456-426614174000"
    private let generatedUID = "323e4567-e89b-42d3-a456-426614174000"

    func testKeychainUIDWinsAndMirrorsToCloud() async {
        let keychain = FakePurchaseUIDKeychain(uid: keychainUID.uppercased())
        let cloud = FakePurchaseUIDCloudStore(uid: cloudUID)
        let store = makeStore(keychain: keychain, cloud: cloud)

        let uid = await store.getOrCreateUID()

        XCTAssertEqual(uid, keychainUID)
        XCTAssertEqual(cloud.uid, keychainUID)
        XCTAssertEqual(keychain.savedUIDs, [])
    }

    func testCloudUIDIsAdoptedOnNewDevice() async {
        let keychain = FakePurchaseUIDKeychain(uid: nil)
        let cloud = FakePurchaseUIDCloudStore(uid: cloudUID.uppercased())
        let store = makeStore(keychain: keychain, cloud: cloud)

        let uid = await store.getOrCreateUID()

        XCTAssertEqual(uid, cloudUID)
        XCTAssertEqual(keychain.savedUIDs, [cloudUID])
        XCTAssertEqual(cloud.synchronizeCount, 1)
    }

    func testGeneratedUIDPersistsToKeychainAndCloud() async {
        let keychain = FakePurchaseUIDKeychain(uid: nil)
        let cloud = FakePurchaseUIDCloudStore(uid: nil)
        let store = makeStore(keychain: keychain, cloud: cloud)

        let uid = await store.getOrCreateUID()

        XCTAssertEqual(uid, generatedUID)
        XCTAssertEqual(keychain.savedUIDs, [generatedUID])
        XCTAssertEqual(cloud.uid, generatedUID)
    }

    func testLaterCloudMismatchDoesNotChangeExistingKeychainIdentity() async {
        let keychain = FakePurchaseUIDKeychain(uid: keychainUID)
        let cloud = FakePurchaseUIDCloudStore(uid: cloudUID)
        let store = makeStore(keychain: keychain, cloud: cloud)

        let uid = await store.getOrCreateUID()

        XCTAssertEqual(uid, keychainUID)
        XCTAssertEqual(cloud.uid, keychainUID)
        XCTAssertEqual(keychain.savedUIDs, [])
    }

    private func makeStore(
        keychain: FakePurchaseUIDKeychain,
        cloud: FakePurchaseUIDCloudStore
    ) -> PurchaseUIDStore {
        PurchaseUIDStore(
            keychain: keychain,
            cloud: cloud,
            cloudWaitNanoseconds: 0,
            sleep: { _ in },
            makeUUID: { self.generatedUID }
        )
    }
}

final class BillingPolicyTests: XCTestCase {
    private let uid = "123e4567-e89b-42d3-a456-426614174000"

    func testStorefrontGateUsesRemoteAllowedCodes() {
        XCTAssertTrue(BillingPolicy.canOfferWebCheckout(
            storefrontCountryCode: "usa",
            allowedStorefronts: ["USA"]
        ))
        XCTAssertFalse(BillingPolicy.canOfferWebCheckout(
            storefrontCountryCode: "CAN",
            allowedStorefronts: ["USA"]
        ))
        XCTAssertFalse(BillingPolicy.canOfferWebCheckout(
            storefrontCountryCode: nil,
            allowedStorefronts: ["USA"]
        ))
        XCTAssertTrue(BillingPolicy.canOfferWebCheckout(
            storefrontCountryCode: nil,
            allowedStorefronts: ["USA"],
            debugAllowsMissingStorefront: true
        ))
    }

    func testWebSubscriptionStoreDetection() {
        XCTAssertTrue(BillingPolicy.isWebSubscription(storeIdentifier: "STRIPE"))
        XCTAssertTrue(BillingPolicy.isWebSubscription(storeIdentifier: "RC_BILLING"))
        XCTAssertFalse(BillingPolicy.isWebSubscription(storeIdentifier: "APP_STORE"))
        XCTAssertFalse(BillingPolicy.isWebSubscription(storeIdentifier: "TEST_STORE"))
        XCTAssertFalse(BillingPolicy.isWebSubscription(storeIdentifier: nil))
    }

    func testCheckoutURLIncludesPackageAndPurchaseUID() throws {
        let url = try XCTUnwrap(BillingPolicy.checkoutURL(
            baseURLString: "https://api.grocer.sh",
            purchaseUID: uid,
            packageIdentifier: "$rc_monthly"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "grocer.sh")
        XCTAssertEqual(components.path, "/checkout")
        XCTAssertEqual(components.queryItems?.first { $0.name == "packageId" }?.value, "$rc_monthly")
        XCTAssertEqual(components.queryItems?.first { $0.name == "uid" }?.value, uid)
    }

    func testBillingPortalURLIncludesPurchaseUID() throws {
        let url = try XCTUnwrap(BillingPolicy.billingPortalURL(
            baseURLString: "https://api.grocer.sh",
            purchaseUID: uid
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "api.grocer.sh")
        XCTAssertEqual(components.path, "/api/billing/portal")
        XCTAssertEqual(components.queryItems?.first { $0.name == "uid" }?.value, uid)
    }
}

private final class FakePurchaseUIDKeychain: PurchaseUIDKeychain {
    var uid: String?
    var savedUIDs: [String] = []

    init(uid: String?) {
        self.uid = uid
    }

    func loadPurchaseUID() throws -> String? {
        uid
    }

    func savePurchaseUID(_ uid: String) throws {
        savedUIDs.append(uid)
        self.uid = uid
    }
}

private final class FakePurchaseUIDCloudStore: PurchaseUIDCloudStore {
    var uid: String?
    var synchronizeCount = 0

    init(uid: String?) {
        self.uid = uid
    }

    func synchronize() {
        synchronizeCount += 1
    }

    func purchaseUID() -> String? {
        uid
    }

    func setPurchaseUID(_ uid: String) {
        self.uid = uid
    }
}
