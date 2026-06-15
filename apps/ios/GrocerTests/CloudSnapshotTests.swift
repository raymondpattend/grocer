import CloudKit
import XCTest
@testable import Grocer

final class CloudSnapshotTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testUpsertReplacesRecordsByStableIdAndKeepsUnrelatedRecords() {
        var snapshot = CloudSnapshot(
            items: [
                item(id: "milk", name: "Milk", quantity: "1"),
                item(id: "eggs", name: "Eggs", quantity: "12"),
            ]
        )

        snapshot.upsert(contentsOf: CloudSnapshot(
            items: [
                item(id: "milk", name: "Milk", quantity: "2"),
            ]
        ))

        XCTAssertEqual(snapshot.items.map(\.id), ["milk", "eggs"])
        XCTAssertEqual(snapshot.items.first { $0.id == "milk" }?.quantity, "2")
        XCTAssertEqual(snapshot.items.first { $0.id == "eggs" }?.quantity, "12")
    }

    func testMemberUpsertUsesCompositeMemberHouseholdKey() {
        var snapshot = CloudSnapshot(
            members: [
                member(id: "ray", householdId: "home", displayName: "Ray"),
                member(id: "ray", householdId: "cabin", displayName: "Ray"),
            ]
        )

        snapshot.upsert(contentsOf: CloudSnapshot(
            members: [
                member(id: "ray", householdId: "home", displayName: "Raymond"),
            ]
        ))

        XCTAssertEqual(snapshot.members.count, 2)
        XCTAssertEqual(
            snapshot.members.first { $0.id == "ray" && $0.householdId == "home" }?.displayName,
            "Raymond"
        )
        XCTAssertEqual(
            snapshot.members.first { $0.id == "ray" && $0.householdId == "cabin" }?.displayName,
            "Ray"
        )
    }

    func testHouseholdDeletionCascadesAllHouseholdScopedRecords() {
        var snapshot = CloudSnapshot(
            households: [
                household(id: "home"),
                household(id: "cabin"),
            ],
            members: [
                member(householdId: "home"),
                member(householdId: "cabin"),
            ],
            lists: [
                list(id: "home-list", householdId: "home"),
                list(id: "cabin-list", householdId: "cabin"),
            ],
            items: [
                item(id: "home-item", householdId: "home", listId: "home-list"),
                item(id: "cabin-item", householdId: "cabin", listId: "cabin-list"),
            ],
            sessions: [
                session(id: "home-session", householdId: "home", listId: "home-list"),
                session(id: "cabin-session", householdId: "cabin", listId: "cabin-list"),
            ],
            tripItems: [
                tripItem(id: "home-trip-item", householdId: "home", sessionId: "home-session"),
                tripItem(id: "cabin-trip-item", householdId: "cabin", sessionId: "cabin-session"),
            ],
            events: [
                event(id: "home-event", householdId: "home"),
                event(id: "cabin-event", householdId: "cabin"),
            ]
        )

        snapshot.remove(CloudRecordDeletion(
            recordName: "home",
            recordType: CK.RecordType.household,
            zone: privateZone()
        ))

        XCTAssertEqual(snapshot.households.map(\.id), ["cabin"])
        XCTAssertEqual(snapshot.members.map(\.householdId), ["cabin"])
        XCTAssertEqual(snapshot.lists.map(\.householdId), ["cabin"])
        XCTAssertEqual(snapshot.items.map(\.householdId), ["cabin"])
        XCTAssertEqual(snapshot.sessions.map(\.householdId), ["cabin"])
        XCTAssertEqual(snapshot.tripItems.map(\.householdId), ["cabin"])
        XCTAssertEqual(snapshot.events.map(\.householdId), ["cabin"])
    }

    func testListDeletionCascadesItemsAndSessionsButKeepsHousehold() {
        var snapshot = CloudSnapshot(
            households: [household(id: "home")],
            lists: [
                list(id: "weekly", householdId: "home"),
                list(id: "party", householdId: "home"),
            ],
            items: [
                item(id: "milk", householdId: "home", listId: "weekly"),
                item(id: "chips", householdId: "home", listId: "party"),
            ],
            sessions: [
                session(id: "trip-1", householdId: "home", listId: "weekly"),
                session(id: "trip-2", householdId: "home", listId: "party"),
            ]
        )

        snapshot.remove(CloudRecordDeletion(
            recordName: "weekly",
            recordType: CK.RecordType.list,
            zone: privateZone()
        ))

        XCTAssertEqual(snapshot.households.map(\.id), ["home"])
        XCTAssertEqual(snapshot.lists.map(\.id), ["party"])
        XCTAssertEqual(snapshot.items.map(\.id), ["chips"])
        XCTAssertEqual(snapshot.sessions.map(\.id), ["trip-2"])
    }

    func testSessionDeletionRemovesTripItemHistoryForThatSessionOnly() {
        var snapshot = CloudSnapshot(
            sessions: [
                session(id: "trip-1"),
                session(id: "trip-2"),
            ],
            tripItems: [
                tripItem(id: "trip-1_milk", sessionId: "trip-1"),
                tripItem(id: "trip-2_eggs", sessionId: "trip-2"),
            ]
        )

        snapshot.remove(CloudRecordDeletion(
            recordName: "trip-1",
            recordType: CK.RecordType.session,
            zone: privateZone()
        ))

        XCTAssertEqual(snapshot.sessions.map(\.id), ["trip-2"])
        XCTAssertEqual(snapshot.tripItems.map(\.id), ["trip-2_eggs"])
    }

    func testFullZoneRefetchRemovesOnlyRecordsFromThatZone() {
        let ownedZone = privateZone()
        let sharedZone = CloudZoneRef(scope: "shared", zoneName: CK.householdZoneName, ownerName: "_sharedOwner")
        var snapshot = CloudSnapshot(
            households: [
                household(id: "owned", ownerName: CKCurrentUserDefaultName),
                household(id: "joined", ownerName: "_sharedOwner"),
            ],
            lists: [
                list(id: "owned-list", householdId: "owned"),
                list(id: "joined-list", householdId: "joined"),
            ],
            items: [
                item(id: "old-owned-item", householdId: "owned", listId: "owned-list"),
                item(id: "joined-item", householdId: "joined", listId: "joined-list"),
            ]
        )

        snapshot.removeRecords(in: [ownedZone])
        snapshot.upsert(contentsOf: CloudSnapshot(
            households: [household(id: "owned", name: "Owned Fresh", ownerName: CKCurrentUserDefaultName)],
            lists: [list(id: "owned-list", householdId: "owned")],
            items: [item(id: "fresh-owned-item", householdId: "owned", listId: "owned-list")]
        ))

        XCTAssertEqual(Set(snapshot.households.map(\.id)), ["owned", "joined"])
        XCTAssertEqual(Set(snapshot.items.map(\.id)), ["fresh-owned-item", "joined-item"])
        XCTAssertTrue(snapshot.householdIds(in: [sharedZone]).contains("joined"))
    }

    func testRemoveRecordsInSharedZoneDropsChildrenEvenWhenOnlyHouseholdHasZoneMetadata() {
        let sharedZone = CloudZoneRef(scope: "shared", zoneName: CK.householdZoneName, ownerName: "_sharedOwner")
        var snapshot = CloudSnapshot(
            households: [
                household(id: "joined", ownerName: "_sharedOwner"),
            ],
            members: [
                member(householdId: "joined"),
            ],
            lists: [
                list(id: "joined-list", householdId: "joined"),
            ],
            items: [
                item(id: "joined-item", householdId: "joined", listId: "joined-list"),
            ],
            sessions: [
                session(id: "joined-session", householdId: "joined", listId: "joined-list"),
            ],
            tripItems: [
                tripItem(id: "joined-trip-item", householdId: "joined", sessionId: "joined-session"),
            ],
            events: [
                event(id: "joined-event", householdId: "joined"),
            ]
        )

        snapshot.removeRecords(in: [sharedZone])

        XCTAssertTrue(snapshot.households.isEmpty)
        XCTAssertTrue(snapshot.members.isEmpty)
        XCTAssertTrue(snapshot.lists.isEmpty)
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertTrue(snapshot.sessions.isEmpty)
        XCTAssertTrue(snapshot.tripItems.isEmpty)
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    private func privateZone() -> CloudZoneRef {
        CloudZoneRef(scope: "private", zoneName: CK.householdZoneName, ownerName: CKCurrentUserDefaultName)
    }

    private func household(
        id: String = "home",
        name: String = "Home",
        ownerMemberId: String = "owner",
        ownerName: String = CKCurrentUserDefaultName
    ) -> Household {
        Household(
            id: id,
            name: name,
            ownerMemberId: ownerMemberId,
            storeName: nil,
            icon: "cart.fill",
            colorTheme: .green,
            createdAt: baseDate,
            updatedAt: baseDate,
            recordZoneName: CK.householdZoneName,
            recordOwnerName: ownerName
        )
    }

    private func member(
        id: String = "member",
        householdId: String = "home",
        displayName: String = "Member",
        role: MemberRole = .member
    ) -> HouseholdMember {
        HouseholdMember(
            id: id,
            householdId: householdId,
            displayName: displayName,
            profileImageData: nil,
            iCloudUserRecordName: id,
            role: role,
            joinedAt: baseDate,
            recordZoneName: CK.householdZoneName,
            recordOwnerName: CKCurrentUserDefaultName
        )
    }

    private func list(
        id: String = "list",
        householdId: String = "home"
    ) -> GroceryList {
        GroceryList(
            id: id,
            householdId: householdId,
            name: DEFAULT_LIST_NAME,
            createdAt: baseDate,
            updatedAt: baseDate,
            archived: false
        )
    }

    private func item(
        id: String = "item",
        householdId: String = "home",
        listId: String = "list",
        name: String = "Milk",
        quantity: String? = nil,
        status: ItemStatus = .needed
    ) -> GroceryItem {
        GroceryItem(
            id: id,
            householdId: householdId,
            listId: listId,
            name: name,
            quantity: quantity,
            category: .dairy,
            notes: nil,
            requestedByMemberId: "member",
            requestedByDisplayName: "Member",
            status: status,
            priority: .normal,
            replacementPreference: nil,
            replacementItemName: nil,
            createdAt: baseDate,
            updatedAt: baseDate,
            completedAt: nil,
            deletedAt: nil,
            activeSessionId: nil
        )
    }

    private func session(
        id: String = "session",
        householdId: String = "home",
        listId: String = "list",
        status: SessionStatus = .active
    ) -> ShoppingSession {
        ShoppingSession(
            id: id,
            householdId: householdId,
            listId: listId,
            startedByMemberId: "member",
            startedByDisplayName: "Member",
            storeName: nil,
            startedAt: baseDate,
            endedAt: nil,
            updatedAt: baseDate,
            status: status
        )
    }

    private func tripItem(
        id: String = "session_item",
        householdId: String = "home",
        sessionId: String = "session"
    ) -> ShoppingTripItem {
        ShoppingTripItem(
            id: id,
            householdId: householdId,
            sessionId: sessionId,
            itemId: "item",
            name: "Milk",
            quantity: nil,
            category: .dairy,
            outcome: .found,
            replacementItemName: nil,
            requestedByMemberId: "member",
            requestedByDisplayName: "Member",
            createdAt: baseDate
        )
    }

    private func event(
        id: String = "event",
        householdId: String = "home"
    ) -> ItemEvent {
        ItemEvent(
            id: id,
            householdId: householdId,
            itemId: nil,
            sessionId: nil,
            type: .itemAdded,
            createdByMemberId: "member",
            createdByDisplayName: "Member",
            createdAt: baseDate,
            metadata: [:]
        )
    }
}
