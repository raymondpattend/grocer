import XCTest
@testable import Grocer

final class ShareInviteLinkTests: XCTestCase {
    private let cloudKitURL = URL(string: "https://www.icloud.com/share/0abc123XYZ#GroceryZone")!

    func testRoundTripPreservesCloudKitURL() throws {
        let branded = try XCTUnwrap(ShareInviteLink.url(
            shareURL: cloudKitURL, groupName: "Home", inviterName: "Ray",
            expiresAt: Date().addingTimeInterval(3600)
        ))
        XCTAssertEqual(branded.host, ShareInviteLink.host)
        XCTAssertEqual(ShareInviteLink.shareURL(from: branded), cloudKitURL)
    }

    func testExpiryRoundTrips() throws {
        // Truncate to whole seconds — the link encodes Unix seconds.
        let expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
        let branded = try XCTUnwrap(ShareInviteLink.url(
            shareURL: cloudKitURL, groupName: nil, inviterName: nil, expiresAt: expiresAt
        ))
        XCTAssertEqual(ShareInviteLink.expiry(from: branded), expiresAt)
    }

    func testIsExpiredWhenPastExp() throws {
        let branded = try XCTUnwrap(ShareInviteLink.url(
            shareURL: cloudKitURL, groupName: nil, inviterName: nil,
            expiresAt: Date(timeIntervalSince1970: 1_000)
        ))
        XCTAssertTrue(ShareInviteLink.isExpired(branded))
    }

    func testIsNotExpiredWhenFutureExp() throws {
        let branded = try XCTUnwrap(ShareInviteLink.url(
            shareURL: cloudKitURL, groupName: nil, inviterName: nil,
            expiresAt: Date().addingTimeInterval(3600)
        ))
        XCTAssertFalse(ShareInviteLink.isExpired(branded))
    }

    func testLinkWithoutExpiryIsNeverExpired() throws {
        // Older links (built before the TTL param) carry no `exp` and must still
        // be accepted.
        let branded = try XCTUnwrap(ShareInviteLink.url(
            shareURL: cloudKitURL, groupName: "Home", inviterName: "Ray"
        ))
        XCTAssertNil(ShareInviteLink.expiry(from: branded))
        XCTAssertFalse(ShareInviteLink.isExpired(branded))
    }

    func testExpiryIgnoresNonShareHosts() {
        let other = URL(string: "https://example.com/abc?exp=1000")!
        XCTAssertNil(ShareInviteLink.expiry(from: other))
        XCTAssertFalse(ShareInviteLink.isExpired(other))
    }
}
