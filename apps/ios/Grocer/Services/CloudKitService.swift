import CloudKit
import Foundation
import UIKit

/// CloudKit data layer. CloudKit is the source of truth for all grocery data.
///
/// Storage model:
///  - The household owner writes all shared records into a **custom zone**
///    ("HouseholdZone") in their **private** database. The Household record is
///    the share root.
///  - Family members who accept the `CKShare` see that zone in their
///    **shared** database.
///  - So reads must check BOTH the private database (if you're the owner) and
///    the shared database (if you're a participant).
///
/// Resilience: `CKContainer(identifier:)` *traps* (uncatchable) if the iCloud
/// container isn't present in the app's active entitlements. iOS has no public
/// API to read your own entitlements at runtime, so we gate CloudKit behind an
/// Info.plist flag (`GRCloudKitEnabled`, driven by the `GR_CLOUDKIT_ENABLED`
/// build setting, default YES). Normal signed builds ship with the iCloud
/// capability + container and run against CloudKit. To run UI-only / local mode
/// (e.g. an unsigned build with no entitlements), build with
/// `GR_CLOUDKIT_ENABLED=NO`; `container` is then nil and the repository falls
/// back to local sample data instead of crashing.
final class CloudKitService {
    static let shared = CloudKitService()

    let container: CKContainer?
    private let zoneID: CKRecordZone.ID

    var isAvailable: Bool { container != nil }
    private var privateDB: CKDatabase? { container?.privateCloudDatabase }
    private var sharedDB: CKDatabase? { container?.sharedCloudDatabase }

    init(containerIdentifier: String = CK.containerIdentifier) {
        if Self.cloudKitEnabledInBuild {
            container = CKContainer(identifier: containerIdentifier)
            print("[CK] ✅ container created: \(containerIdentifier)")
        } else {
            print("[CK] ⛔ disabled for this build (GRCloudKitEnabled=NO)")
            container = nil
        }
        zoneID = CKRecordZone.ID(zoneName: CK.householdZoneName, ownerName: CKCurrentUserDefaultName)
    }

