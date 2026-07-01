import CloudKit
import Foundation

// Outbox + local-persistence layer extracted from GroceryRepository.
// PendingCloud* model the durable CloudKit write queue; LocalSyncStore is
// the on-disk snapshot/outbox cache the repository loads on launch and
// flushes to for durability. Kept together as one cohesive unit.

enum PendingCloudOperation: String, Codable {
    case save
    case delete
}

enum PendingCloudRecord: Codable, Equatable {
    case household(Household)
    case member(HouseholdMember)
    case list(GroceryList)
    case item(GroceryItem)
    case session(ShoppingSession)
    case tripItem(ShoppingTripItem)
    case event(ItemEvent)

    var recordType: String {
        switch self {
        case .household: return CK.RecordType.household
        case .member: return CK.RecordType.member
        case .list: return CK.RecordType.list
        case .item: return CK.RecordType.item
        case .session: return CK.RecordType.session
        case .tripItem: return CK.RecordType.tripItem
        case .event: return CK.RecordType.event
        }
    }

    var recordName: String {
        switch self {
        case .household(let value): return value.id
        case .member(let value): return "\(value.id)_\(value.householdId)"
        case .list(let value): return value.id
        case .item(let value): return value.id
        case .session(let value): return value.id
        case .tripItem(let value): return value.id
        case .event(let value): return value.id
        }
    }

    var householdId: String? {
        switch self {
        case .household(let value): return value.id
        case .member(let value): return value.householdId
        case .list(let value): return value.householdId
        case .item(let value): return value.householdId
        case .session(let value): return value.householdId
        case .tripItem(let value): return value.householdId
        case .event(let value): return value.householdId
        }
    }

    var key: String {
        "\(recordType):\(recordName):\(householdId ?? "")"
    }

    var snapshot: CloudSnapshot {
        var snapshot = CloudSnapshot()
        switch self {
        case .household(let value): snapshot.households = [value]
        case .member(let value): snapshot.members = [value]
        case .list(let value): snapshot.lists = [value]
        case .item(let value): snapshot.items = [value]
        case .session(let value): snapshot.sessions = [value]
        case .tripItem(let value): snapshot.tripItems = [value]
        case .event(let value): snapshot.events = [value]
        }
        return snapshot
    }

    var deletion: CloudRecordDeletion {
        CloudRecordDeletion(
            recordName: recordName,
            recordType: recordType,
            zone: CloudZoneRef(scope: "local", zoneName: "", ownerName: "")
        )
    }

    func apply(to record: CKRecord) {
        switch self {
        case .household(let value): value.apply(to: record)
        case .member(let value): value.apply(to: record)
        case .list(let value): value.apply(to: record)
        case .item(let value): value.apply(to: record)
        case .session(let value): value.apply(to: record)
        case .tripItem(let value): value.apply(to: record)
        case .event(let value): value.apply(to: record)
        }
    }
}

struct PendingCloudWrite: Codable, Equatable {
    var operation: PendingCloudOperation
    var record: PendingCloudRecord
    var revision: Int
    var enqueuedAt: Date
    var failureCount: Int? = nil
    var retryAfter: Date? = nil
    var lastError: String? = nil
    /// The CloudKit field keys this device actually modified, when known. On a
    /// `.serverRecordChanged` conflict the merge writes *only* these keys onto
    /// the server record, so a concurrent editor's edits to other (independent)
    /// fields survive. `nil` means "all of the record's fields" — the
    /// conservative default that matches the pre-merge full-record behaviour.
    /// Optional so older persisted outboxes (which lack the key) still decode.
    var changedKeys: Set<String>? = nil

    var key: String { record.key }
}

final class LocalSyncStore {
    private let fileManager = FileManager.default
    private let snapshotURL: URL
    private let outboxURL: URL
    private let systemFieldsURL: URL
    private let queue = DispatchQueue(label: "org.narro.grocer.local-sync-store", qos: .utility)

    init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let root = base.appendingPathComponent("GrocerSync", isDirectory: true)
        // Scope the cache per CloudKit environment so Development and Production
        // data never mix on the same device.
        let directory = root.appendingPathComponent(CloudKitEnvironment.current, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        snapshotURL = directory.appendingPathComponent("snapshot.json")
        outboxURL = directory.appendingPathComponent("outbox.json")
        systemFieldsURL = directory.appendingPathComponent("systemfields.json")

        // Remove the legacy un-scoped cache from older builds so it can't be
        // read by the wrong environment again.
        try? fileManager.removeItem(at: root.appendingPathComponent("snapshot.json"))
        try? fileManager.removeItem(at: root.appendingPathComponent("outbox.json"))
    }

    func loadSnapshot() -> CloudSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? Self.decoder.decode(CloudSnapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: CloudSnapshot) {
        queue.async { [snapshotURL] in
            guard let data = try? Self.encoder.encode(snapshot) else { return }
            try? data.write(to: snapshotURL, options: .atomic)
        }
    }

    func loadOutbox() -> [String: PendingCloudWrite] {
        guard let data = try? Data(contentsOf: outboxURL),
              let writes = try? Self.decoder.decode([PendingCloudWrite].self, from: data) else {
            return [:]
        }
        var byKey: [String: PendingCloudWrite] = [:]
        for write in writes {
            if let existing = byKey[write.key], existing.revision > write.revision {
                continue
            }
            byKey[write.key] = write
        }
        return byKey
    }

    func saveOutbox(_ writes: [String: PendingCloudWrite]) {
        let ordered = writes.values.sorted { $0.enqueuedAt < $1.enqueuedAt }
        queue.async { [outboxURL] in
            guard let data = try? Self.encoder.encode(ordered) else { return }
            try? data.write(to: outboxURL, options: .atomic)
        }
    }

    func loadSystemFields() -> [String: Data] {
        guard let data = try? Data(contentsOf: systemFieldsURL),
              let fields = try? Self.decoder.decode([String: Data].self, from: data) else {
            return [:]
        }
        return fields
    }

    func saveSystemFields(_ fields: [String: Data]) {
        queue.async { [systemFieldsURL] in
            guard let data = try? Self.encoder.encode(fields) else { return }
            try? data.write(to: systemFieldsURL, options: .atomic)
        }
    }

    /// Runs `work` on the persistence queue *after* every write enqueued so far
    /// has completed (the queue is serial/FIFO). Used to advance CloudKit change
    /// tokens only once the matching snapshot is durably on disk.
    func runAfterPendingWrites(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Suspends until every `saveSnapshot`/`saveOutbox`/`saveSystemFields` write
    /// enqueued so far has been written to disk. Because `queue` is serial/FIFO,
    /// a task hopped onto it now runs only after all prior writes complete, so
    /// awaiting it guarantees those choices are durable — the barrier the trip
    /// summary waits on before letting the shopper leave.
    func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    func reset() {
        queue.sync {
            try? fileManager.removeItem(at: snapshotURL)
            try? fileManager.removeItem(at: outboxURL)
            try? fileManager.removeItem(at: systemFieldsURL)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