    private static var cloudKitEnabledInBuild: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GRCloudKitEnabled") else {
            return true
        }
        if let flag = value as? Bool { return flag }
        if let str = value as? String { return (str as NSString).boolValue }
        return true
    }

    // MARK: - Account & setup

    func accountStatus() async -> CKAccountStatus {
        guard let container else {
            print("[CK] accountStatus → container is nil")
            return .couldNotDetermine
        }
        do {
            let status = try await container.accountStatus()
            print("[CK] accountStatus → \(Self.describeAccountStatus(status))")
            return status
        } catch {
            print("[CK] ❌ accountStatus threw: \(error)")
            return .couldNotDetermine
        }
    }

    func ensureZone() async throws {
        guard let privateDB else {
            print("[CK] ❌ ensureZone: no privateDB")
            throw CloudKitUnavailable()
        }
        print("[CK] ensureZone → creating zone \(zoneID.zoneName)…")
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            _ = try await privateDB.modifyRecordZones(saving: [zone], deleting: [])
            print("[CK] ✅ ensureZone succeeded")
        } catch {
            print("[CK] ❌ ensureZone failed: \(error)")
            throw error
        }
    }

    func currentUserRecordName() async -> String? {
        guard let container else {
            print("[CK] currentUserRecordName → container is nil")
            return nil
        }
        do {
            let recordID = try await container.userRecordID()
            print("[CK] currentUserRecordName → \(recordID.recordName)")
            return recordID.recordName
        } catch {
            print("[CK] ❌ currentUserRecordName threw: \(error)")
            return nil
        }
    }

    // MARK: - Fetch

    func fetchSnapshot() async throws -> CloudSnapshot {
        var snapshot = CloudSnapshot()
        print("[CK] fetchSnapshot starting…")
        if let privateDB {
            print("[CK]   fetching from private DB, zone: \(zoneID)")
            try await accumulate(from: privateDB, into: &snapshot, scope: [zoneID], label: "private")
        } else {
            print("[CK]   ⚠️ no privateDB, skipping")
        }
        if let sharedDB {
            let zones = (try? await sharedDB.allRecordZones())?.map(\.zoneID) ?? []
            print("[CK]   fetching from shared DB, \(zones.count) zone(s): \(zones.map(\.zoneName))")
            try await accumulate(from: sharedDB, into: &snapshot, scope: zones, label: "shared")
        } else {
            print("[CK]   ⚠️ no sharedDB, skipping")
        }
        print("[CK] ✅ fetchSnapshot done — \(snapshot.households.count) households, \(snapshot.members.count) members, \(snapshot.lists.count) lists, \(snapshot.items.count) items")
        return snapshot
    }

    private func accumulate(from db: CKDatabase, into snapshot: inout CloudSnapshot, scope zones: [CKRecordZone.ID], label: String) async throws {
        for zone in zones {
            do {
                var changeToken: CKServerChangeToken?
                var moreComing = true
                var totalRecords = 0
                while moreComing {
                    let changes = try await db.recordZoneChanges(inZoneWith: zone, since: changeToken)
                    for (recordID, result) in changes.modificationResultsByID {
                        switch result {
                        case .success(let modification):
                            snapshot.absorb(modification.record)
                            totalRecords += 1
                        case .failure(let error):
                            print("[CK]   ⚠️ [\(label)] record \(recordID.recordName) change failed: \(error)")
                        }
                    }
                    if !changes.deletions.isEmpty {
                        print("[CK]   [\(label)] zone \(zone.zoneName): \(changes.deletions.count) deletions")
                    }
                    changeToken = changes.changeToken
                    moreComing = changes.moreComing
                }
                print("[CK]   [\(label)] zone \(zone.zoneName): fetched \(totalRecords) record(s)")
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                print("[CK]   [\(label)] zone \(zone.zoneName): not found (empty, continuing)")
                continue
            } catch let error as CKError where error.code == .changeTokenExpired {
                print("[CK]   [\(label)] zone \(zone.zoneName): change token expired, retrying from nil…")
                var moreComing = true
                var totalRecords = 0
                while moreComing {
                    let changes = try await db.recordZoneChanges(inZoneWith: zone, since: nil)
                    for (_, result) in changes.modificationResultsByID {
                        if case .success(let modification) = result {
                            snapshot.absorb(modification.record)
                            totalRecords += 1
                        }
                    }
                    moreComing = changes.moreComing
                }
                print("[CK]   [\(label)] zone \(zone.zoneName): refetched \(totalRecords) record(s)")
            } catch {
                print("[CK]   ❌ [\(label)] zone \(zone.zoneName) fetch error: \(error)")
                throw error
            }
        }
    }

    // MARK: - Save / delete

    func save(_ record: CKRecord) async throws {
        let db = database(for: record.recordID.zoneID)
        let dbLabel = record.recordID.zoneID.ownerName == CKCurrentUserDefaultName ? "private" : "shared"
        guard let db else {
            print("[CK] ❌ save: no DB for zone \(record.recordID.zoneID) (owner=\(record.recordID.zoneID.ownerName))")
            throw CloudKitUnavailable()
        }
        print("[CK] save → \(record.recordType) \(record.recordID.recordName) to \(dbLabel) DB")
        let (saveResults, _) = try await db.modifyRecords(saving: [record], deleting: [])
        for (id, result) in saveResults {
            switch result {
            case .success:
                print("[CK] ✅ saved \(record.recordType) \(id.recordName)")
            case .failure(let error):
                print("[CK] ❌ save failed for \(record.recordType) \(id.recordName): \(error)")
                throw error
            }
        }
    }

    func save(_ records: [CKRecord]) async throws {
        guard let first = records.first else { return }
        let db = database(for: first.recordID.zoneID)
        guard let db else {
            print("[CK] ❌ save(batch): no DB for zone \(first.recordID.zoneID)")
            throw CloudKitUnavailable()
        }
        let types = records.map { "\($0.recordType)(\($0.recordID.recordName.prefix(8))…)" }.joined(separator: ", ")
        print("[CK] save(batch) → \(records.count) records: \(types)")
        let (saveResults, _) = try await db.modifyRecords(saving: records, deleting: [])
        var errors: [Error] = []
        for (id, result) in saveResults {
            switch result {
            case .success:
                print("[CK] ✅ saved \(id.recordName)")
            case .failure(let error):
                print("[CK] ❌ save failed for \(id.recordName): \(error)")
                errors.append(error)
            }
        }
        if let first = errors.first { throw first }
    }

    func saveToPrivateZone(_ records: [CKRecord]) async throws -> [CKRecord.ID: CKRecord] {
        guard let privateDB else {
            print("[CK] ❌ saveToPrivateZone: no privateDB")
            throw CloudKitUnavailable()
        }
        let types = records.map { "\($0.recordType)(\($0.recordID.recordName.prefix(8))…)" }.joined(separator: ", ")
        print("[CK] saveToPrivateZone → \(records.count) records: \(types)")
        let (saveResults, _) = try await privateDB.modifyRecords(saving: records, deleting: [])
        var saved: [CKRecord.ID: CKRecord] = [:]
        var errors: [Error] = []
        for (id, result) in saveResults {
            switch result {
            case .success(let record):
                saved[id] = record
                print("[CK] ✅ saved to private: \(record.recordType) \(id.recordName)")
            case .failure(let error):
                print("[CK] ❌ save to private failed for \(id.recordName): \(error)")
                errors.append(error)
            }
        }
        if let first = errors.first { throw first }
        return saved
    }

    func delete(recordID: CKRecord.ID) async throws {
        guard let db = database(for: recordID.zoneID) else {
            print("[CK] ❌ delete: no DB for zone \(recordID.zoneID)")
            throw CloudKitUnavailable()
        }
        print("[CK] delete → \(recordID.recordName)")
        _ = try await db.modifyRecords(saving: [], deleting: [recordID])
        print("[CK] ✅ deleted \(recordID.recordName)")
    }

    func record(for recordID: CKRecord.ID) async throws -> CKRecord {
        guard let db = database(for: recordID.zoneID) else {
            print("[CK] ❌ record(for:): no DB for zone \(recordID.zoneID)")
            throw CloudKitUnavailable()
        }
        print("[CK] record(for:) → \(recordID.recordName) in zone \(recordID.zoneID.zoneName):\(recordID.zoneID.ownerName)")
        let r = try await db.record(for: recordID)
        print("[CK] ✅ fetched \(r.recordType) \(recordID.recordName)")
        return r
    }

    private func database(for zoneID: CKRecordZone.ID) -> CKDatabase? {
        zoneID.ownerName == CKCurrentUserDefaultName ? privateDB : sharedDB
    }

    func makeRecordID(_ name: String = UUID().uuidString) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    /// The local (owned) household zone in this user's private database. Records
    /// for groups the user owns live here; records for groups they joined live
    /// in the owner's zone, accessed via the shared database.
    var localZoneID: CKRecordZone.ID { zoneID }

    func privateRecord(id: CKRecord.ID) async throws -> CKRecord {
        guard let privateDB else { throw CloudKitUnavailable() }
        return try await privateDB.record(for: id)
    }

    func accept(_ metadata: CKShare.Metadata) async throws {
        guard let container else { throw CloudKitUnavailable() }
        _ = try await container.accept(metadata)
    }

    // MARK: - Sharing

    func share(for householdRecord: CKRecord) async throws -> CKShare {
        guard let privateDB else { throw CloudKitUnavailable() }
        print("[CK] share(for:) → household \(householdRecord.recordID.recordName)")
        if let ref = householdRecord.share,
           let existing = try? await privateDB.record(for: ref.recordID) as? CKShare {
            existing.publicPermission = .none
            print("[CK] ✅ reusing existing CKShare")
            return try await saveShare(existing)
        }
        let share = CKShare(rootRecord: householdRecord)
        share[CKShare.SystemFieldKey.title] = householdRecord[CK.Field.name] as? String ?? "Family Groceries"
        share.publicPermission = .none
        if let iconData = Self.appIconPNGData() {
            share[CKShare.SystemFieldKey.thumbnailImageData] = iconData as CKRecordValue
        }
        print("[CK] creating new CKShare for household…")
        let (saveResults, _) = try await privateDB.modifyRecords(saving: [householdRecord, share], deleting: [])
        for (id, result) in saveResults {
            switch result {
            case .success:
                print("[CK] ✅ share save OK: \(id.recordName)")
            case .failure(let error):
                print("[CK] ❌ share save failed: \(id.recordName): \(error)")
                throw error
            }
        }
        if case .success(let savedShare) = saveResults[share.recordID], let savedShare = savedShare as? CKShare {
            return savedShare
        }
        return share
    }

    @available(iOS 26.0, *)
    func oneTimeInviteURL(for householdRecord: CKRecord) async throws -> URL {
        let share = try await share(for: householdRecord)
        share.publicPermission = .none

        let participant = CKShare.Participant.oneTimeURLParticipant()
        participant.permission = .readWrite
        share.addParticipant(participant)

        let savedShare = try await saveShare(share)
        guard let url = savedShare.oneTimeURL(for: participant.participantID) else {
            throw CloudInviteURLUnavailable()
        }
        print("[CK] ✅ one-time invite URL created for participant \(participant.participantID)")
        return url
    }

    func revokeParticipant(
        matching recordNames: Set<String>,
        from householdRecordID: CKRecord.ID
    ) async throws -> Bool {
        guard let privateDB else { throw CloudKitUnavailable() }
        let householdRecord = try await privateDB.record(for: householdRecordID)
        guard let shareRef = householdRecord.share,
              let share = try await privateDB.record(for: shareRef.recordID) as? CKShare else {
            print("[CK] revokeParticipant: household has no share")
            return false
        }

        share.publicPermission = .none
        let normalizedTargets = Set(recordNames.flatMap { [$0, Self.sanitizeUserRecordName($0)] })
        let participants = share.participants.filter { participant in
            guard participant.role != .owner else { return false }
            guard let recordName = participant.userIdentity.userRecordID?.recordName else { return false }
            return normalizedTargets.contains(recordName)
                || normalizedTargets.contains(Self.sanitizeUserRecordName(recordName))
        }

        guard !participants.isEmpty else {
            print("[CK] revokeParticipant: no matching CKShare participant found")
            _ = try await saveShare(share)
            return false
        }

        for participant in participants {
            print("[CK] revokeParticipant → removing \(participant.userIdentity.userRecordID?.recordName ?? "unknown")")
            share.removeParticipant(participant)
        }
        _ = try await saveShare(share)
        return true
    }

    @discardableResult
    private func saveShare(_ share: CKShare) async throws -> CKShare {
        guard let privateDB else { throw CloudKitUnavailable() }
        let (saveResults, _) = try await privateDB.modifyRecords(saving: [share], deleting: [])
        for (id, result) in saveResults {
            switch result {
            case .success:
                print("[CK] ✅ share saved: \(id.recordName)")
            case .failure(let error):
                print("[CK] ❌ share save failed: \(id.recordName): \(error)")
                throw error
            }
        }
        if case .success(let savedShare) = saveResults[share.recordID], let savedShare = savedShare as? CKShare {
            return savedShare
        }
        return share
    }

    private static func sanitizeUserRecordName(_ name: String) -> String {
        var s = name
        while s.hasPrefix("_") { s = String(s.dropFirst()) }
        return s
    }

    // MARK: - Subscriptions (real-time sync)

    private static let subscriptionRegistrationVersion = 2
    private static let privateZoneSubscriptionID = "grocer-household-zone-sub"
    private static let sharedDatabaseSubscriptionID = "grocer-shared-db-sub"
    private static let subscriptionsRegisteredKey = "grocer.cloudkit.subscriptionsRegistered"
    private static let subscriptionsRegisteredVersionKey = "grocer.cloudkit.subscriptionsRegisteredVersion"

    /// Registers CloudKit push subscriptions so record changes wake the app for a refresh.
    /// Idempotent — skips only after this version has registered both scopes successfully.
    func registerSubscriptions(force: Bool = false) async -> CloudSubscriptionRegistrationResult {
        guard let privateDB, let sharedDB else {
            print("[CK] registerSubscriptions skipped (CloudKit unavailable)")
            return CloudSubscriptionRegistrationResult(
                privateZoneRegistered: false,
                sharedDatabaseRegistered: false,
                errors: ["CloudKit unavailable"]
            )
        }
        let registeredVersion = UserDefaults.standard.integer(forKey: Self.subscriptionsRegisteredVersionKey)
        if !force, registeredVersion >= Self.subscriptionRegistrationVersion {
            print("[CK] registerSubscriptions skipped (already registered)")
            await registerForRemoteNotifications()
            return CloudSubscriptionRegistrationResult(
                privateZoneRegistered: true,
                sharedDatabaseRegistered: true,
                errors: []
            )
        }

        print("[CK] registerSubscriptions → creating zone + shared DB subscriptions…")

        let zoneSub = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.privateZoneSubscriptionID)
        let zoneInfo = CKSubscription.NotificationInfo()
        zoneInfo.shouldSendContentAvailable = true
        zoneSub.notificationInfo = zoneInfo

        let sharedSub = CKDatabaseSubscription(subscriptionID: Self.sharedDatabaseSubscriptionID)
        let sharedInfo = CKSubscription.NotificationInfo()
        sharedInfo.shouldSendContentAvailable = true
        sharedSub.notificationInfo = sharedInfo

        var privateZoneRegistered = false
        var sharedDatabaseRegistered = false
        var errors: [String] = []

        do {
            let (saveResults, _) = try await privateDB.modifySubscriptions(saving: [zoneSub], deleting: [])
            try Self.validateSubscriptionSaveResults(saveResults, context: "private zone")
            privateZoneRegistered = true
            print("[CK] ✅ private zone subscription registered")
        } catch {
            print("[CK] ❌ private zone subscription failed: \(error)")
            errors.append("Private zone: \(Self.describe(error))")
        }

        do {
            let (saveResults, _) = try await sharedDB.modifySubscriptions(saving: [sharedSub], deleting: [])
            try Self.validateSubscriptionSaveResults(saveResults, context: "shared database")
            sharedDatabaseRegistered = true
            print("[CK] ✅ shared database subscription registered")
        } catch {
            print("[CK] ❌ shared database subscription failed: \(error)")
            errors.append("Shared DB: \(Self.describe(error))")
        }

        if privateZoneRegistered && sharedDatabaseRegistered {
            UserDefaults.standard.set(true, forKey: Self.subscriptionsRegisteredKey)
            UserDefaults.standard.set(Self.subscriptionRegistrationVersion, forKey: Self.subscriptionsRegisteredVersionKey)
        } else {
            UserDefaults.standard.set(false, forKey: Self.subscriptionsRegisteredKey)
            UserDefaults.standard.removeObject(forKey: Self.subscriptionsRegisteredVersionKey)
        }

        await registerForRemoteNotifications()
        return CloudSubscriptionRegistrationResult(
            privateZoneRegistered: privateZoneRegistered,
            sharedDatabaseRegistered: sharedDatabaseRegistered,
            errors: errors
        )
    }

    func clearSubscriptionRegistrationFlag() {
        UserDefaults.standard.set(false, forKey: Self.subscriptionsRegisteredKey)
        UserDefaults.standard.removeObject(forKey: Self.subscriptionsRegisteredVersionKey)
    }

    private func registerForRemoteNotifications() async {
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    private static func validateSubscriptionSaveResults(
        _ results: [CKSubscription.ID: Result<CKSubscription, Error>],
        context: String
    ) throws {
        for (id, result) in results {
            if case .failure(let error) = result {
                print("[CK] ❌ \(context) subscription \(id) failed: \(error)")
                throw error
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let ck = error as? CKError {
            return "CKError.\(ck.code.rawValue): \(ck.localizedDescription)"
        }
        return error.localizedDescription
    }

    // MARK: - Zone management

    func deleteZone() async throws {
        guard let privateDB else {
            print("[CK] ❌ deleteZone: no privateDB")
            throw CloudKitUnavailable()
        }
        print("[CK] deleteZone → deleting zone \(zoneID.zoneName)…")
        _ = try await privateDB.modifyRecordZones(saving: [], deleting: [zoneID])
        print("[CK] ✅ deleteZone succeeded — all records in zone removed")
    }

    // MARK: - Debug helpers

    static func appIconPNGData() -> Data? {
        guard let icon = UIImage(named: "AppIcon") ?? UIImage(named: "AppIcon60x60") else { return nil }
        return icon.pngData()
    }

    private static func describeAccountStatus(_ s: CKAccountStatus) -> String {
        switch s {
        case .available: return "available"
        case .noAccount: return "noAccount"
        case .restricted: return "restricted"
        case .couldNotDetermine: return "couldNotDetermine"
        case .temporarilyUnavailable: return "temporarilyUnavailable"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }
}

struct CloudKitUnavailable: LocalizedError {
    var errorDescription: String? { "iCloud is not available on this device." }
}

struct CloudInviteURLUnavailable: LocalizedError {
    var errorDescription: String? {
        "CloudKit couldn't create an invite link for this group. Please try inviting again."
    }
}

struct CloudSubscriptionRegistrationResult: Equatable {
    var privateZoneRegistered: Bool
    var sharedDatabaseRegistered: Bool
    var errors: [String]

    var isFullyRegistered: Bool {
        privateZoneRegistered && sharedDatabaseRegistered
    }

    var statusText: String {
        if isFullyRegistered { return "Subscribed" }
        if errors.isEmpty { return "Not subscribed" }
        return errors.joined(separator: " · ")
    }
}

/// Accumulated records from a CloudKit fetch, decoded into domain models.
struct CloudSnapshot {
    var households: [Household] = []
    var members: [HouseholdMember] = []
    var lists: [GroceryList] = []
    var items: [GroceryItem] = []
    var sessions: [ShoppingSession] = []
    var events: [ItemEvent] = []

    mutating func absorb(_ record: CKRecord) {
        switch record.recordType {
        case CK.RecordType.household:
            if let v = Household(record: record) { households.append(v) }
            else { print("[CK] ⚠️ failed to decode Household from \(record.recordID.recordName), keys: \(record.allKeys())") }
        case CK.RecordType.member:
            if let v = HouseholdMember(record: record) { members.append(v) }
            else { print("[CK] ⚠️ failed to decode HouseholdMember from \(record.recordID.recordName), keys: \(record.allKeys())") }
        case CK.RecordType.list:
            if let v = GroceryList(record: record) { lists.append(v) }
            else { print("[CK] ⚠️ failed to decode GroceryList from \(record.recordID.recordName), keys: \(record.allKeys())") }
        case CK.RecordType.item:
            if let v = GroceryItem(record: record) { items.append(v) }
            else { print("[CK] ⚠️ failed to decode GroceryItem from \(record.recordID.recordName), keys: \(record.allKeys())") }
        case CK.RecordType.session:
            if let v = ShoppingSession(record: record) { sessions.append(v) }
            else { print("[CK] ⚠️ failed to decode ShoppingSession from \(record.recordID.recordName), keys: \(record.allKeys())") }
        case CK.RecordType.event:
            if let v = ItemEvent(record: record) { events.append(v) }
            else { print("[CK] ⚠️ failed to decode ItemEvent from \(record.recordID.recordName), keys: \(record.allKeys())") }
        default:
            print("[CK] ⚠️ unknown record type: \(record.recordType) (\(record.recordID.recordName))")
        }
    }
}
