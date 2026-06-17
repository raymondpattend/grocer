import CloudKit
import Foundation
import Network
import Observation
import WidgetKit

private enum PendingCloudOperation: String, Codable {
    case save
    case delete
}

private enum PendingCloudRecord: Codable, Equatable {
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

private struct PendingCloudWrite: Codable, Equatable {
    var operation: PendingCloudOperation
    var record: PendingCloudRecord
    var revision: Int
    var enqueuedAt: Date
    var failureCount: Int? = nil
    var retryAfter: Date? = nil
    var lastError: String? = nil

    var key: String { record.key }
}

struct GroceryItemInput {
    var name: String
    var quantity: String?
    var category: GroceryCategory
    var notes: String?
    var priority: ItemPriority = .normal
    var replacementPreference: String?
}

/// Which CloudKit environment this build talks to. CloudKit picks this from the
/// provisioning profile's `aps-environment`: Debug / dev-signed builds use
/// `development`, TestFlight / App Store builds use `production`. We read the
/// same signal so the local cache can be scoped to match — otherwise a Debug
/// build replays Production records into Development zones that don't exist,
/// producing endless "Zone Not Found" failures.
enum CloudKitEnvironment {
    static let current: String = resolve()

    private static func resolve() -> String {
        // Decode with ISO Latin-1, not ASCII: a .mobileprovision is a PKCS#7
        // signed blob whose certificate/signature bytes are > 127, which makes
        // `String(data:encoding:.ascii)` return nil for the whole file — every
        // build would then fall through to "production" and share the prod
        // cache. Latin-1 maps all 256 byte values, so the embedded plaintext
        // plist is always recoverable.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .isoLatin1),
              let start = raw.range(of: "<plist"),
              let end = raw.range(of: "</plist>"),
              let plistData = String(raw[start.lowerBound..<end.upperBound]).data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String
        else {
            // No embedded profile: either an App Store build (→ Production) or a
            // Simulator build (no provisioning profile at all). Fall back to the
            // compile configuration so Debug simulator runs still get the
            // Development-scoped cache instead of sharing the prod one.
            #if DEBUG
            return "development"
            #else
            return "production"
            #endif
        }
        return aps == "development" ? "development" : "production"
    }
}

private final class LocalSyncStore {
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

/// Central observable store for the family grocery space.
///
/// CloudKit is the source of truth. This repository keeps an in-memory working
/// set (the cache the UI binds to), loads it from CloudKit on launch, and
/// writes every mutation back best-effort. When CloudKit is unavailable (no
/// iCloud account, schema not created, offline first run), it keeps local state
/// empty until the shopper creates or joins a group, and sync resumes later.
///
/// A user can belong to multiple **groups**. A group *is* the grocery list: it
/// carries the store, icon, and color theme, and holds a single implicit
/// `GroceryList` for its items. One group is "selected" at a time.
@Observable
@MainActor
final class GroceryRepository {
    /// Weak global reference so non-SwiftUI code (e.g. the share delegate) can
    /// read current state. Set once at app launch via `makeShared()`.
    private(set) static weak var current: GroceryRepository?

    static func makeShared() -> GroceryRepository {
        let repo = GroceryRepository()
        current = repo
        return repo
    }

    #if DEBUG
    static func makePreview(
        households: [Household] = [],
        members: [HouseholdMember] = [],
        lists: [GroceryList] = [],
        items: [GroceryItem] = [],
        sessions: [ShoppingSession] = [],
        tripItems: [ShoppingTripItem] = [],
        joinedHouseholdId: String? = nil
    ) -> GroceryRepository {
        let repo = GroceryRepository()
        repo.households = households
        repo.members = members
        repo.lists = lists
        repo.items = items
        repo.sessions = sessions
        repo.tripItems = tripItems
        repo.joinedHouseholdId = joinedHouseholdId
        repo.hasCompletedInitialLoad = true
        return repo
    }
    #endif

    private(set) var households: [Household] = [] {
        didSet { rebuildHouseholdCaches() }
    }
    private(set) var members: [HouseholdMember] = [] {
        didSet { rebuildMemberCaches() }
    }
    private(set) var lists: [GroceryList] = [] {
        didSet { rebuildListCaches() }
    }
    private(set) var items: [GroceryItem] = [] {
        didSet { rebuildItemCaches() }
    }
    private(set) var sessions: [ShoppingSession] = [] {
        didSet { rebuildSessionCaches() }
    }
    private(set) var tripItems: [ShoppingTripItem] = [] {
        didSet { rebuildTripItemCaches() }
    }
    private(set) var events: [ItemEvent] = [] {
        didSet { rebuildEventCaches() }
    }

    private(set) var selectedHouseholdId: String?

    /// Set after successfully joining a group; the UI shows a welcome sheet.
    var joinedHouseholdId: String?

    /// True while a CloudKit share invite is being accepted. The UI shows a
    /// loading indicator until the joined-group sheet is ready to present.
    private(set) var isAcceptingInvite = false

    enum SyncState: Equatable { case idle, syncing, offline, error(String) }
    private(set) var syncState: SyncState = .idle

    /// Whether iCloud is signed in and usable. Drives `cloudIssue` so the offline
    /// chip can tell an iCloud sign-out apart from a plain network drop.
    private(set) var iCloudAccountAvailable = true

    /// A severe connectivity/account problem worth surfacing at the top of the
    /// app, mapped to a UI-free shape so views don't import CloudKit. `nil` when
    /// healthy or only in a minor/transient state (syncing, pending writes).
    enum CloudIssue: Equatable { case iCloudUnavailable, offline, syncError(String) }

    var cloudIssue: CloudIssue? {
        if !iCloudAccountAvailable { return .iCloudUnavailable }
        switch syncState {
        case .offline: return .offline
        case .error(let message): return .syncError(message)
        case .idle, .syncing: return nil
        }
    }

    /// Watches network reachability so the app reconnects the moment connectivity
    /// returns, instead of waiting for the next poll tick. See `startNetworkMonitoring`.
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var hasStartedPathMonitor = false
    /// Guards `retryCloudConnection` so overlapping triggers (path update +
    /// activation + manual tap) don't stack re-bootstraps.
    @ObservationIgnored private var isRecoveringConnection = false
    private(set) var subscriptionStatus = CloudSubscriptionRegistrationResult(
        privateZoneRegistered: false,
        sharedDatabaseRegistered: false,
        errors: []
    )
    private(set) var usingCloudKit = false
    private(set) var hasCompletedInitialLoad = false

    /// Number of local changes still queued to push to CloudKit. Surfaced on the
    /// debug screen to diagnose stuck syncs.
    var pendingCloudWriteCount: Int { pendingCloudWrites.count }

    private let cloud = CloudKitService.shared
    private let api = APIClient.shared
    private let liveActivity = LiveActivityManager.shared
    private let notifications = PushNotificationCoordinator.shared
    private let tripItemAlerts = ShoppingTripItemAddedAlertCoordinator.shared
    private let settings = SettingsStore.shared
    private let localStore = LocalSyncStore()
    private let shoppingTripInactivityLimit: TimeInterval = 60 * 60
    private let removedItemTombstoneRetention: TimeInterval = 30 * 24 * 60 * 60
    private let eventRetention: TimeInterval = 90 * 24 * 60 * 60
    private let completedTripRetentionCount = 50
    private let completedTripRetention: TimeInterval = 180 * 24 * 60 * 60
    private static let idleForegroundPollInterval: Duration = .seconds(1)
    private static let activeTripForegroundPollInterval: Duration = .milliseconds(700)
    private static let idleForegroundPollMinimumSpacing: TimeInterval = 1
    private static let activeTripForegroundPollMinimumSpacing: TimeInterval = 0.7
    private static let remoteNotificationDebounce: Duration = .milliseconds(150)
    private var remoteRefreshTask: Task<Void, Never>?
    private var foregroundRefreshTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var lastForegroundPollAt: Date?
    private var cloudWriteTask: Task<Void, Never>?
    private var pendingCloudWrites: [String: PendingCloudWrite] = [:]
    private var nextCloudWriteRevision = 0
    /// When Production CloudKit lacks `ShoppingTripItem.replacementItemName`, trip
    /// item saves omit that field so session completion is not blocked.
    private static let tripItemReplacementNameFieldKey = "grocer.cloudkit.tripItemReplacementNameFieldSupported"
    private var supportsTripItemReplacementNameField: Bool {
        get {
            GrocerAppGroup.defaults.object(forKey: Self.tripItemReplacementNameFieldKey) as? Bool ?? true
        }
        set {
            GrocerAppGroup.defaults.set(newValue, forKey: Self.tripItemReplacementNameFieldKey)
        }
    }
    /// Encoded `CKRecord` system fields keyed by record name. Lets the outbox
    /// re-save a record in one round trip (no pre-fetch for the change tag);
    /// refreshed on every fetch and after every successful save.
    private var recordSystemFields: [String: Data] = [:]
    /// Hash of the profile image last uploaded for each member record this
    /// session. Lets member saves skip re-uploading an unchanged avatar asset.
    private var lastUploadedMemberAvatarHash: [String: Int] = [:]
    /// Set when a refresh is requested while one is already in flight, so the
    /// in-flight pass re-runs once more instead of silently dropping the request.
    private var refreshRequestedWhileInFlight = false
    private var hasEstablishedTripItemAlertBaseline = false
    private var alertedTripItemIds: Set<String> = []
    @ObservationIgnored private var householdById: [String: Household] = [:]
    @ObservationIgnored private var listByHouseholdId: [String: GroceryList] = [:]
    @ObservationIgnored private var membersByHouseholdId: [String: [HouseholdMember]] = [:]
    @ObservationIgnored private var memberByHouseholdAndId: [String: [String: HouseholdMember]] = [:]
    @ObservationIgnored private var sessionsById: [String: ShoppingSession] = [:]
    @ObservationIgnored private var activeSessionByListId: [String: ShoppingSession] = [:]
    @ObservationIgnored private var completedTripsByHouseholdId: [String: [ShoppingSession]] = [:]
    @ObservationIgnored private var itemsByListId: [String: [GroceryItem]] = [:]
    @ObservationIgnored private var pendingItemsByListId: [String: [GroceryItem]] = [:]
    @ObservationIgnored private var pendingGroupsByListId: [String: [(category: GroceryCategory, items: [GroceryItem])]] = [:]
    @ObservationIgnored private var shoppingPendingGroupsBySessionId: [String: [(category: GroceryCategory, items: [GroceryItem])]] = [:]
    @ObservationIgnored private var addedDuringTripBySessionId: [String: [GroceryItem]] = [:]
    @ObservationIgnored private var handledItemsBySessionId: [String: [GroceryItem]] = [:]
    @ObservationIgnored private var itemSuggestionsByListId: [String: [GroceryItemSuggestion]] = [:]
    @ObservationIgnored private var itemSuggestionLookupByListId: [String: [String: GroceryItemSuggestion]] = [:]
    @ObservationIgnored private var tripItemsBySessionId: [String: [ShoppingTripItem]] = [:]
    @ObservationIgnored private var progressBySessionId: [String: SessionProgress] = [:]
    @ObservationIgnored private var tripProgressBySessionId: [String: SessionProgress] = [:]
    @ObservationIgnored private var localPersistenceBatchDepth = 0
    @ObservationIgnored private var hasDeferredLocalSnapshotSave = false
    @ObservationIgnored private var hasDeferredOutboxFlushSchedule = false
    private var derivedStateRevision = 0

    // MARK: - Derived caches

    private static let emptyProgress = SessionProgress(total: 0, found: 0, replaced: 0, outOfStock: 0, skipped: 0, remaining: 0)

    private func trackDerivedState() {
        _ = derivedStateRevision
    }

    private func markDerivedStateChanged() {
        derivedStateRevision += 1
    }

    private func rebuildHouseholdCaches() {
        householdById = Dictionary(uniqueKeysWithValues: households.map { ($0.id, $0) })
        markDerivedStateChanged()
        // Keep arrival-reminder geofences aligned with the latest linked-store
        // locations (e.g. after a CloudKit sync changes a store on another device).
        StoreReminderManager.shared.syncMonitoredRegions(households: households)
    }

    private func rebuildListCaches() {
        var byHousehold: [String: GroceryList] = [:]
        for list in lists where !list.archived {
            if byHousehold[list.householdId] == nil {
                byHousehold[list.householdId] = list
            }
        }
        listByHouseholdId = byHousehold
        markDerivedStateChanged()
    }

    private func rebuildMemberCaches() {
        let grouped = Dictionary(grouping: members, by: \.householdId)
        membersByHouseholdId = grouped.mapValues { $0.sorted(by: HouseholdMember.stableDisplayOrder) }
        memberByHouseholdAndId = membersByHouseholdId.mapValues { householdMembers in
            householdMembers.reduce(into: [:]) { byId, member in
                byId[member.id] = member
            }
        }
        markDerivedStateChanged()
    }

    private func rebuildSessionCaches() {
        sessionsById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        var activeByList: [String: ShoppingSession] = [:]
        var completedByHousehold: [String: [ShoppingSession]] = [:]
        for session in sessions {
            if session.status == .active, activeByList[session.listId] == nil {
                activeByList[session.listId] = session
            } else if session.status != .active {
                completedByHousehold[session.householdId, default: []].append(session)
            }
        }
        activeSessionByListId = activeByList
        completedTripsByHouseholdId = completedByHousehold.mapValues {
            $0.sorted(by: ShoppingSession.recentDisplayOrder)
        }
        rebuildShoppingSessionItemCaches()
        rebuildSessionProgressCaches()
        reconcileEndedLocalActivities()
        markDerivedStateChanged()
    }

    private func rebuildItemCaches() {
        var byList: [String: [GroceryItem]] = [:]
        var pendingByList: [String: [GroceryItem]] = [:]
        var handledBySession: [String: [GroceryItem]] = [:]

        for item in items {
            byList[item.listId, default: []].append(item)
            if item.status == .needed {
                pendingByList[item.listId, default: []].append(item)
            }
            if let sessionId = item.activeSessionId, item.status != .needed {
                handledBySession[sessionId, default: []].append(item)
            }
        }

        itemsByListId = byList.mapValues { $0.sorted(by: GroceryItem.listDisplayOrder) }
        pendingItemsByListId = pendingByList.mapValues { $0.sorted(by: GroceryItem.listDisplayOrder) }
        pendingGroupsByListId = pendingItemsByListId.mapValues { $0.groupedByCategory() }
        handledItemsBySessionId = handledBySession.mapValues { $0.sorted(by: GroceryItem.handledDisplayOrder) }
        rebuildItemSuggestionCaches()
        rebuildShoppingSessionItemCaches()
        rebuildSessionProgressCaches()
        markDerivedStateChanged()
    }

    private func rebuildShoppingSessionItemCaches() {
        guard !sessions.isEmpty else {
            shoppingPendingGroupsBySessionId = [:]
            addedDuringTripBySessionId = [:]
            return
        }

        var pendingGroups: [String: [(category: GroceryCategory, items: [GroceryItem])]] = [:]
        var addedDuringTrip: [String: [GroceryItem]] = [:]
        for session in sessions {
            let pending = pendingItemsByListId[session.listId] ?? []
            let originalItems = pending
                .filter { $0.createdAt <= session.startedAt }
                .sorted(by: GroceryItem.shoppingPriorityOrder)
            pendingGroups[session.id] = originalItems.groupedByCategory()
            addedDuringTrip[session.id] = pending.filter { $0.createdAt > session.startedAt }
        }
        shoppingPendingGroupsBySessionId = pendingGroups
        addedDuringTripBySessionId = addedDuringTrip
    }

    private func rebuildItemSuggestionCaches() {
        var suggestionsByList: [String: [GroceryItemSuggestion]] = [:]
        var lookupByList: [String: [String: GroceryItemSuggestion]] = [:]

        for (listId, listItems) in itemsByListId {
            let pendingKeys = Set((pendingItemsByListId[listId] ?? []).map { $0.name.itemSuggestionKey })
            var seen = Set<String>()
            let suggestions = listItems
                .sorted {
                    let lhsDate = Self.itemSuggestionDate(for: $0)
                    let rhsDate = Self.itemSuggestionDate(for: $1)
                    if lhsDate != rhsDate { return lhsDate > rhsDate }
                    return GroceryItem.listDisplayOrder($0, $1)
                }
                .compactMap { item -> GroceryItemSuggestion? in
                    let key = item.name.itemSuggestionKey
                    guard !key.isEmpty, !seen.contains(key) else { return nil }
                    seen.insert(key)
                    return GroceryItemSuggestion(
                        name: item.name,
                        quantity: item.quantity,
                        category: item.category,
                        isPending: pendingKeys.contains(key),
                        lastUsedAt: Self.itemSuggestionDate(for: item)
                    )
                }
            suggestionsByList[listId] = suggestions
            lookupByList[listId] = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.name.itemSuggestionKey, $0) })
        }

        itemSuggestionsByListId = suggestionsByList
        itemSuggestionLookupByListId = lookupByList
    }

    private func rebuildTripItemCaches() {
        let grouped = Dictionary(grouping: tripItems, by: \.sessionId)
        tripItemsBySessionId = grouped.mapValues { $0.sorted(by: ShoppingTripItem.tripDisplayOrder) }
        tripProgressBySessionId = tripItemsBySessionId.mapValues { Self.progress(forTripItems: $0) }
        markDerivedStateChanged()
    }

    private func rebuildEventCaches() {
        markDerivedStateChanged()
    }

    private func rebuildSessionProgressCaches() {
        guard !sessions.isEmpty else {
            progressBySessionId = [:]
            return
        }

        var next: [String: SessionProgress] = [:]
        for session in sessions {
            let scoped = (itemsByListId[session.listId] ?? []).filter {
                $0.status != .removed && ($0.status == .needed || $0.activeSessionId == session.id)
            }
            next[session.id] = Self.progress(forItems: scoped)
        }
        progressBySessionId = next
    }

    private static func progress(forItems items: [GroceryItem]) -> SessionProgress {
        var progress = emptyProgress
        progress.total = items.count
        for item in items {
            switch item.status {
            case .found:
                progress.found += 1
            case .replaced:
                progress.replaced += 1
            case .outOfStock:
                progress.outOfStock += 1
            case .skipped:
                progress.skipped += 1
            case .needed:
                progress.remaining += 1
            case .removed:
                break
            }
        }
        return progress
    }

    private static func progress(forTripItems items: [ShoppingTripItem]) -> SessionProgress {
        var progress = emptyProgress
        progress.total = items.count
        for item in items {
            switch item.outcome {
            case .found:
                progress.found += 1
            case .replaced:
                progress.replaced += 1
            case .outOfStock:
                progress.outOfStock += 1
            case .skipped:
                progress.skipped += 1
            case .needed:
                progress.remaining += 1
            case .removed:
                break
            }
        }
        return progress
    }

    // MARK: - Current selection

    var currentHousehold: Household? {
        trackDerivedState()
        return selectedHouseholdId.flatMap { householdById[$0] } ?? households.first
    }

    /// The single (non-archived) list backing the current group.
    var currentList: GroceryList? {
        trackDerivedState()
        guard let hid = currentHousehold?.id else { return nil }
        return listByHouseholdId[hid]
    }

    /// The single (non-archived) list backing a given group.
    func list(for household: Household) -> GroceryList? {
        trackDerivedState()
        return listByHouseholdId[household.id]
    }

    var currentMembers: [HouseholdMember] {
        trackDerivedState()
        guard let hid = currentHousehold?.id else { return [] }
        return membersByHouseholdId[hid] ?? []
    }

    func member(id: String?, householdId: String?) -> HouseholdMember? {
        trackDerivedState()
        guard let id, let householdId else { return nil }
        return memberByHouseholdAndId[householdId]?[id]
    }

    func member(for item: GroceryItem) -> HouseholdMember? {
        member(id: item.requestedByMemberId, householdId: item.householdId)
    }

    private var currentMemberId: String { Self.sanitizeRecordName(settings.memberIdOrDevice) }

    /// CloudKit rejects record names starting with `_` (reserved for system
    /// records). The iCloud user record name always starts with `_`, so strip it.
    static func sanitizeRecordName(_ name: String) -> String {
        var s = name
        while s.hasPrefix("_") { s = String(s.dropFirst()) }
        return s.isEmpty ? UUID().uuidString : s
    }

    private var currentMember: HouseholdMember? {
        guard let household = currentHousehold else { return nil }
        return member(for: household)
    }

    /// True when the group's CloudKit zone belongs to another user — i.e. it was
    /// shared into this account rather than created here. Drives the "Shared with
    /// Me" grouping in the group switcher.
    func isSharedWithMe(_ household: Household) -> Bool {
        (household.recordOwnerName ?? CKCurrentUserDefaultName) != CKCurrentUserDefaultName
    }

    var isOwnerOfCurrentGroup: Bool {
        guard let h = currentHousehold else { return false }
        let rootOwnedByCurrentAccount = (h.recordOwnerName ?? CKCurrentUserDefaultName) == CKCurrentUserDefaultName
        return rootOwnedByCurrentAccount && h.ownerMemberId == currentMemberId
    }

    var sharingUnavailableReason: String? {
        guard currentHousehold != nil else {
            return String(localized: "Create a list before inviting members.")
        }
        guard usingCloudKit else {
            return String(localized: "Sign in to iCloud to invite members. List sharing needs CloudKit, which isn't available in this build/session.")
        }
        switch syncState {
        case .idle, .syncing:
            // A background fetch in flight is not a reason to block sharing —
            // silent pushes flip syncState to .syncing for a second or two and
            // would otherwise make the invite button flicker disabled. Sharing
            // only needs CloudKit available + ownership, checked below.
            break
        case .offline:
            return String(localized: "Reconnect to iCloud before inviting members.")
        case .error:
            return String(localized: "iCloud sync is unavailable right now. Sharing will be available after this list syncs to iCloud.")
        }
        guard isOwnerOfCurrentGroup else {
            return String(localized: "Only the list owner can invite members.")
        }
        return nil
    }

    var canShare: Bool { sharingUnavailableReason == nil }

    /// Free accounts can invite up to this many people to a list. The list
    /// owner does not count toward the limit — Grocer Pro lifts it entirely.
    static let freeInviteLimit = 2

    /// People on the current list besides the owner — i.e. the accepted
    /// participants who count against `freeInviteLimit`.
    var invitedMemberCount: Int {
        max(0, currentMembers.count - 1)
    }
    var displayName: String { currentMember?.displayName ?? settings.displayName }
    var profileImageData: Data? { currentMember?.profileImageData ?? settings.profileImageData }

    func selectHousehold(_ id: String) {
        selectedHouseholdId = id
        settings.selectedHouseholdId = id
        Task { await configureLiveActivity() }
    }

    // MARK: - Derived state (scoped to the current list)

    func activeSession(for listId: String?) -> ShoppingSession? {
        trackDerivedState()
        guard let listId else { return nil }
        return activeSessionByListId[listId]
    }

    var activeSession: ShoppingSession? { activeSession(for: currentList?.id) }

    func session(id: String) -> ShoppingSession? {
        trackDerivedState()
        return sessionsById[id]
    }

    func isStartedByCurrentUser(_ session: ShoppingSession) -> Bool {
        let starter = Self.sanitizeRecordName(session.startedByMemberId)
        return starter == currentMemberId || session.startedByMemberId == settings.deviceId
    }

    func pendingItems(forList listId: String?) -> [GroceryItem] {
        trackDerivedState()
        guard let listId else { return [] }
        return pendingItemsByListId[listId] ?? []
    }

    var pendingItems: [GroceryItem] { pendingItems(forList: currentList?.id) }

    func pendingItemGroups(forList listId: String?) -> [(category: GroceryCategory, items: [GroceryItem])] {
        trackDerivedState()
        guard let listId else { return [] }
        return pendingGroupsByListId[listId] ?? []
    }

    var pendingItemGroups: [(category: GroceryCategory, items: [GroceryItem])] {
        pendingItemGroups(forList: currentList?.id)
    }

    var removedItems: [GroceryItem] {
        guard let listId = currentList?.id else { return [] }
        return (itemsByListId[listId] ?? [])
            .filter { $0.deletedAt == nil && ($0.status == .removed || $0.status == .found || $0.status == .replaced) }
            .sorted(by: GroceryItem.handledDisplayOrder)
    }

    var currentAuditEvents: [ItemEvent] {
        guard let householdId = currentHousehold?.id else { return [] }
        return events
            .filter { $0.householdId == householdId }
            .sorted(by: ItemEvent.recentDisplayOrder)
    }

    /// Distinct item suggestions from this group/list, latest first.
    var currentItemSuggestions: [GroceryItemSuggestion] {
        trackDerivedState()
        guard let listId = currentList?.id else { return [] }
        return itemSuggestionsByListId[listId] ?? []
    }

    /// Distinct item names from this list that aren't currently pending — for "add again" UI.
    var pastItemNames: [String] {
        currentItemSuggestions
            .filter { !$0.isPending }
            .map(\.name)
    }

    func currentItemSuggestion(named name: String) -> GroceryItemSuggestion? {
        trackDerivedState()
        guard let listId = currentList?.id else { return nil }
        return itemSuggestionLookupByListId[listId]?[name.itemSuggestionKey]
    }

    /// Removes completed/removed history records for a suggestion while leaving
    /// any currently-needed item with the same name on the list.
    func removeCurrentItemSuggestion(named name: String) {
        guard let listId = currentList?.id else { return }
        let key = name.itemSuggestionKey
        guard !key.isEmpty else { return }

        let historicalItems = (itemsByListId[listId] ?? []).filter {
            $0.name.itemSuggestionKey == key && $0.status != .needed
        }
        guard !historicalItems.isEmpty else { return }

        let historicalIds = Set(historicalItems.map(\.id))
        performLocalPersistenceBatch {
            items.removeAll { historicalIds.contains($0.id) }
            for item in historicalItems {
                enqueueDelete(.item(item))
            }
        }
    }

    private static func itemSuggestionDate(for item: GroceryItem) -> Date {
        item.completedAt ?? item.updatedAt
    }

    func addedDuringTrip(session: ShoppingSession) -> [GroceryItem] {
        trackDerivedState()
        return addedDuringTripBySessionId[session.id] ?? []
    }

    func pendingShoppingGroups(session: ShoppingSession) -> [(category: GroceryCategory, items: [GroceryItem])] {
        trackDerivedState()
        return shoppingPendingGroupsBySessionId[session.id] ?? []
    }

    func handledItems(session: ShoppingSession) -> [GroceryItem] {
        trackDerivedState()
        return handledItemsBySessionId[session.id] ?? []
    }

    func progress(for session: ShoppingSession) -> SessionProgress {
        trackDerivedState()
        return progressBySessionId[session.id] ?? Self.emptyProgress
    }

    // MARK: - Trip history

    /// Finished (completed or cancelled) trips for a group, most recent first.
    func completedTrips(for householdId: String?) -> [ShoppingSession] {
        trackDerivedState()
        guard let householdId else { return [] }
        return completedTripsByHouseholdId[householdId] ?? []
    }

    /// Finished trips for the currently selected group.
    var currentCompletedTrips: [ShoppingSession] {
        completedTrips(for: currentHousehold?.id)
    }

    /// The captured item snapshots for a finished trip, in display order.
    func tripItems(for session: ShoppingSession) -> [ShoppingTripItem] {
        trackDerivedState()
        return tripItemsBySessionId[session.id] ?? []
    }

    /// Outcome tallies for a finished trip, derived from its captured snapshots.
    func tripProgress(for session: ShoppingSession) -> SessionProgress {
        trackDerivedState()
        return tripProgressBySessionId[session.id] ?? Self.emptyProgress
    }

    private func expireInactiveShoppingTrips(now: Date = Date()) async {
        let expired = sessions.filter { session in
            guard session.status == .active else { return false }
            guard isStartedByCurrentUser(session) else { return false }
            return now.timeIntervalSince(lastActivityDate(for: session)) >= shoppingTripInactivityLimit
        }

        for session in expired {
            guard sessions.contains(where: { $0.id == session.id && $0.status == .active }) else { continue }
            print("[Repo] auto-ending inactive shopping session \(session.id)")
            await cancelShopping(session)
        }
    }

    private func pruneHistoricalRecords(now: Date = Date()) {
        guard usingCloudKit else { return }

        let removedItemCutoff = now.addingTimeInterval(-removedItemTombstoneRetention)
        let eventCutoff = now.addingTimeInterval(-eventRetention)
        let completedTripCutoff = now.addingTimeInterval(-completedTripRetention)

        let staleItems = items.filter { item in
            guard let deletedAt = item.deletedAt else { return false }
            return deletedAt < removedItemCutoff
        }
        let staleEvents = events.filter { $0.createdAt < eventCutoff }

        var staleSessions: [ShoppingSession] = []
        let completedByHousehold = Dictionary(grouping: sessions.filter { $0.status != .active }, by: \.householdId)
        for householdSessions in completedByHousehold.values {
            let sorted = householdSessions.sorted(by: ShoppingSession.recentDisplayOrder)
            for (index, session) in sorted.enumerated() {
                let endedOrUpdatedAt = session.endedAt ?? session.updatedAt
                if index >= completedTripRetentionCount || endedOrUpdatedAt < completedTripCutoff {
                    staleSessions.append(session)
                }
            }
        }

        let staleSessionIds = Set(staleSessions.map(\.id))
        let staleTripItems = tripItems.filter { staleSessionIds.contains($0.sessionId) }

        guard !staleItems.isEmpty || !staleEvents.isEmpty || !staleSessions.isEmpty || !staleTripItems.isEmpty else {
            return
        }

        performLocalPersistenceBatch {
            for item in staleItems { enqueueDelete(.item(item)) }
            for event in staleEvents { enqueueDelete(.event(event)) }
            for tripItem in staleTripItems { enqueueDelete(.tripItem(tripItem)) }
            for session in staleSessions { enqueueDelete(.session(session)) }

            let staleItemIds = Set(staleItems.map(\.id))
            let staleEventIds = Set(staleEvents.map(\.id))
            let staleTripItemIds = Set(staleTripItems.map(\.id))
            items.removeAll { staleItemIds.contains($0.id) }
            events.removeAll { staleEventIds.contains($0.id) }
            tripItems.removeAll { staleTripItemIds.contains($0.id) }
            sessions.removeAll { staleSessionIds.contains($0.id) }
        }

        print("[Repo] pruned history: \(staleItems.count) item tombstone(s), \(staleEvents.count) event(s), \(staleSessions.count) trip(s), \(staleTripItems.count) trip item(s)")
    }

    private func lastActivityDate(for session: ShoppingSession) -> Date {
        var latest = max(session.startedAt, session.updatedAt)
        if let endedAt = session.endedAt {
            latest = max(latest, endedAt)
        }

        let sessionItemIds = Set(items
            .filter { $0.householdId == session.householdId && $0.listId == session.listId }
            .map(\.id))

        for event in events where event.householdId == session.householdId && event.createdAt >= session.startedAt {
            let matchesSession = event.sessionId == session.id
            let matchesSessionItem = event.itemId.map { sessionItemIds.contains($0) } ?? false
            if matchesSession || matchesSessionItem {
                latest = max(latest, event.createdAt)
            }
        }

        for item in items where item.householdId == session.householdId && item.listId == session.listId {
            guard item.activeSessionId == session.id || item.createdAt >= session.startedAt || item.updatedAt >= session.startedAt else {
                continue
            }
            latest = max(latest, item.createdAt, item.updatedAt)
            if let completedAt = item.completedAt {
                latest = max(latest, completedAt)
            }
        }

        return latest
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        print("[Repo] ── bootstrap START ──")
        startNetworkMonitoring()
        ShareCoordinator.shared.setHandler { [weak self] metadata in
            await self?.acceptShare(metadata)
        }

        selectedHouseholdId = settings.selectedHouseholdId.nilIfBlank
        print("[Repo] restored selectedHouseholdId: \(selectedHouseholdId ?? "nil")")
        loadLocalSyncState()

        syncState = .syncing
        print("[Repo] checking iCloud account status…")
        let status = await cloud.accountStatus()
        iCloudAccountAvailable = (status == .available)
        guard status == .available else {
            print("[Repo] ⚠️ iCloud not available (status=\(status.rawValue))")
            usingCloudKit = false
            ensureValidSelection()
            syncState = .offline
            hasCompletedInitialLoad = true
            await configureLiveActivity()
            print("[Repo] ── bootstrap END (offline) ──")
            return
        }

        usingCloudKit = true
        print("[Repo] iCloud available, usingCloudKit = true")

        if let userRecordName = await cloud.currentUserRecordName() {
            let sanitized = Self.sanitizeRecordName(userRecordName)
            settings.memberId = sanitized
            print("[Repo] memberId set to: \(sanitized) (raw: \(userRecordName))")
        } else {
            print("[Repo] ⚠️ couldn't get userRecordName, memberId stays: \(settings.memberIdOrDevice)")
        }

        do {
            print("[Repo] step 1: ensureZone…")
            try await cloud.ensureZone()

            print("[Repo] step 2: refresh (fetch CloudKit changes)…")
            try await refresh()

            print("[Repo] step 3: households=\(households.count), checking if empty…")
            if households.isEmpty {
                print("[Repo] no households found; waiting for onboarding")
            }
            ensureValidSelection()
            syncState = .idle
            scheduleOutboxFlush()
            print("[Repo] ✅ bootstrap succeeded — \(households.count) group(s), sync=idle")
            await registerForRealtimeSync()
        } catch {
            print("[Repo] ❌ bootstrap failed: \(error)")
            if households.isEmpty {
                ensureValidSelection()
                syncState = .error(String(localized: "Sync failed: \(Self.shortError(error))"))
            } else {
                syncState = .error(String(localized: "Sync failed: \(Self.shortError(error))"))
            }
        }
        hasCompletedInitialLoad = true
        await configureLiveActivity()
        print("[Repo] ── bootstrap END (sync=\(syncState)) ──")
    }

    /// A full sync: pull changes *and* run the heavy idempotent maintenance pass.
    /// Used on meaningful triggers (bootstrap, activation, manual refresh).
    func refresh() async throws {
        try await fetchAndApplyChanges(discoverSharedZones: true)
        await runMaintenance()
    }

    /// The light, frequently-run half of a sync: pull CloudKit changes, merge
    /// them into the working set, and persist. Cheap enough to run on every
    /// foreground poll because a change-token fetch returns nothing when idle.
    func fetchAndApplyChanges(discoverSharedZones: Bool = true) async throws {
        guard usingCloudKit else {
            print("[Repo] fetch skipped (not using CloudKit)")
            return
        }
        print("[Repo] fetch → fetching changes…")
        let changes = try await cloud.fetchChanges(
            forceFull: currentSnapshot().isEmpty,
            discoverSharedZones: discoverSharedZones
        )
        if changes.hasRecordChanges {
            applySyncResult(changes)
            saveLocalSnapshot()
        } else {
            print("[Repo] fetch → no CloudKit record changes")
        }
        print("[Repo] fetch → \(households.count) households, \(members.count) members, \(lists.count) lists, \(items.count) items, \(events.count) events")
        ensureValidSelection()
        // Cheap (filters sessions by time) and acts only on genuinely stale
        // trips, so it's safe to run on every poll — keeps an idle foreground
        // session from leaving a trip "active" forever.
        await expireInactiveShoppingTrips()
        await configureLiveActivity()
    }

    /// The heavy half: roster/owner repair, profile-cache sync, stale-trip
    /// expiry, and the one-time parent-ref backfill. These scan the whole data
    /// set and can enqueue writes, so they run only on meaningful triggers — never
    /// on the steady foreground poll, which would churn battery and write traffic.
    private func runMaintenance() async {
        guard usingCloudKit else { return }
        ensureCurrentUserMemberRecords()
        repairOrphanedGroupOwners()
        pruneHistoricalRecords()
        syncPersonalProfileCache()
        await backfillParentReferencesIfNeeded()
        await configureLiveActivity()
    }

    /// One-time backfill for groups created before parent-reference support.
    ///
    /// `CKShare(rootRecord:)` only shares the root record and descendants whose
    /// `parent` references chain up to it. Records saved by older builds have no
    /// parent, so participants who join can't see the list or items. Here the
    /// *owner* re-saves every child record of the groups it owns, which adds the
    /// missing `parent` link (set in `setHouseholdParent`) and makes the data
    /// visible to everyone the group is shared with. Guarded by a flag so it
    /// runs only once.
    private func backfillParentReferencesIfNeeded() async {
        guard usingCloudKit else { return }
        let key = "grocer.migration.parentRefs.v2"
        guard !GrocerAppGroup.defaults.bool(forKey: key) else { return }

        let ownedHouseholdIds = households
            .filter { $0.ownerMemberId == currentMemberId
                && ($0.recordOwnerName ?? CKCurrentUserDefaultName) == CKCurrentUserDefaultName }
            .map(\.id)
        guard !ownedHouseholdIds.isEmpty else {
            GrocerAppGroup.defaults.set(true, forKey: key)
            return
        }

        print("[Repo] backfilling parent refs for \(ownedHouseholdIds.count) owned group(s)…")
        for hid in ownedHouseholdIds {
            for list in lists where list.householdId == hid {
                await fetchAndSave(list, type: CK.RecordType.list, id: list.id, householdId: hid)
            }
            for item in items where item.householdId == hid {
                await fetchAndSave(item, type: CK.RecordType.item, id: item.id, householdId: hid)
            }
            for session in sessions where session.householdId == hid {
                await fetchAndSave(session, type: CK.RecordType.session, id: session.id, householdId: hid)
            }
            for tripItem in tripItems where tripItem.householdId == hid {
                await fetchAndSave(tripItem, type: CK.RecordType.tripItem, id: tripItem.id, householdId: hid)
            }
            for event in events where event.householdId == hid {
                await fetchAndSave(event, type: CK.RecordType.event, id: event.id, householdId: hid)
            }
            for member in members where member.householdId == hid {
                await saveMemberBestEffort(member)
            }
        }
        GrocerAppGroup.defaults.set(true, forKey: key)
        print("[Repo] ✅ parent-ref backfill complete")
    }

    /// User-initiated pull-to-refresh. CloudKit silent pushes can be delayed
    /// (and are unreliable on the Simulator), so this gives an explicit way to
    /// pull the latest shared changes on demand.
    func manualRefresh() async {
        await refreshSnapshot(context: "Refresh failed", registerSubscriptions: true, showSyncing: true, maintenance: true)
    }

    /// Refresh after the app becomes active. Runs the full pass (with
    /// maintenance) to repair any state missed while backgrounded; the steady
    /// foreground loop then does light change-only polls.
    func refreshAfterActivation() async {
        // Re-check iCloud availability so a sign-out (or sign-in) while the app
        // was backgrounded is reflected in the top-of-app status chip.
        iCloudAccountAvailable = await cloud.accountStatus() == .available
        await refreshSnapshot(context: "Activation refresh failed", registerSubscriptions: true, showSyncing: false, maintenance: true)
    }

    /// Recover from an offline / iCloud-unavailable state: re-check the account
    /// and either resync (CloudKit already up) or bring CloudKit up from scratch
    /// (we launched without a usable account/connection). Safe to call repeatedly
    /// — triggered by the network monitor, app activation, and the offline chip's
    /// "Try Again" button.
    func retryCloudConnection() async {
        guard !isRecoveringConnection else { return }
        isRecoveringConnection = true
        defer { isRecoveringConnection = false }

        let status = await cloud.accountStatus()
        iCloudAccountAvailable = (status == .available)
        guard status == .available else { return }

        if usingCloudKit {
            // Don't flip to `.syncing` mid-retry — keep the chip steady until the
            // outcome is known so it doesn't flicker away and back.
            await refreshSnapshot(context: "Reconnect refresh failed",
                                  registerSubscriptions: true, showSyncing: false, maintenance: true)
        } else {
            await bootstrap()
        }
    }

    /// Begins watching network reachability (once). When connectivity returns and
    /// we're currently showing a problem, kick off a reconnect so the status chip
    /// clears on its own without the user pulling to refresh.
    private func startNetworkMonitoring() {
        guard !hasStartedPathMonitor else { return }
        hasStartedPathMonitor = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.cloudIssue != nil else { return }
                await self.retryCloudConnection()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "org.narro.grocer.network-monitor"))
    }

    func startForegroundRefreshLoop() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = Task { [weak self] in
            await self?.pollWhileForeground(force: true)
            while !Task.isCancelled {
                let interval = self?.activeSession == nil
                    ? Self.idleForegroundPollInterval
                    : Self.activeTripForegroundPollInterval
                try? await Task.sleep(for: interval)
                await self?.pollWhileForeground(force: false)
            }
        }
    }

    func stopForegroundRefreshLoop() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
    }

    /// Steady-state foreground tick: pull changes only, no maintenance. This is
    /// intentionally quick because it is the user-visible realtime path; full
    /// shared-zone discovery is reserved for force/activation/manual refreshes.
    private func pollWhileForeground(force: Bool) async {
        guard hasCompletedInitialLoad else { return }
        let now = Date()
        let minimumSpacing = activeSession == nil
            ? Self.idleForegroundPollMinimumSpacing
            : Self.activeTripForegroundPollMinimumSpacing
        if !force, let lastForegroundPollAt,
           now.timeIntervalSince(lastForegroundPollAt) < minimumSpacing {
            return
        }
        lastForegroundPollAt = now
        if usingCloudKit {
            await refreshSnapshot(
                context: "Foreground refresh failed",
                registerSubscriptions: false,
                showSyncing: false,
                maintenance: false,
                discoverSharedZones: force
            )
        } else {
            await expireInactiveShoppingTrips(now: now)
            // Launched offline / signed out → CloudKit never came up. Keep trying
            // so the app reconnects on its own once the account/network returns.
            await retryCloudConnection()
        }
    }

    /// Entry point for the periodic `BGAppRefreshTask`. Pulls and flushes while
    /// backgrounded so changes whose silent push iOS dropped still arrive without
    /// the user reopening the app. On a cold background launch (no UI scene, so
    /// `bootstrap()` never ran) this bootstraps first.
    func performBackgroundRefresh() async {
        guard CloudKitService.shared.isAvailable else { return }
        if !hasCompletedInitialLoad {
            await bootstrap()
            return
        }
        guard usingCloudKit else { return }
        do {
            try await fetchAndApplyChanges()
            await flushOutboxNow()
        } catch {
            print("[Repo] ⚠️ background refresh failed: \(error)")
        }
    }

    /// Called when CloudKit delivers a silent push after a subscription fires.
    /// Debounced so bursts of changes coalesce into one refresh.
    func handleRemoteNotification() async {
        guard usingCloudKit else { return }
        remoteRefreshTask?.cancel()
        remoteRefreshTask = Task(priority: .userInitiated) {
            try? await Task.sleep(for: Self.remoteNotificationDebounce)
            guard !Task.isCancelled else { return }
            print("[Repo] remote notification → refreshing…")
            await refreshSnapshot(
                context: "Remote refresh failed",
                registerSubscriptions: false,
                showSyncing: false,
                maintenance: false,
                discoverSharedZones: false
            )
        }
        await remoteRefreshTask?.value
    }

    private func refreshSnapshot(
        context: String,
        registerSubscriptions: Bool,
        showSyncing: Bool,
        maintenance: Bool,
        discoverSharedZones: Bool = true
    ) async {
        guard usingCloudKit else { return }
        // Coalesce instead of dropping: if a sync is already running, flag it so
        // the in-flight pass runs one more cycle rather than losing this request
        // (e.g. a push that lands mid-refresh).
        guard !refreshInFlight else {
            refreshRequestedWhileInFlight = true
            return
        }
        refreshInFlight = true
        defer { refreshInFlight = false }

        repeat {
            refreshRequestedWhileInFlight = false
            if showSyncing { syncState = .syncing }
            do {
                if maintenance {
                    try await refresh()
                } else {
                    try await fetchAndApplyChanges(discoverSharedZones: discoverSharedZones)
                }
                syncState = .idle
                if registerSubscriptions {
                    await registerForRealtimeSync()
                }
                scheduleOutboxFlush()
                print("[Repo] ✅ \(context.replacingOccurrences(of: " failed", with: "")) succeeded")
            } catch {
                print("[Repo] ❌ \(context): \(error)")
                recordSyncFailure(error, context: context)
            }
        } while refreshRequestedWhileInFlight
    }

    private func registerForRealtimeSync(force: Bool = false) async {
        guard usingCloudKit else { return }
        subscriptionStatus = await cloud.registerSubscriptions(force: force)
        guard !subscriptionStatus.isFullyRegistered else { return }
        syncState = .error(String(localized: "CloudKit subscriptions failed. Pull to refresh still works."))
    }

    private func ensureValidSelection() {
        if currentHousehold == nil { selectedHouseholdId = households.first?.id }
        settings.selectedHouseholdId = selectedHouseholdId ?? ""
    }

    private func configureLiveActivity() async {
        let memberships = householdMembershipsForPushRegistration()
        liveActivity.configure(householdMemberships: memberships)
        notifications.configure(householdMemberships: memberships)
    }

    private func householdMembershipsForPushRegistration() -> [String: String] {
        var memberships: [String: String] = [:]
        for household in households {
            if let member = member(for: household) {
                memberships[household.id] = member.id
            }
        }
        return memberships
    }

    private func member(for household: Household) -> HouseholdMember? {
        let householdMembers = membersByHouseholdId[household.id] ?? []
        return householdMembers.first { $0.id == currentMemberId }
            ?? householdMembers.first { $0.role == .owner }
            ?? householdMembers.first
    }

    private func syncPersonalProfileCache() {
        guard let member = member(id: currentMemberId, householdId: currentHousehold?.id) else { return }
        settings.displayName = member.displayName
        settings.profileImageData = member.profileImageData
    }

    private func ensureCurrentUserMemberRecords() {
        guard usingCloudKit else { return }
        let now = Date()
        let memberId = currentMemberId
        var added: [HouseholdMember] = []
        for household in households where !members.contains(where: { $0.householdId == household.id && $0.id == memberId }) {
            let zoneSource = members.first { $0.householdId == household.id }
            let member = HouseholdMember(
                id: memberId,
                householdId: household.id,
                displayName: settings.displayName,
                profileImageData: settings.profileImageData,
                iCloudUserRecordName: memberId,
                role: household.ownerMemberId == memberId ? .owner : .member,
                joinedAt: now,
                recordZoneName: zoneSource?.recordZoneName ?? household.recordZoneName,
                recordOwnerName: zoneSource?.recordOwnerName ?? household.recordOwnerName
            )
            members.append(member)
            added.append(member)
            print("[Repo] auto-created member \(memberId) for household \(household.name)")
        }
        if !added.isEmpty {
            added.forEach { persist($0) }
        }
    }

    // MARK: - Group management (a group is the list)

    @discardableResult
    func createGroup(name: String, store: String?, icon: String, theme: ListColorTheme) async -> Household? {
        print("[Repo] createGroup: \(name)")
        do {
            let household = try await makeGroup(name: name, store: store, icon: icon, theme: theme)
            selectHousehold(household.id)
            print("[Repo] ✅ createGroup succeeded: \(household.id)")
            return household
        } catch {
            print("[Repo] ❌ createGroup failed: \(error)")
            syncState = .error(String(localized: "Couldn't save list: \(Self.shortError(error))"))
            return nil
        }
    }

    @discardableResult
    private func makeGroup(name: String, store: String?, icon: String, theme: ListColorTheme) async throws -> Household {
        let now = Date()
        let memberId = currentMemberId
        print("[Repo] makeGroup: name=\(name), memberId=\(memberId), usingCloudKit=\(usingCloudKit)")

        let house = Household(id: cloud.makeRecordID().recordName, name: name,
                              ownerMemberId: memberId, storeName: store?.nilIfBlank,
                              icon: icon, colorTheme: theme, createdAt: now, updatedAt: now,
                              recordZoneName: CK.householdZoneName,
                              recordOwnerName: CKCurrentUserDefaultName)
        let member = HouseholdMember(id: memberId, householdId: house.id,
                                     displayName: settings.displayName,
                                     profileImageData: settings.profileImageData,
                                     iCloudUserRecordName: memberId,
                                     role: .owner, joinedAt: now,
                                     recordZoneName: CK.householdZoneName,
                                     recordOwnerName: CKCurrentUserDefaultName)
        let list = GroceryList(id: cloud.makeRecordID().recordName, householdId: house.id,
                               name: DEFAULT_LIST_NAME, createdAt: now, updatedAt: now, archived: false)

        households.append(house)
        members.append(member)
        lists.append(list)
        selectedHouseholdId = house.id
        settings.selectedHouseholdId = house.id
        print("[Repo] group added to local state: house=\(house.id), list=\(list.id)")

        print("[Repo] queueing new group records for CloudKit…")
        enqueueSave(.household(house))
        enqueueSave(.member(member))
        enqueueSave(.list(list))
        if usingCloudKit {
            await flushOutbox()
            if !pendingCloudWrites.keys.contains(PendingCloudRecord.household(house).key),
               !pendingCloudWrites.keys.contains(PendingCloudRecord.member(member).key),
               !pendingCloudWrites.keys.contains(PendingCloudRecord.list(list).key) {
                syncState = .idle
                print("[Repo] ✅ group saved to CloudKit")
            }
        } else {
            syncState = .offline
        }
        return house
    }

    /// Update the current group's appearance (name, store, icon, theme).
    func updateGroup(name: String, store: String?, icon: String, theme: ListColorTheme) {
        guard isOwnerOfCurrentGroup else {
            syncState = .error(String(localized: "Only the list owner can edit list details."))
            return
        }
        guard var house = currentHousehold else { return }
        house.name = name
        house.storeName = store?.nilIfBlank
        house.icon = icon
        house.colorTheme = theme
        house.updatedAt = Date()
        if let idx = households.firstIndex(where: { $0.id == house.id }) { households[idx] = house }
        persistHousehold(house)
    }

    /// Link the current list to a physical store so members can be reminded on
    /// arrival. The store geofence is shared on the group (any member may set
    /// it); the per-member opt-in is local. The member who links the store is
    /// opted in here — others opt in individually from Settings.
    func linkStore(latitude: Double, longitude: Double, radius: Double, name: String?) {
        guard var house = currentHousehold else { return }
        house.storeLatitude = latitude
        house.storeLongitude = longitude
        house.storeRadius = radius
        house.storeName = name?.nilIfBlank
        house.updatedAt = Date()
        if let idx = households.firstIndex(where: { $0.id == house.id }) { households[idx] = house }
        persistHousehold(house)
        SettingsStore.shared.setStoreRemindersEnabled(true, forHousehold: house.id)
        StoreReminderManager.shared.syncMonitoredRegions(households: households)
    }

    /// Remove the linked store from the current list (clears the shared geofence
    /// for everyone). Reminder opt-ins are left as-is but become inert.
    func unlinkStore() {
        guard var house = currentHousehold else { return }
        house.storeLatitude = nil
        house.storeLongitude = nil
        house.storeRadius = nil
        house.storeName = nil
        house.updatedAt = Date()
        if let idx = households.firstIndex(where: { $0.id == house.id }) { households[idx] = house }
        persistHousehold(house)
        StoreReminderManager.shared.syncMonitoredRegions(households: households)
    }

    func renameGroup(_ name: String) {
        guard isOwnerOfCurrentGroup else {
            syncState = .error(String(localized: "Only the list owner can rename this list."))
            return
        }
        guard var house = currentHousehold else { return }
        house.name = name
        house.updatedAt = Date()
        if let idx = households.firstIndex(where: { $0.id == house.id }) { households[idx] = house }
        persistHousehold(house)
    }

    // MARK: - Member management

    func removeMember(_ member: HouseholdMember) {
        guard isOwnerOfCurrentGroup else {
            syncState = .error(String(localized: "Only the list owner can remove members."))
            return
        }
        guard let household = households.first(where: { $0.id == member.householdId }) else { return }
        guard member.role != .owner else { return }
        members.removeAll { $0.id == member.id && $0.householdId == member.householdId }
        repairOrphanedGroupOwners()
        guard usingCloudKit else {
            saveLocalSnapshot()
            return
        }
        Task {
            do {
                let names = Set([member.id, member.iCloudUserRecordName].compactMap { $0?.nilIfBlank })
                _ = try await cloud.revokeParticipant(
                    matching: names,
                    from: householdRecordID(household)
                )
                enqueueDelete(.member(member))
                await flushOutbox()
                try? await refresh()
            } catch {
                print("[Repo] ❌ remove member failed: \(error)")
                recordSyncFailure(error, context: "Remove member failed")
                try? await refresh()
            }
        }
    }

    func isCurrentUser(_ member: HouseholdMember) -> Bool {
        member.id == currentMemberId
    }

    func updateDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        settings.displayName = trimmed
        var changed: [HouseholdMember] = []
        for idx in members.indices where members[idx].id == currentMemberId {
            members[idx].displayName = trimmed
            changed.append(members[idx])
        }
        changed.forEach { persist($0) }
    }

    func updateProfileImageData(_ imageData: Data?) {
        settings.profileImageData = imageData
        var changed: [HouseholdMember] = []
        for idx in members.indices where members[idx].id == currentMemberId {
            members[idx].profileImageData = imageData
            changed.append(members[idx])
        }
        changed.forEach { persist($0) }
    }

    /// Leaving the current group. The owner *deletes* the whole group for
    /// everyone — its household, list, items, history, members, and the
    /// CloudKit share. A member only removes themselves.
    func leaveCurrentGroup() {
        guard let house = currentHousehold else { return }
        if isOwnerOfCurrentGroup {
            deleteGroupAsOwner(house)
        } else {
            removeSelfFromGroup(house)
        }
    }

    /// Member leaving a shared group: remove the current account from the
    /// CloudKit share, then keep the local cache discarded. Deleting only the app
    /// member row is not enough — CloudKit will surface the shared zone again
    /// while the account is still a participant.
    private func removeSelfFromGroup(_ house: Household) {
        let rootRecordID = householdRecordID(house)
        discardLocalGroup(house)
        guard usingCloudKit else {
            saveLocalSnapshot()
            return
        }
        saveLocalSnapshot()
        Task {
            do {
                try await cloud.leaveShare(rootRecordID: rootRecordID)
                cloud.clearCachedSharedZone(rootRecordID.zoneID)
                try? await refresh()
            } catch {
                print("[Repo] ❌ leave shared group failed: \(error)")
                recordSyncFailure(error, context: "Leave group failed")
            }
        }
    }

    /// Owner leaving: tear the group down completely. Child records don't
    /// cascade-delete with the household root (their `parent` link uses
    /// `.none`), so each is deleted explicitly; deleting the household root
    /// also removes the `CKShare`, revoking every participant's access.
    private func deleteGroupAsOwner(_ house: Household) {
        guard usingCloudKit else {
            discardLocalGroup(house)
            saveLocalSnapshot()
            return
        }
        // Enqueue while the household is still in local state so child record
        // IDs resolve to the correct zone, then drop it locally.
        items.filter { $0.householdId == house.id }.forEach { enqueueDelete(.item($0)) }
        sessions.filter { $0.householdId == house.id }.forEach { enqueueDelete(.session($0)) }
        tripItems.filter { $0.householdId == house.id }.forEach { enqueueDelete(.tripItem($0)) }
        events.filter { $0.householdId == house.id }.forEach { enqueueDelete(.event($0)) }
        lists.filter { $0.householdId == house.id }.forEach { enqueueDelete(.list($0)) }
        members.filter { $0.householdId == house.id }.forEach { enqueueDelete(.member($0)) }
        enqueueDelete(.household(house))
        discardLocalGroup(house)
        saveLocalSnapshot()
    }

    /// Removes every trace of a group from in-memory state and reselects a
    /// remaining group.
    private func discardLocalGroup(_ house: Household) {
        households.removeAll { $0.id == house.id }
        lists.removeAll { $0.householdId == house.id }
        items.removeAll { $0.householdId == house.id }
        sessions.removeAll { $0.householdId == house.id }
        tripItems.removeAll { $0.householdId == house.id }
        events.removeAll { $0.householdId == house.id }
        members.removeAll { $0.householdId == house.id }
        selectedHouseholdId = households.first?.id
        ensureValidSelection()
    }

    // MARK: - Item CRUD

    @discardableResult
    func addItem(name: String, quantity: String?, category: GroceryCategory,
                 notes: String?, priority: ItemPriority = .normal,
                 replacementPreference: String?) -> GroceryItem? {
        addItems([
            GroceryItemInput(
                name: name,
                quantity: quantity,
                category: category,
                notes: notes,
                priority: priority,
                replacementPreference: replacementPreference
            )
        ]).first
    }

    @discardableResult
    func addItems(_ inputs: [GroceryItemInput]) -> [GroceryItem] {
        guard let household = currentHousehold, let list = currentList else { return [] }
        let now = Date()
        let member = currentMember
        let session = activeSession(for: list.id)

        // Items still needed on this list, keyed by lowercased name. An add whose
        // name matches one exactly (case aside) merges its quantity into that row
        // instead of creating a duplicate — "10 bananas" + "5 bananas" → "15".
        // New rows created in this same batch are folded in too, so repeated
        // names within a single paste collapse together as well.
        var byName: [String: GroceryItem] = [:]
        for item in pendingItemsByListId[list.id] ?? [] {
            let key = item.name.lowercased()
            if byName[key] == nil { byName[key] = item }
        }
        let preexistingIds = Set(byName.values.map(\.id))

        // Keys touched by this batch, in first-seen order, so persistence and the
        // return value run in a stable order.
        var touchedKeys: [String] = []

        for input in inputs {
            let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()

            if var existing = byName[key] {
                existing.quantity = Quantity.merged(existing.quantity, input.quantity)
                existing.updatedAt = now
                byName[key] = existing
            } else {
                byName[key] = GroceryItem(
                    id: cloud.makeRecordID().recordName,
                    householdId: household.id, listId: list.id,
                    name: name,
                    quantity: input.quantity?.nilIfBlank,
                    category: input.category,
                    notes: input.notes?.nilIfBlank,
                    requestedByMemberId: member?.id ?? settings.deviceId,
                    requestedByDisplayName: member?.displayName ?? settings.displayName,
                    status: .needed,
                    priority: input.priority,
                    replacementPreference: input.replacementPreference?.nilIfBlank,
                    replacementItemName: nil,
                    createdAt: now,
                    updatedAt: now,
                    completedAt: nil,
                    deletedAt: nil,
                    activeSessionId: session?.id
                )
            }
            if !touchedKeys.contains(key) { touchedKeys.append(key) }
        }
        guard !touchedKeys.isEmpty else { return [] }

        let touched = touchedKeys.map { byName[$0]! }
        let newItems = touched.filter { !preexistingIds.contains($0.id) }

        items.append(contentsOf: newItems)
        performLocalPersistenceBatch {
            for item in touched where preexistingIds.contains(item.id) {
                replaceInWorkingSet(item)
            }
            for item in touched {
                persist(item)
                let isNew = !preexistingIds.contains(item.id)
                logEvent(isNew ? .itemAdded : .itemEdited,
                         householdId: item.householdId, itemId: item.id, sessionId: session?.id,
                         metadata: ["name": item.name])
            }
        }
        // Prewarm the product image so it's a cache hit by the time it's viewed.
        // Only new items need it — merged ones were already on the list.
        Task { await api.prewarmImages(newItems.map(\.name)) }

        // Retention: record adds to a SHARED list so other members can be nudged
        // about them if they go inactive. Solo lists have no recipients, so skip.
        // `actorMemberId` matches the member id registered in device_tokens, so
        // the cron's "exclude my own additions" filter works.
        let householdMemberCount = (membersByHouseholdId[household.id] ?? []).count
        if !newItems.isEmpty, householdMemberCount > 1 {
            let payload = ListActivityPayload(
                householdId: household.id,
                actorMemberId: member?.id ?? settings.deviceId,
                actorDisplayName: member?.displayName ?? settings.displayName,
                deviceId: settings.deviceId,
                itemCount: newItems.count
            )
            Task { await api.reportListActivity(payload) }
        }

        if let session, let lastItem = touched.last {
            pushLiveActivityUpdate(for: session, lastItem: lastItem, lastStatus: nil)
        }
        return touched
    }

    func update(_ item: GroceryItem) {
        var updated = item
        updated.updatedAt = Date()
        replaceInWorkingSet(updated)
        persist(updated)
        logEvent(.itemEdited, householdId: item.householdId, itemId: item.id,
                 sessionId: activeSession(for: item.listId)?.id, metadata: ["name": updated.name])
    }

    func restoreItem(_ item: GroceryItem) {
        var updated = item
        updated.status = .needed
        updated.completedAt = nil
        updated.deletedAt = nil
        updated.activeSessionId = nil
        updated.updatedAt = Date()
        replaceInWorkingSet(updated)
        persist(updated)
        logEvent(.itemEdited, householdId: item.householdId, itemId: item.id,
                 sessionId: activeSession(for: item.listId)?.id,
                 metadata: ["name": updated.name, "status": updated.status.rawValue])
    }

    func delete(_ item: GroceryItem) {
        let now = Date()
        var updated = item
        updated.status = .removed
        updated.updatedAt = now
        updated.completedAt = updated.completedAt ?? now
        updated.deletedAt = now
        updated.activeSessionId = activeSession(for: item.listId)?.id
        replaceInWorkingSet(updated)
        persist(updated)
        logEvent(.itemRemoved, householdId: item.householdId, itemId: item.id,
                 sessionId: activeSession(for: item.listId)?.id, metadata: ["name": item.name])
    }

    // MARK: - Siri / App Intents entry point

    /// Returns a repository ready to serve an App Intent. Reuses the live
    /// instance when the app is already running; otherwise spins one up and
    /// bootstraps it so a cold, headless (Siri-triggered) launch loads the local
    /// cache, the selected group, and enables CloudKit sync.
    static func sharedForIntent() async -> GroceryRepository {
        if let current { return current }
        let repo = makeShared()
        await repo.bootstrap()
        return repo
    }

    /// Item-name suggestions for the App Intent resolver. These are optional:
    /// Siri can still resolve arbitrary dictated text through
    /// `GroceryItemNameQuery.entities(matching:)`.
    func intentItemNameSuggestions(limit: Int = 20) -> [String] {
        Array(currentItemSuggestions.map(\.name).prefix(limit))
    }

    /// Household choices for the App Intent list picker.
    func intentHouseholdChoices() -> [Household] {
        households
    }

    /// Adds an item dictated through Siri / Shortcuts to the given group (or the
    /// sole group when `householdId` is nil and only one exists), mirroring the
    /// in-app default path (offline category + unit guesses). Blocks until the
    /// CloudKit write is flushed so a background launch isn't suspended mid-sync.
    func addItemFromIntent(_ rawText: String, householdId: String? = nil) async -> IntentAddOutcome {
        if !hasCompletedInitialLoad {
            await bootstrap()
        }
        let targetHouseholdId = householdId ?? (households.count == 1 ? households.first?.id : nil)
        if let targetHouseholdId {
            selectHousehold(targetHouseholdId)
        }
        guard let list = currentList else { return .noList }

        let parsed = SiriItemPhrase(parsing: rawText)
        guard !parsed.name.isEmpty else { return .empty }

        addItem(
            name: parsed.name,
            quantity: parsed.quantity,
            category: CategoryGuess.guess(for: parsed.name),
            notes: nil,
            replacementPreference: nil
        )
        await flushOutboxNow()
        // Name the group (e.g. "Home"), not the internal list (always
        // "Groceries"), so multi-group users hear where it landed.
        return .added(item: parsed.name, list: currentHousehold?.name ?? list.name)
    }

    /// Drains the CloudKit outbox and waits for the in-flight flush task so a
    /// headless caller (App Intent) can guarantee the write reached CloudKit
    /// before `perform()` returns. No-op when not syncing to CloudKit — the
    /// write is still persisted to the local snapshot and flushes on next open.
    func flushOutboxNow() async {
        await cloudWriteTask?.value
        await flushOutbox()
    }

    // MARK: - Shopping status transitions

    func mark(_ item: GroceryItem, as status: ItemStatus, replacement: String? = nil) {
        let session = activeSession(for: item.listId)
        var updated = item
        updated.status = status
        updated.updatedAt = Date()
        updated.activeSessionId = session?.id
        if status != .needed { updated.completedAt = Date() }
        if status == .needed {
            updated.completedAt = nil
            updated.deletedAt = nil
        }
        if status == .replaced { updated.replacementItemName = replacement }
        replaceInWorkingSet(updated)
        persist(updated)

        let eventType: ItemEventType
        switch status {
        case .found: eventType = .itemFound
        case .replaced: eventType = .itemReplaced
        case .outOfStock: eventType = .itemOutOfStock
        case .skipped: eventType = .itemSkipped
        case .removed: eventType = .itemRemoved
        case .needed: eventType = .itemEdited
        }
        var metadata = ["name": updated.name, "status": status.rawValue]
        if let replacement = replacement?.nilIfBlank {
            metadata["replacement"] = replacement
        }
        logEvent(eventType, householdId: item.householdId, itemId: item.id, sessionId: session?.id, metadata: metadata)
        if let session { pushLiveActivityUpdate(for: session, lastItem: updated, lastStatus: status) }
    }

    // MARK: - Sessions

    /// Starts a trip for a group's list. The store defaults to the group's
    /// store (auto-use) and can be overridden per trip.
    func startShopping(list: GroceryList, storeName: String? = nil) async {
        guard activeSession(for: list.id) == nil else { return }
        let member = currentMember
        let groupStore = householdById[list.householdId]?.storeName
        let now = Date()
        let session = ShoppingSession(
            id: cloud.makeRecordID().recordName,
            householdId: list.householdId, listId: list.id,
            startedByMemberId: member?.id ?? settings.deviceId,
            startedByDisplayName: member?.displayName ?? settings.displayName,
            storeName: (storeName ?? groupStore)?.nilIfBlank,
            startedAt: now, endedAt: nil, updatedAt: now, status: .active
        )
        sessions.append(session)
        persist(session)
        logEvent(.sessionStarted, householdId: session.householdId, sessionId: session.id,
                 metadata: ["store": session.storeName ?? ""])

        // Ensure the shopper's avatar is in the App Group so the Live Activity can
        // render it in place of the cart icon, even before the next roster sync.
        if let memberId = member?.id, let avatar = member?.profileImageData ?? settings.profileImageData {
            WidgetShopperAvatarStore.save(avatar, forMember: memberId)
        }

        let content = contentState(for: session)
        let payload = startPayload(session: session, content: content)
        liveActivity.startLocalActivity(session: session, content: content)
        Task {
            let result = await api.startLiveActivity(payload)
            if let result {
                print("[Repo] startLiveActivity → sent=\(result.sent) failed=\(result.failed) " +
                      "notifSent=\(result.notificationsSent ?? 0) notifFailed=\(result.notificationsFailed ?? 0)")
            } else {
                print("[Repo] ⚠️ startLiveActivity API call failed or returned nil")
            }
        }
    }

    /// Sends a "heads up, I'm about to shop" Time Sensitive ping to everyone
    /// else in the current group. No shopping session is started.
    @discardableResult
    func sendHeadsUp() async -> Bool {
        guard let household = currentHousehold else { return false }
        let member = currentMember
        let payload = HeadsUpPayload(
            householdId: household.id,
            sourceDeviceId: settings.deviceId,
            shopperName: member?.displayName ?? settings.displayName,
            storeName: notificationStoreName(householdId: household.id, preferred: household.storeName),
            sentAt: ISO8601DateFormatter().string(from: Date())
        )
        let result = await api.sendHeadsUp(payload)
        if let result {
            print("[Repo] sendHeadsUp → sent=\(result.sent) failed=\(result.failed)")
        } else {
            print("[Repo] ⚠️ sendHeadsUp API call failed or returned nil")
        }
        return result != nil
    }

    func setStore(_ session: ShoppingSession, to storeName: String?) {
        var updated = session
        updated.storeName = storeName?.nilIfBlank
        updated.updatedAt = Date()
        replaceSession(updated)
        persist(updated)
        pushLiveActivityUpdate(for: updated, lastItem: nil, lastStatus: nil)
    }

    func finishShopping(_ session: ShoppingSession, clearCompleted: Bool, keepOutOfStock: Bool) async {
        var ended = session
        let now = Date()
        ended.status = .completed
        ended.endedAt = now
        ended.updatedAt = now
        replaceSession(ended)
        persist(ended)
        logEvent(.sessionCompleted, householdId: session.householdId, sessionId: session.id)

        let progress = progress(for: session)
        let payload = endPayload(session: ended, status: "completed", progress: progress)
        liveActivity.endLocalActivity(
            session: ended,
            content: contentState(for: ended, overrideStatus: .completed),
            includeHouseholdFallback: true
        )
        await flushCriticalSessionWrites(sessionId: session.id)
        // Snapshot the trip's items *before* cleanup wipes their activeSessionId.
        captureTripItems(for: session, at: now)
        applyCleanup(session: session, clearCompleted: clearCompleted, keepOutOfStock: keepOutOfStock)
        await flushOutboxNow()
        guard !hasPendingWrite(for: .session(ended)) else {
            print("[Repo] ⚠️ finishShopping deferred Live Activity end; session completion still pending CloudKit")
            return
        }
        await api.endLiveActivity(payload)
    }

    func cancelShopping(_ session: ShoppingSession) async {
        var cancelled = session
        let now = Date()
        cancelled.status = .cancelled
        cancelled.endedAt = now
        cancelled.updatedAt = now
        replaceSession(cancelled)
        persist(cancelled)
        logEvent(.sessionCancelled, householdId: session.householdId, sessionId: session.id)
        let progress = progress(for: session)
        let payload = endPayload(session: cancelled, status: "cancelled", progress: progress)
        liveActivity.endLocalActivity(
            session: cancelled,
            content: contentState(for: cancelled, overrideStatus: .cancelled),
            includeHouseholdFallback: true
        )
        await flushCriticalSessionWrites(sessionId: session.id)
        // A cancelled/auto-expired trip is still history; capture whatever was handled.
        captureTripItems(for: session, at: now)
        await flushOutboxNow()
        guard !hasPendingWrite(for: .session(cancelled)) else {
            print("[Repo] ⚠️ cancelShopping deferred Live Activity end; session cancellation still pending CloudKit")
            return
        }
        await api.endLiveActivity(payload)
    }

    private func applyCleanup(session: ShoppingSession, clearCompleted: Bool, keepOutOfStock: Bool) {
        var changed: [GroceryItem] = []
        let now = Date()
        items = items.compactMap { item in
            guard item.listId == session.listId else { return item }
            var item = item
            switch item.status {
            case .found, .replaced:
                if clearCompleted {
                    item.status = .removed
                    item.deletedAt = now
                    item.completedAt = item.completedAt ?? now
                    item.updatedAt = now
                    changed.append(item)
                } else {
                    // Keep it on the list: the planning list only shows `.needed`
                    // items, so a found/replaced item left as-is would silently
                    // vanish. Reset it to needed so "Remove found items: off"
                    // actually keeps the item visible.
                    item.status = .needed
                    item.completedAt = nil
                    item.deletedAt = nil
                    item.replacementItemName = nil
                    item.updatedAt = now
                    changed.append(item)
                }
            case .outOfStock:
                if keepOutOfStock {
                    item.status = .needed
                    item.completedAt = nil
                    item.deletedAt = nil
                    item.replacementItemName = nil
                    item.updatedAt = now
                    changed.append(item)
                } else {
                    item.status = .removed
                    item.deletedAt = now
                    item.completedAt = item.completedAt ?? now
                    item.updatedAt = now
                    changed.append(item)
                }
            case .skipped:
                item.status = .needed
                item.completedAt = nil
                item.deletedAt = nil
                item.updatedAt = now
                changed.append(item)
            default: break
            }
            item.activeSessionId = nil
            return item
        }
        changed.forEach { persist($0) }
    }

    /// Writes an immutable per-item snapshot of a trip so its contents stay
    /// reviewable after the live items are cleaned up / reused. Membership =
    /// items handled during the trip (`activeSessionId == session.id`, any
    /// outcome) plus items still on the list but left unfound (`.needed`). Must
    /// be called *before* `applyCleanup`, which clears `activeSessionId`.
    /// Re-capturing the same trip upserts via the deterministic record name.
    private func captureTripItems(for session: ShoppingSession, at capturedAt: Date) {
        let tripScopedItems = items.filter { item in
            guard item.listId == session.listId else { return false }
            return item.activeSessionId == session.id
                || (item.status == .needed && item.deletedAt == nil)
        }
        guard !tripScopedItems.isEmpty else { return }

        var captured: [ShoppingTripItem] = []
        for item in tripScopedItems {
            let snapshot = ShoppingTripItem(
                id: ShoppingTripItem.recordName(sessionId: session.id, itemId: item.id),
                householdId: session.householdId,
                sessionId: session.id,
                itemId: item.id,
                name: item.name,
                quantity: item.quantity,
                category: item.category,
                outcome: item.status,
                replacementItemName: item.replacementItemName,
                requestedByMemberId: item.requestedByMemberId,
                requestedByDisplayName: item.requestedByDisplayName,
                createdAt: capturedAt
            )
            if let idx = tripItems.firstIndex(where: { $0.id == snapshot.id }) {
                tripItems[idx] = snapshot
            } else {
                tripItems.append(snapshot)
            }
            captured.append(snapshot)
        }
        captured.forEach { persist($0) }
    }

    // MARK: - Live Activity payload helpers

    private func contentState(for session: ShoppingSession,
                              overrideStatus: SessionStatus? = nil,
                              lastItem: GroceryItem? = nil,
                              lastStatus: ItemStatus? = nil) -> GroceryActivityAttributes.ContentState {
        let p = progress(for: session)
        return GroceryActivityAttributes.ContentState(
            storeName: session.storeName,
            shopperName: session.startedByDisplayName,
            status: (overrideStatus ?? session.status).rawValue,
            itemsFound: p.found, itemsRemaining: p.remaining, totalItems: p.total,
            outOfStockCount: p.outOfStock, replacedCount: p.replaced,
            lastHandledItemName: lastItem?.name, lastHandledItemStatus: lastStatus?.rawValue
        )
    }

    private func pushLiveActivityUpdate(for session: ShoppingSession, lastItem: GroceryItem?, lastStatus: ItemStatus?) {
        let content = contentState(for: session, lastItem: lastItem, lastStatus: lastStatus)
        liveActivity.updateLocalActivity(session: session, content: content)
        let payload = updatePayload(session: session, content: content)
        Task { await api.updateLiveActivity(payload) }
    }

    private func notificationStoreName(householdId: String, preferred: String?) -> String? {
        preferred?.nilIfBlank ?? householdById[householdId]?.name.nilIfBlank
    }

    private func reconcileEndedLocalActivities() {
        liveActivity.reconcileEndedActivities(sessions) { [weak self] session in
            self?.contentState(for: session, overrideStatus: session.status)
                ?? GroceryActivityAttributes.ContentState(
                    storeName: session.storeName,
                    shopperName: session.startedByDisplayName,
                    status: session.status.rawValue,
                    itemsFound: 0,
                    itemsRemaining: 0,
                    totalItems: 0,
                    outOfStockCount: 0,
                    replacedCount: 0,
                    lastHandledItemName: nil,
                    lastHandledItemStatus: nil
                )
        }
    }

    private func startPayload(session: ShoppingSession, content: GroceryActivityAttributes.ContentState) -> StartLiveActivityPayload {
        StartLiveActivityPayload(
            householdId: session.householdId, sessionId: session.id,
            startedByMemberId: session.startedByMemberId,
            sourceDeviceId: settings.deviceId,
            storeName: notificationStoreName(householdId: session.householdId, preferred: content.storeName),
            shopperName: content.shopperName, status: content.status,
            itemsFound: content.itemsFound, itemsRemaining: content.itemsRemaining, totalItems: content.totalItems,
            outOfStockCount: content.outOfStockCount, replacedCount: content.replacedCount,
            lastHandledItemName: content.lastHandledItemName, lastHandledItemStatus: content.lastHandledItemStatus,
            startedAt: ISO8601DateFormatter().string(from: session.startedAt)
        )
    }

    private func updatePayload(session: ShoppingSession, content: GroceryActivityAttributes.ContentState) -> UpdateLiveActivityPayload {
        UpdateLiveActivityPayload(
            householdId: session.householdId, sessionId: session.id,
            storeName: notificationStoreName(householdId: session.householdId, preferred: content.storeName),
            shopperName: content.shopperName, status: content.status,
            itemsFound: content.itemsFound, itemsRemaining: content.itemsRemaining, totalItems: content.totalItems,
            outOfStockCount: content.outOfStockCount, replacedCount: content.replacedCount,
            lastHandledItemName: content.lastHandledItemName, lastHandledItemStatus: content.lastHandledItemStatus,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    private func endPayload(session: ShoppingSession, status: String, progress p: SessionProgress) -> EndLiveActivityPayload {
        EndLiveActivityPayload(
            householdId: session.householdId, sessionId: session.id,
            sourceDeviceId: settings.deviceId,
            storeName: notificationStoreName(householdId: session.householdId, preferred: session.storeName),
            shopperName: session.startedByDisplayName,
            status: status,
            itemsFound: p.found, itemsRemaining: p.remaining, totalItems: p.total,
            outOfStockCount: p.outOfStock, replacedCount: p.replaced,
            endedAt: ISO8601DateFormatter().string(from: session.endedAt ?? Date())
        )
    }

    // MARK: - CloudKit Sharing

    func prepareShare() async throws -> (CKShare, CKContainer) {
        print("[Repo] prepareShare starting…")
        if let reason = sharingUnavailableReason {
            print("[Repo] ❌ sharing unavailable: \(reason)")
            throw CloudSharingUnavailable(reason)
        }
        guard usingCloudKit, let household = currentHousehold, let container = cloud.container else {
            print("[Repo] ❌ prepareShare: usingCloudKit=\(usingCloudKit), household=\(currentHousehold?.id ?? "nil"), container=\(cloud.container != nil)")
            throw CloudKitUnavailable()
        }
        let recordID = cloud.makeRecordID(household.id)
        print("[Repo] prepareShare: fetching household record \(recordID.recordName)…")
        let householdRecord = try await cloud.privateRecord(id: recordID)
        print("[Repo] prepareShare: creating share…")
        let share = try await cloud.share(for: householdRecord)
        print("[Repo] ✅ prepareShare done")
        return (share, container)
    }

    /// Invite link for the contacts-picker flow: one URL we can text to several
    /// chosen people at once. See `CloudKitService.invitableShareURL`.
    func prepareInviteLink() async throws -> URL {
        print("[Repo] prepareInviteLink starting…")
        if let reason = sharingUnavailableReason {
            print("[Repo] ❌ invite link unavailable: \(reason)")
            throw CloudSharingUnavailable(reason)
        }
        guard usingCloudKit, let household = currentHousehold else {
            print("[Repo] ❌ prepareInviteLink: usingCloudKit=\(usingCloudKit), household=\(currentHousehold?.id ?? "nil")")
            throw CloudKitUnavailable()
        }
        let recordID = cloud.makeRecordID(household.id)
        let householdRecord = try await cloud.privateRecord(id: recordID)
        let url = try await cloud.invitableShareURL(for: householdRecord)
        print("[Repo] ✅ prepareInviteLink done")
        return url
    }

    @available(iOS 26.0, *)
    func prepareOneTimeInviteURL() async throws -> URL {
        print("[Repo] prepareOneTimeInviteURL starting…")
        if let reason = sharingUnavailableReason {
            print("[Repo] ❌ one-time invite unavailable: \(reason)")
            throw CloudSharingUnavailable(reason)
        }
        guard usingCloudKit, let household = currentHousehold else {
            print("[Repo] ❌ prepareOneTimeInviteURL: usingCloudKit=\(usingCloudKit), household=\(currentHousehold?.id ?? "nil")")
            throw CloudKitUnavailable()
        }
        let recordID = cloud.makeRecordID(household.id)
        print("[Repo] prepareOneTimeInviteURL: fetching household record \(recordID.recordName)…")
        let householdRecord = try await cloud.privateRecord(id: recordID)
        let url = try await cloud.oneTimeInviteURL(for: householdRecord)
        print("[Repo] ✅ prepareOneTimeInviteURL done")
        return url
    }

    func dismissJoinedHousehold() {
        joinedHouseholdId = nil
    }

    func acceptShare(_ metadata: CKShare.Metadata) async {
        let householdIdsBefore = Set(households.map(\.id))
        isAcceptingInvite = true
        defer { isAcceptingInvite = false }
        do {
            try await cloud.accept(metadata)
            try await refresh()
            await registerForRealtimeSync(force: true)
            await configureLiveActivity()

            if let newHousehold = households.first(where: { !householdIdsBefore.contains($0.id) }) {
                selectHousehold(newHousehold.id)
                joinedHouseholdId = newHousehold.id
                print("[Repo] switched to newly joined group: \(newHousehold.name)")
            }
        } catch {
            print("[Repository] accept share failed: \(error)")
            recordSyncFailure(error, context: "Accept share failed")
        }
    }

    // MARK: - Destructive reset

    func purgeAndRebootstrap() async throws {
        print("[Repo] ── purgeAndRebootstrap START ──")
        guard usingCloudKit else {
            print("[Repo] not using CloudKit, clearing local state only")
            resetLocalSyncState()
            households = []; members = []; lists = []; items = []; sessions = []; tripItems = []; events = []
            hasCompletedInitialLoad = false
            await bootstrap()
            return
        }
        try await cloud.deleteZone()
        resetLocalSyncState()
        households = []; members = []; lists = []; items = []; sessions = []; tripItems = []; events = []
        selectedHouseholdId = nil
        settings.selectedHouseholdId = ""
        hasCompletedInitialLoad = false
        syncState = .syncing
        print("[Repo] local state cleared, re-bootstrapping…")
        await bootstrap()
        print("[Repo] ── purgeAndRebootstrap END ──")
    }

    // MARK: - Persistence plumbing

    private func replaceInWorkingSet(_ item: GroceryItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) { items[idx] = item }
    }
    private func replaceSession(_ session: ShoppingSession) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) { sessions[idx] = session }
    }

    private func currentSnapshot() -> CloudSnapshot {
        CloudSnapshot(
            households: households,
            members: members,
            lists: lists,
            items: items,
            sessions: sessions,
            tripItems: tripItems,
            events: events
        )
    }

    private func loadLocalSyncState() {
        pendingCloudWrites = localStore.loadOutbox()
        nextCloudWriteRevision = (pendingCloudWrites.values.map(\.revision).max() ?? 0) + 1
        recordSystemFields = localStore.loadSystemFields()
        guard var snapshot = localStore.loadSnapshot(), !snapshot.isEmpty else { return }
        applyPendingWrites(to: &snapshot)
        applySnapshot(snapshot)
        ensureValidSelection()
        hasCompletedInitialLoad = true
        print("[Repo] loaded local cache — \(households.count) group(s), \(items.count) item(s), \(pendingCloudWrites.count) pending write(s)")
        publishWidgetSnapshot()
    }

    private func saveLocalSnapshot() {
        localStore.saveSnapshot(currentSnapshot())
        localStore.saveOutbox(pendingCloudWrites)
        publishWidgetSnapshot()
    }

    private func saveLocalSnapshotDeferredIfNeeded() {
        guard localPersistenceBatchDepth > 0 else {
            saveLocalSnapshot()
            return
        }
        hasDeferredLocalSnapshotSave = true
    }

    private func scheduleOutboxFlushDeferredIfNeeded() {
        guard localPersistenceBatchDepth > 0 else {
            scheduleOutboxFlush()
            return
        }
        hasDeferredOutboxFlushSchedule = true
    }

    private func performLocalPersistenceBatch(_ updates: () -> Void) {
        localPersistenceBatchDepth += 1
        updates()
        localPersistenceBatchDepth -= 1

        guard localPersistenceBatchDepth == 0 else { return }
        if hasDeferredLocalSnapshotSave {
            hasDeferredLocalSnapshotSave = false
            saveLocalSnapshot()
        }
        if hasDeferredOutboxFlushSchedule {
            hasDeferredOutboxFlushSchedule = false
            scheduleOutboxFlush()
        }
    }

    // MARK: - Home screen widget

    private var lastPublishedWidgetSignature: Data?

    /// Publishes a lightweight snapshot of every list (with pending item names)
    /// to the App Group so the home-screen widget can render it, and nudges
    /// WidgetKit to refresh. Called from the local-persistence chokepoints so it
    /// stays current with every change; deduped so frequent outbox flushes don't
    /// spam WidgetCenter.
    private func publishWidgetSnapshot() {
        let summaries: [WidgetListSummary] = households
            .sorted(by: Household.stableDisplayOrder)
            .map { household in
                let listId = listByHouseholdId[household.id]?.id
                let pending = listId.flatMap { pendingItemsByListId[$0] } ?? []
                return WidgetListSummary(
                    id: household.id,
                    name: household.name,
                    icon: household.icon,
                    colorThemeRaw: household.colorTheme.rawValue,
                    storeName: household.storeName,
                    pendingCount: pending.count,
                    itemNames: pending.prefix(12).map(\.name)
                )
            }

        // Dedupe on the list content only (not the generated timestamp) so an
        // unchanged list doesn't trigger a redundant timeline reload.
        guard let signature = try? JSONEncoder().encode(summaries),
              signature != lastPublishedWidgetSignature else { return }
        lastPublishedWidgetSignature = signature

        WidgetSnapshotStore.save(WidgetSnapshot(lists: summaries, generatedAt: Date()))
        WidgetCenter.shared.reloadAllTimelines()

        // Warm the shared image cache for the items the widget will show so they
        // appear without each widget having to fetch them itself.
        let names = Array(Set(summaries.flatMap { $0.itemNames })).prefix(24)
        for name in names {
            Task { await ProductImageLoader.shared.prewarm(for: name) }
        }
    }

    private func applySnapshot(_ snapshot: CloudSnapshot) {
        // Only assign when the value actually changed. `@Observable` fires a
        // mutation on every assignment regardless of equality, so writing an
        // identical array here would needlessly re-render every observing view.
        // With the ~5s foreground refresh loop that meant the toolbar group
        // menu (and its liquid-glass material) visibly flashed each cycle.
        assignIfChanged(&households, snapshot.households.sorted(by: Household.stableDisplayOrder))
        let sortedMembers = snapshot.members.sorted(by: HouseholdMember.stableDisplayOrder)
        if members != sortedMembers {
            members = sortedMembers
            // Publish member avatars to the App Group so Live Activities on family
            // devices can render the shopper's picture (keyed by member id).
            WidgetShopperAvatarStore.sync(members.map { ($0.id, $0.profileImageData) })
        }
        assignIfChanged(&lists, snapshot.lists.sorted(by: GroceryList.stableDisplayOrder))
        assignIfChanged(&items, snapshot.items.sorted(by: GroceryItem.listDisplayOrder))
        assignIfChanged(&sessions, snapshot.sessions.sorted(by: ShoppingSession.stableDisplayOrder))
        assignIfChanged(&tripItems, snapshot.tripItems.sorted(by: ShoppingTripItem.tripDisplayOrder))
        assignIfChanged(&events, snapshot.events.sorted(by: ItemEvent.stableDisplayOrder))
        repairOrphanedGroupOwners()
    }

    private func repairOrphanedGroupOwners() {
        guard !households.isEmpty, !members.isEmpty else { return }

        var membersToPersist: [HouseholdMember] = []

        for householdIndex in households.indices {
            let household = households[householdIndex]
            let memberIndexes = members.indices.filter { members[$0].householdId == household.id }
            guard !memberIndexes.isEmpty else { continue }

            guard let currentOwnerIndex = memberIndexes.first(where: { members[$0].id == household.ownerMemberId }) else {
                print("[Repo] owner member missing for \(household.name); leaving app-level ownership unchanged until CloudKit refetches it")
                continue
            }

            for memberIndex in memberIndexes {
                let repairedRole: MemberRole = memberIndex == currentOwnerIndex ? .owner : .member
                guard members[memberIndex].role != repairedRole else { continue }
                members[memberIndex].role = repairedRole
                membersToPersist.append(members[memberIndex])
            }
        }

        membersToPersist.forEach { persist($0) }
    }

    /// Writes `newValue` to `storage` only when it differs, avoiding spurious
    /// `@Observable` mutations (and the view re-renders they trigger).
    private func assignIfChanged<T: Equatable>(_ storage: inout T, _ newValue: T) {
        if storage != newValue { storage = newValue }
    }

    private func applySyncResult(_ result: CloudSyncResult) {
        let previousItemIds = Set(items.map(\.id))
        let localPendingItemIds = pendingCloudItemIds()
        let shouldAlertForNewTripItems = hasCompletedInitialLoad && hasEstablishedTripItemAlertBaseline

        var snapshot = currentSnapshot()
        // Households that vanished because their shared zone is gone (removed
        // from share / group deleted). Resolve their IDs from the pre-prune
        // snapshot so we can also drop any writes still queued against them —
        // otherwise applyPendingWrites would re-insert the phantom records.
        let removedHouseholdIds = snapshot.householdIds(in: result.vanishedZones)
        snapshot.removeRecords(in: result.fullZones)
        snapshot.upsert(contentsOf: result.snapshot)
        for deletion in result.deletions {
            snapshot.remove(deletion)
        }
        purgePendingWrites(forHouseholds: removedHouseholdIds)
        applyPendingWrites(to: &snapshot)
        applySnapshot(snapshot)

        // Cache the change tags for every record we just saw so the outbox can
        // re-save in a single round trip, then drop tags for records that no
        // longer exist so the cache can't grow without bound.
        if !result.systemFields.isEmpty {
            recordSystemFields.merge(result.systemFields) { _, new in new }
        }
        pruneSystemFieldsCache()
        localStore.saveSystemFields(recordSystemFields)

        if shouldAlertForNewTripItems {
            alertForNewActiveTripItems(
                incomingItems: result.snapshot.items,
                previousItemIds: previousItemIds,
                localPendingItemIds: localPendingItemIds
            )
        }
        hasEstablishedTripItemAlertBaseline = true
    }

    private func alertForNewActiveTripItems(incomingItems: [GroceryItem],
                                            previousItemIds: Set<String>,
                                            localPendingItemIds: Set<String>) {
        guard !incomingItems.isEmpty else { return }

        for item in incomingItems {
            guard !previousItemIds.contains(item.id),
                  !localPendingItemIds.contains(item.id),
                  !alertedTripItemIds.contains(item.id),
                  item.status == .needed,
                  item.deletedAt == nil,
                  !isRequestedByCurrentUser(item),
                  let session = activeSession(for: item.listId),
                  isStartedByCurrentUser(session),
                  item.createdAt > session.startedAt else {
                continue
            }

            alertedTripItemIds.insert(item.id)
            tripItemAlerts.alert(item: item, session: session)
        }
    }

    private func pendingCloudItemIds() -> Set<String> {
        pendingCloudWrites.values.reduce(into: Set<String>()) { itemIds, write in
            if case .item(let item) = write.record {
                itemIds.insert(item.id)
            }
        }
    }

    private func isRequestedByCurrentUser(_ item: GroceryItem) -> Bool {
        let requester = Self.sanitizeRecordName(item.requestedByMemberId)
        return requester == currentMemberId || item.requestedByMemberId == settings.deviceId
    }

    /// Drops queued writes for groups that no longer exist (their shared zone
    /// vanished). These writes target a dead zone and can never succeed, so
    /// keeping them would spin the outbox forever and re-insert ghost records.
    private func purgePendingWrites(forHouseholds householdIds: Set<String>) {
        guard !householdIds.isEmpty else { return }
        let staleKeys = pendingCloudWrites.filter { _, write in
            write.record.householdId.map { householdIds.contains($0) } ?? false
        }.keys
        guard !staleKeys.isEmpty else { return }
        for key in staleKeys { pendingCloudWrites.removeValue(forKey: key) }
        print("[Repo] 🗑️ purged \(staleKeys.count) pending write(s) for removed group(s)")
    }

    /// Drops cached change tags (and avatar hashes) for records that are no
    /// longer in the working set, so the caches track the live data set.
    private func pruneSystemFieldsCache() {
        var valid = Set<String>()
        valid.formUnion(households.map(\.id))
        valid.formUnion(members.map { "\($0.id)_\($0.householdId)" })
        valid.formUnion(lists.map(\.id))
        valid.formUnion(items.map(\.id))
        valid.formUnion(sessions.map(\.id))
        valid.formUnion(tripItems.map(\.id))
        valid.formUnion(events.map(\.id))
        recordSystemFields = recordSystemFields.filter { valid.contains($0.key) }
        lastUploadedMemberAvatarHash = lastUploadedMemberAvatarHash.filter { valid.contains($0.key) }
    }

    private func applyPendingWrites(to snapshot: inout CloudSnapshot) {
        let writes = pendingCloudWrites.values.sorted {
            if $0.revision != $1.revision { return $0.revision < $1.revision }
            return $0.enqueuedAt < $1.enqueuedAt
        }
        for write in writes {
            switch write.operation {
            case .save:
                snapshot.upsert(contentsOf: write.record.snapshot)
            case .delete:
                snapshot.remove(write.record.deletion)
            }
        }
    }

    private func persist(_ item: GroceryItem) {
        enqueueSave(.item(item))
    }

    private func persist(_ session: ShoppingSession) {
        enqueueSave(.session(session))
    }

    private func persist(_ tripItem: ShoppingTripItem) {
        enqueueSave(.tripItem(tripItem))
    }
    private func persist(_ member: HouseholdMember) {
        enqueueSave(.member(member))
    }
    private func persistHousehold(_ house: Household) {
        enqueueSave(.household(house))
    }

    private func persist(_ list: GroceryList) {
        enqueueSave(.list(list))
    }

    private func persist(_ event: ItemEvent) {
        enqueueSave(.event(event))
    }

    private func enqueueSave(_ record: PendingCloudRecord) {
        enqueueWrite(PendingCloudWrite(
            operation: .save,
            record: record,
            revision: nextOutboxRevision(),
            enqueuedAt: Date()
        ))
    }

    private func enqueueDelete(_ record: PendingCloudRecord) {
        enqueueWrite(PendingCloudWrite(
            operation: .delete,
            record: record,
            revision: nextOutboxRevision(),
            enqueuedAt: Date()
        ))
    }

    private func enqueueWrite(_ write: PendingCloudWrite) {
        guard shouldQueueForCloud(write.record) else {
            saveLocalSnapshotDeferredIfNeeded()
            return
        }
        pendingCloudWrites[write.key] = write
        saveLocalSnapshotDeferredIfNeeded()
        scheduleOutboxFlushDeferredIfNeeded()
    }

    private func hasPendingWrite(for record: PendingCloudRecord) -> Bool {
        pendingCloudWrites[record.key] != nil
    }

    private func shouldQueueForCloud(_ record: PendingCloudRecord) -> Bool {
        if usingCloudKit { return true }
        guard let householdId = record.householdId else { return false }
        return households.first { $0.id == householdId }?.recordZoneName != nil
    }

    private func nextOutboxRevision() -> Int {
        defer { nextCloudWriteRevision += 1 }
        return nextCloudWriteRevision
    }

    private func scheduleOutboxFlush() {
        guard usingCloudKit, !pendingCloudWrites.isEmpty else { return }
        let delay = nextOutboxFlushDelay()
        let previous = cloudWriteTask
        cloudWriteTask = Task(priority: .userInitiated) { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self?.flushOutbox()
        }
    }

    private func nextOutboxFlushDelay(now: Date = Date()) -> TimeInterval {
        var earliestRetryAfter: Date?
        for write in pendingCloudWrites.values {
            guard let retryAfter = write.retryAfter, retryAfter > now else { return 0 }
            if earliestRetryAfter == nil || retryAfter < earliestRetryAfter! {
                earliestRetryAfter = retryAfter
            }
        }
        return earliestRetryAfter.map { max(0.25, $0.timeIntervalSince(now)) } ?? 0
    }

    private func eligiblePendingWrites(now: Date = Date()) -> [PendingCloudWrite] {
        pendingCloudWrites.values
            .filter { write in
                guard let retryAfter = write.retryAfter else { return true }
                return retryAfter <= now
            }
            .sorted {
                if $0.revision != $1.revision { return $0.revision < $1.revision }
                let lp = Self.outboxPriority(for: $0.record)
                let rp = Self.outboxPriority(for: $1.record)
                if lp != rp { return lp < rp }
                return $0.enqueuedAt < $1.enqueuedAt
            }
    }

    /// Session termination must reach CloudKit before trip-item snapshots so a
    /// schema mismatch on one trip item cannot strand the group in Active.
    private static func outboxPriority(for record: PendingCloudRecord) -> Int {
        switch record {
        case .session: return 0
        case .event: return 1
        case .item: return 2
        case .tripItem: return 3
        case .household, .member, .list: return 4
        }
    }

    /// Flushes the session record and its lifecycle event before heavier trip-end
    /// writes are enqueued.
    private func flushCriticalSessionWrites(sessionId: String) async {
        guard usingCloudKit else { return }
        await cloudWriteTask?.value
        await flushPendingWritesIndividually { record in
            switch record {
            case .session(let session):
                return session.id == sessionId
            case .event(let event):
                return event.sessionId == sessionId
            default:
                return false
            }
        }
    }

    /// Saves matching outbox entries one record at a time so a poison record in
    /// the same revision cannot block unrelated writes via atomic batch failure.
    private func flushPendingWritesIndividually(
        where include: (PendingCloudRecord) -> Bool
    ) async {
        guard usingCloudKit else { return }

        var snapshotDirty = false
        var systemFieldsDirty = false
        var serverWon = false

        while true {
            let matching = eligiblePendingWrites().filter { include($0.record) }
            guard !matching.isEmpty else { break }

            let pendingBefore = Set(matching.map(\.key))
            for write in matching {
                guard pendingCloudWrites[write.key] == write else { continue }
                let zone = recordID(for: write.record).zoneID
                let outcome = await flushBatch([write], in: zone)
                snapshotDirty = snapshotDirty || outcome.removedAny
                systemFieldsDirty = systemFieldsDirty || outcome.systemFieldsChanged
                serverWon = serverWon || outcome.serverWon
            }

            let stillPending = pendingBefore.filter { pendingCloudWrites[$0] != nil }
            if stillPending.count == pendingBefore.count { break }
        }

        if systemFieldsDirty { localStore.saveSystemFields(recordSystemFields) }
        if snapshotDirty { saveLocalSnapshot() }
        if serverWon, !refreshInFlight {
            try? await fetchAndApplyChanges()
        }
    }

    /// Largest record count sent in a single CloudKit modify operation. CloudKit
    /// caps a batch around 400; staying under it keeps a burst within one round
    /// trip while leaving headroom.
    private static let outboxBatchLimit = 350

    /// Drains the pending-write queue using batched CloudKit modify operations —
    /// one round trip per zone-chunk instead of a fetch+save per record. Records
    /// carry a cached change tag so no pre-fetch is needed; per-record conflicts
    /// fall through to `resolveConflict`. Persists once at the end, not per write.
    private func flushOutbox() async {
        guard usingCloudKit, !pendingCloudWrites.isEmpty else { return }

        // CloudKit batches must stay within one database/zone, so group by zone.
        let writes = eligiblePendingWrites()
        guard !writes.isEmpty else {
            scheduleOutboxFlush()
            return
        }
        var byZone: [CKRecordZone.ID: [PendingCloudWrite]] = [:]
        for write in writes {
            byZone[recordID(for: write.record).zoneID, default: []].append(write)
        }

        var snapshotDirty = false
        var systemFieldsDirty = false
        var serverWon = false
        for (zone, zoneWrites) in byZone {
            for chunk in zoneWrites.chunked(into: Self.outboxBatchLimit) {
                let outcome = await flushBatch(chunk, in: zone)
                snapshotDirty = snapshotDirty || outcome.removedAny
                systemFieldsDirty = systemFieldsDirty || outcome.systemFieldsChanged
                serverWon = serverWon || outcome.serverWon
            }
        }

        if systemFieldsDirty { localStore.saveSystemFields(recordSystemFields) }
        if snapshotDirty { saveLocalSnapshot() }
        // A conflict the server's copy won leaves the working set showing the
        // discarded local value; pull the winning records so the UI converges.
        // Skip if a refresh is already running — it will pick them up — so we
        // don't race two fetches on the same change token.
        if serverWon, !refreshInFlight {
            try? await fetchAndApplyChanges()
        }
        if !pendingCloudWrites.isEmpty {
            scheduleOutboxFlush()
        }
    }

    private struct BatchOutcome {
        var removedAny = false
        var systemFieldsChanged = false
        var serverWon = false
    }

    /// Sends one zone-scoped batch and reconciles the per-record results against
    /// the outbox. Writes superseded by a newer local edit while in flight are
    /// left for the next flush.
    private func flushBatch(_ writes: [PendingCloudWrite], in zone: CKRecordZone.ID) async -> BatchOutcome {
        var saveRecords: [CKRecord] = []
        var deleteIDs: [CKRecord.ID] = []
        var writeByRecordName: [String: PendingCloudWrite] = [:]

        for write in writes {
            guard pendingCloudWrites[write.key] == write else { continue } // superseded
            let rid = recordID(for: write.record)
            writeByRecordName[rid.recordName] = write
            switch write.operation {
            case .save:
                saveRecords.append(buildRecord(for: write.record, recordID: rid))
            case .delete:
                deleteIDs.append(rid)
            }
        }
        guard !saveRecords.isEmpty || !deleteIDs.isEmpty else { return BatchOutcome() }

        let results: (save: [CKRecord.ID: Result<CKRecord, Error>], delete: [CKRecord.ID: Result<Void, Error>])
        do {
            results = try await cloud.modify(saving: saveRecords, deleting: deleteIDs, in: zone)
        } catch let error as CKError where Self.isZoneGone(error) {
            // The whole zone is gone — discard every write targeting it.
            var outcome = BatchOutcome()
            for write in writes where pendingCloudWrites[write.key] == write {
                pendingCloudWrites.removeValue(forKey: write.key)
                outcome.removedAny = true
            }
            print("[Repo] 🗑️ discarded \(writes.count) write(s) — zone \(zone.zoneName) gone")
            return outcome
        } catch {
            print("[Repo] ⚠️ batch deferred for zone \(zone.zoneName): \(error)")
            var outcome = BatchOutcome()
            for write in writes {
                outcome.removedAny = markWriteDeferred(write, error: error) || outcome.removedAny
            }
            recordSyncFailure(error, context: "iCloud sync failed")
            scheduleOutboxFlush()
            return outcome
        }

        var outcome = BatchOutcome()
        if syncState != .idle { syncState = .idle }

        var atomicFailureWrites: [PendingCloudWrite] = []

        for (rid, saveResult) in results.save {
            guard let write = writeByRecordName[rid.recordName] else { continue }
            switch saveResult {
            case .success(let saved):
                recordSystemFields[rid.recordName] = saved.encodedSystemFields()
                rememberMemberAvatar(for: write.record)
                outcome.systemFieldsChanged = true
                if removeIfCurrent(write) { outcome.removedAny = true }
            case .failure(let error):
                if writes.count > 1, Self.isBatchAtomicFailure(error) {
                    atomicFailureWrites.append(write)
                    continue
                }
                if Self.isTripItemReplacementNameSchemaError(error), case .tripItem = write.record {
                    let resolution = await retryTripItemWithoutReplacementName(
                        write: write, rid: rid, zone: zone, schemaError: error
                    )
                    outcome.removedAny = outcome.removedAny || resolution.removedAny
                    outcome.systemFieldsChanged = outcome.systemFieldsChanged || resolution.systemFieldsChanged
                    outcome.serverWon = outcome.serverWon || resolution.serverWon
                    continue
                }
                let resolution = await handleSaveFailure(write: write, rid: rid, error: error, zone: zone)
                outcome.removedAny = outcome.removedAny || resolution.removedAny
                outcome.systemFieldsChanged = outcome.systemFieldsChanged || resolution.systemFieldsChanged
                outcome.serverWon = outcome.serverWon || resolution.serverWon
            }
        }

        if writes.count > 1, !atomicFailureWrites.isEmpty {
            for write in atomicFailureWrites where pendingCloudWrites[write.key] == write {
                let retryOutcome = await flushBatch([write], in: zone)
                outcome.removedAny = outcome.removedAny || retryOutcome.removedAny
                outcome.systemFieldsChanged = outcome.systemFieldsChanged || retryOutcome.systemFieldsChanged
                outcome.serverWon = outcome.serverWon || retryOutcome.serverWon
            }
        }

        for (rid, deleteResult) in results.delete {
            guard let write = writeByRecordName[rid.recordName] else { continue }
            switch deleteResult {
            case .success:
                recordSystemFields.removeValue(forKey: rid.recordName)
                outcome.systemFieldsChanged = true
                if removeIfCurrent(write) { outcome.removedAny = true }
            case .failure(let error):
                if let ck = error as? CKError, ck.code == .unknownItem || Self.isZoneGone(ck) {
                    recordSystemFields.removeValue(forKey: rid.recordName)
                    outcome.systemFieldsChanged = true
                    if removeIfCurrent(write) { outcome.removedAny = true }
                } else {
                    print("[Repo] ⚠️ delete deferred for \(rid.recordName): \(error)")
                    outcome.removedAny = markWriteDeferred(write, error: error) || outcome.removedAny
                    recordSyncFailure(error, context: "iCloud delete failed")
                }
            }
        }

        return outcome
    }

    /// Removes a write from the outbox only if it hasn't been superseded by a
    /// newer edit enqueued while the batch was in flight.
    private func removeIfCurrent(_ write: PendingCloudWrite) -> Bool {
        guard pendingCloudWrites[write.key] == write else { return false }
        pendingCloudWrites.removeValue(forKey: write.key)
        return true
    }

    @discardableResult
    private func markWriteDeferred(_ write: PendingCloudWrite, error: Error) -> Bool {
        guard var current = pendingCloudWrites[write.key], current == write else { return false }
        let failureCount = (current.failureCount ?? 0) + 1
        current.failureCount = failureCount
        current.retryAfter = Date().addingTimeInterval(Self.outboxRetryDelay(for: error, failureCount: failureCount))
        current.lastError = Self.shortError(error)
        pendingCloudWrites[write.key] = current
        return true
    }

    private static func outboxRetryDelay(for error: Error, failureCount: Int) -> TimeInterval {
        if let ck = error as? CKError,
           let retryAfter = ck.errorUserInfo[CKErrorRetryAfterKey] as? TimeInterval {
            return min(max(retryAfter, 1), 60 * 30)
        }
        if let ck = error as? CKError,
           let retryAfter = ck.errorUserInfo[CKErrorRetryAfterKey] as? NSNumber {
            return min(max(retryAfter.doubleValue, 1), 60 * 30)
        }
        let exponent = min(max(failureCount - 1, 0), 8)
        return min(pow(2, Double(exponent)), 60 * 30)
    }

    private struct SaveFailureResolution {
        var removedAny = false
        var systemFieldsChanged = false
        var serverWon = false
    }

    /// Reconciles a single failed save. `.serverRecordChanged` routes to the
    /// merge; a dead zone discards; anything else defers for the next flush.
    private func handleSaveFailure(write: PendingCloudWrite, rid: CKRecord.ID, error: Error, zone: CKRecordZone.ID) async -> SaveFailureResolution {
        var outcome = SaveFailureResolution()
        if Self.isTripItemReplacementNameSchemaError(error), case .tripItem = write.record {
            return await retryTripItemWithoutReplacementName(
                write: write, rid: rid, zone: zone, schemaError: error
            )
        }
        if CloudKitSchemaTelemetry.parseMismatch(from: error) != nil {
            reportSchemaMismatch(
                error,
                recordName: rid.recordName,
                context: "icloud_save",
                recovered: false
            )
        }
        if let ck = error as? CKError, ck.code == .serverRecordChanged {
            let resolution = await resolveConflict(write: write, error: ck, zone: zone)
            outcome.systemFieldsChanged = true
            outcome.serverWon = resolution.serverWon
            if resolution.resolved, removeIfCurrent(write) { outcome.removedAny = true }
        } else if let ck = error as? CKError, Self.isZoneGone(ck) {
            recordSystemFields.removeValue(forKey: rid.recordName)
            outcome.systemFieldsChanged = true
            if removeIfCurrent(write) { outcome.removedAny = true }
            print("[Repo] 🗑️ discarding \(rid.recordName) — zone gone")
        } else {
            print("[Repo] ⚠️ save deferred for \(rid.recordName): \(error)")
            outcome.removedAny = markWriteDeferred(write, error: error) || outcome.removedAny
            recordSyncFailure(error, context: "iCloud save failed")
        }
        return outcome
    }

    /// Builds the `CKRecord` to save for a pending write, reusing the cached
    /// system fields (change tag) when present so the save is one round trip.
    private func buildRecord(for pending: PendingCloudRecord, recordID rid: CKRecord.ID) -> CKRecord {
        let record: CKRecord
        if let data = recordSystemFields[rid.recordName],
           let cached = CKRecord.from(systemFields: data),
           cached.recordID == rid,
           cached.recordType == pending.recordType {
            record = cached
        } else {
            record = CKRecord(recordType: pending.recordType, recordID: rid)
        }
        applyFields(of: pending, to: record)
        if let householdId = pending.householdId, pending.recordType != CK.RecordType.household {
            setHouseholdParent(record, householdId: householdId)
        }
        return record
    }

    /// Applies a pending record's fields to a `CKRecord`. For members the avatar
    /// asset is re-uploaded only when it changed since our last upload (or on the
    /// first save this session), avoiding redundant full-asset uploads on routine
    /// member saves (role repair, roster sync).
    private func applyFields(of pending: PendingCloudRecord, to record: CKRecord) {
        switch pending {
        case .member(let member):
            member.applyMetadata(to: record)
            let recordName = pending.recordName
            let newHash = member.profileImageData?.hashValue ?? 0
            let serverHasRecord = recordSystemFields[recordName] != nil
            if !serverHasRecord || lastUploadedMemberAvatarHash[recordName] != newHash {
                member.applyProfileImage(to: record)
            }
        case .tripItem(let tripItem):
            tripItem.apply(to: record, includeReplacementItemName: supportsTripItemReplacementNameField)
        default:
            pending.apply(to: record)
        }
    }

    private func retryTripItemWithoutReplacementName(
        write: PendingCloudWrite,
        rid: CKRecord.ID,
        zone: CKRecordZone.ID,
        schemaError: Error
    ) async -> SaveFailureResolution {
        if supportsTripItemReplacementNameField {
            supportsTripItemReplacementNameField = false
            print("[Repo] ⚠️ ShoppingTripItem.replacementItemName missing in CloudKit schema; omitting field on trip snapshots")
            reportSchemaMismatch(
                schemaError,
                recordName: rid.recordName,
                context: "trip_item_omit_field",
                recovered: true
            )
        }

        guard case .tripItem = write.record else {
            return SaveFailureResolution()
        }

        let record = buildRecord(for: write.record, recordID: rid)

        do {
            let results = try await cloud.modify(saving: [record], deleting: [], in: zone)
            if let saveResult = results.save[rid], case .success(let saved) = saveResult {
                recordSystemFields[rid.recordName] = saved.encodedSystemFields()
                if removeIfCurrent(write) {
                    return SaveFailureResolution(removedAny: true, systemFieldsChanged: true, serverWon: false)
                }
            }
        } catch {
            print("[Repo] ⚠️ trip item retry without replacementItemName failed for \(rid.recordName): \(error)")
            reportSchemaMismatch(
                error,
                recordName: rid.recordName,
                context: "trip_item_omit_field_retry_failed",
                recovered: false
            )
            _ = markWriteDeferred(write, error: error)
            recordSyncFailure(error, context: "iCloud save failed")
        }
        return SaveFailureResolution()
    }

    private func reportSchemaMismatch(
        _ error: Error,
        recordName: String?,
        context: String,
        recovered: Bool
    ) {
        guard let mismatch = CloudKitSchemaTelemetry.parseMismatch(from: error) else { return }
        CloudKitSchemaTelemetry.report(
            mismatch: mismatch,
            error: error,
            context: context,
            recordName: recordName,
            recovered: recovered
        )
    }

    private static func isBatchAtomicFailure(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        if ck.code == .batchRequestFailed { return true }
        let message = ck.localizedDescription.lowercased()
        return message.contains("atomic failure")
    }

    private static func isTripItemReplacementNameSchemaError(_ error: Error) -> Bool {
        guard let mismatch = CloudKitSchemaTelemetry.parseMismatch(from: error) else { return false }
        return mismatch.recordType.caseInsensitiveCompare(CK.RecordType.tripItem) == .orderedSame
            && mismatch.fieldName == CK.Field.replacementItemName
    }

    private func rememberMemberAvatar(for pending: PendingCloudRecord) {
        guard case .member(let member) = pending else { return }
        lastUploadedMemberAvatarHash[pending.recordName] = member.profileImageData?.hashValue ?? 0
    }

    /// The logical last-modified time used for conflict resolution. Immutable or
    /// untimestamped record types return nil (local copy is kept).
    private func updatedAt(of pending: PendingCloudRecord) -> Date? {
        switch pending {
        case .household(let v): return v.updatedAt
        case .list(let v): return v.updatedAt
        case .item(let v): return v.updatedAt
        case .session(let v): return v.updatedAt
        case .member, .tripItem, .event: return nil
        }
    }

    private struct ConflictResolution {
        var resolved: Bool   // true → the write can be removed from the outbox
        var serverWon: Bool  // true → the server copy was kept (UI should refetch)
    }

    /// Resolves a `.serverRecordChanged` conflict by comparing `updatedAt`
    /// (server `modificationDate` as tiebreaker): the newer write wins. The
    /// server's record travels with the error, so no extra fetch is needed.
    /// Soft-deletes and restores both bump `updatedAt`, so this orders
    /// delete-vs-edit correctly without special-casing.
    private func resolveConflict(write: PendingCloudWrite, error: CKError, zone: CKRecordZone.ID) async -> ConflictResolution {
        let rid = recordID(for: write.record)
        let recordName = rid.recordName

        guard let serverRecord = error.serverRecord else {
            print("[Repo] ⚠️ conflict without server record for \(recordName); deferring")
            return ConflictResolution(resolved: false, serverWon: false)
        }
        // Adopt the server's change tag either way so the next attempt is valid.
        recordSystemFields[recordName] = serverRecord.encodedSystemFields()

        if write.operation == .delete {
            // Our intent is removal; the server's concurrent edit doesn't change
            // that. Re-issue the delete now that we hold the latest tag.
            do {
                let results = try await cloud.modify(saving: [], deleting: [rid], in: zone)
                if let deleteResult = results.delete[rid], case .success = deleteResult {
                    recordSystemFields.removeValue(forKey: recordName)
                    return ConflictResolution(resolved: true, serverWon: false)
                }
            } catch {
                print("[Repo] ⚠️ conflict delete retry failed for \(recordName): \(error)")
            }
            return ConflictResolution(resolved: false, serverWon: false)
        }

        let localCompletedBeatsStaleCancellation = shouldKeepLocalCompletedSession(write: write, over: serverRecord)
        let localDate = updatedAt(of: write.record)
        let serverDate = (serverRecord[CK.Field.updatedAt] as? Date) ?? serverRecord.modificationDate
        if !localCompletedBeatsStaleCancellation, let localDate, let serverDate, serverDate > localDate {
            print("[Repo] ↩︎ conflict: server newer for \(serverRecord.recordType) \(recordName); kept server")
            return ConflictResolution(resolved: true, serverWon: true)
        }
        if localCompletedBeatsStaleCancellation {
            print("[Repo] ↻ conflict: keeping completed session over stale cancellation for \(recordName)")
        }

        // Local wins (newer, equal, or untimestamped): write our fields onto the
        // server's record — which carries the latest tag — and re-save once.
        applyFields(of: write.record, to: serverRecord)
        if let householdId = write.record.householdId, write.record.recordType != CK.RecordType.household {
            setHouseholdParent(serverRecord, householdId: householdId)
        }
        do {
            let results = try await cloud.modify(saving: [serverRecord], deleting: [], in: zone)
            if let saveResult = results.save[rid], case .success(let saved) = saveResult {
                recordSystemFields[recordName] = saved.encodedSystemFields()
                rememberMemberAvatar(for: write.record)
                print("[Repo] ↻ conflict resolved (local kept) for \(serverRecord.recordType) \(recordName)")
                return ConflictResolution(resolved: true, serverWon: false)
            }
            print("[Repo] ⚠️ conflict re-save still conflicted for \(recordName); deferring")
        } catch {
            print("[Repo] ⚠️ conflict re-save error for \(recordName): \(error)")
            recordSyncFailure(error, context: "Conflict retry failed")
        }
        return ConflictResolution(resolved: false, serverWon: false)
    }

    @discardableResult
    private func fetchAndSave<T: CloudKitApplicable>(_ model: T, type: String, id: String, householdId: String? = nil) async -> Bool {
        let rid = householdId.map { childRecordID(id, householdId: $0) } ?? cloud.makeRecordID(id)
        let record: CKRecord
        do {
            record = try await cloud.record(for: rid)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: type, recordID: rid)
        } catch let error as CKError where Self.isZoneGone(error) {
            print("[Repo] 🗑️ discarding \(type) \(id) — zone gone")
            return true
        } catch {
            print("[Repo] ⚠️ fetch deferred for \(type) \(id): \(error)")
            recordSyncFailure(error, context: "Save \(type) failed")
            return false
        }
        model.apply(to: record)
        if let householdId { setHouseholdParent(record, householdId: householdId) }
        return await saveBestEffort(record)
    }

    @discardableResult
    private func saveBestEffort(_ r: CKRecord, retried: Bool = false) async -> Bool {
        do {
            try await cloud.save(r)
            if syncState != .idle { syncState = .idle }
            return true
        } catch let error as CKError where error.code == .serverRecordChanged && !retried {
            // The server's copy travels with the error. Keep whichever side is
            // newer by `updatedAt` (server `modificationDate` as tiebreaker)
            // instead of blindly clobbering with the local copy.
            guard let serverRecord = error.serverRecord else {
                recordSyncFailure(error, context: "Conflict retry failed")
                return false
            }
            recordSystemFields[r.recordID.recordName] = serverRecord.encodedSystemFields()
            let localCompletedBeatsStaleCancellation = shouldKeepLocalCompletedSession(localRecord: r, over: serverRecord)
            let localDate = r[CK.Field.updatedAt] as? Date
            let serverDate = (serverRecord[CK.Field.updatedAt] as? Date) ?? serverRecord.modificationDate
            if !localCompletedBeatsStaleCancellation, let localDate, let serverDate, serverDate > localDate {
                print("[Repo] ↩︎ conflict: server newer for \(r.recordType) \(r.recordID.recordName); kept server")
                return true
            }
            if localCompletedBeatsStaleCancellation {
                print("[Repo] ↻ conflict: keeping completed session over stale cancellation for \(r.recordID.recordName)")
            }
            for key in r.allKeys() { serverRecord[key] = r[key] }
            print("[Repo] ↻ retrying save for \(r.recordType) \(r.recordID.recordName) after conflict")
            return await saveBestEffort(serverRecord, retried: true)
        } catch let error as CKError where Self.isZoneGone(error) {
            print("[Repo] 🗑️ discarding save for \(r.recordType) \(r.recordID.recordName) — zone gone")
            return true
        } catch {
            print("[Repo] ⚠️ saveBestEffort failed for \(r.recordType) \(r.recordID.recordName): \(error)")
            recordSyncFailure(error, context: "iCloud save failed")
            return false
        }
    }

    private func saveMemberBestEffort(_ member: HouseholdMember) async {
        let recordID = recordID(for: member)
        let record: CKRecord
        do {
            record = try await cloud.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            print("[Repo] member \(member.id) not on server yet, creating fresh record")
            record = CKRecord(recordType: CK.RecordType.member, recordID: recordID)
        } catch let error as CKError where Self.isZoneGone(error) {
            print("[Repo] 🗑️ skipping member \(member.id) save — zone gone")
            return
        } catch {
            print("[Repo] ⚠️ member fetch deferred: \(error)")
            recordSyncFailure(error, context: "Save member failed")
            return
        }

        member.apply(to: record)
        setHouseholdParent(record, householdId: member.householdId)
        await saveBestEffort(record)
    }

    private func recordSyncFailure(_ error: Error, context: String) {
        if Self.isConnectivityError(error) {
            syncState = .offline
        } else if Self.shouldSuppressUserVisibleSyncFailure(error) {
            if case .syncing = syncState {
                syncState = .idle
            }
            print("[Repo] ⚠️ \(context) deferred without surfacing sync issue: \(Self.shortError(error))")
        } else {
            syncState = .error(String(localized: "\(context): \(Self.shortError(error))"))
        }
    }

    private func shouldKeepLocalCompletedSession(write: PendingCloudWrite, over serverRecord: CKRecord) -> Bool {
        guard write.operation == .save,
              case .session(let session) = write.record,
              session.status == .completed,
              serverRecord.recordType == CK.RecordType.session,
              (serverRecord[CK.Field.status] as? String) == SessionStatus.cancelled.rawValue else {
            return false
        }
        return true
    }

    private func shouldKeepLocalCompletedSession(localRecord: CKRecord, over serverRecord: CKRecord) -> Bool {
        localRecord.recordType == CK.RecordType.session
            && serverRecord.recordType == CK.RecordType.session
            && (localRecord[CK.Field.status] as? String) == SessionStatus.completed.rawValue
            && (serverRecord[CK.Field.status] as? String) == SessionStatus.cancelled.rawValue
    }

    private func resetLocalSyncState() {
        cloud.clearSubscriptionRegistrationFlag()
        GrocerAppGroup.defaults.removeObject(forKey: "grocer.migration.parentRefs.v1")
        GrocerAppGroup.defaults.removeObject(forKey: "grocer.migration.parentRefs.v2")
        cloudWriteTask?.cancel()
        cloudWriteTask = nil
        pendingCloudWrites.removeAll()
        nextCloudWriteRevision = 0
        recordSystemFields.removeAll()
        lastUploadedMemberAvatarHash.removeAll()
        localPersistenceBatchDepth = 0
        hasDeferredLocalSnapshotSave = false
        hasDeferredOutboxFlushSchedule = false
        localStore.reset()
        subscriptionStatus = CloudSubscriptionRegistrationResult(
            privateZoneRegistered: false,
            sharedDatabaseRegistered: false,
            errors: []
        )
        lastForegroundPollAt = nil
    }

    private func logEvent(_ type: ItemEventType, householdId: String? = nil, itemId: String? = nil,
                          sessionId: String? = nil, metadata: [String: String] = [:]) {
        let member = currentMember
        let event = ItemEvent(
            id: cloud.makeRecordID().recordName,
            householdId: householdId ?? currentHousehold?.id ?? "local",
            itemId: itemId, sessionId: sessionId, type: type,
            createdByMemberId: member?.id ?? settings.deviceId,
            createdByDisplayName: member?.displayName ?? settings.displayName,
            createdAt: Date(), metadata: metadata
        )
        events.append(event)
        persist(event)
    }

    private func newRecord<T: CloudKitApplicable>(_ model: T, type: String, id: String, householdId: String? = nil) -> CKRecord {
        let rid = householdId.map { childRecordID(id, householdId: $0) } ?? cloud.makeRecordID(id)
        let r = CKRecord(recordType: type, recordID: rid); model.apply(to: r)
        if let householdId { setHouseholdParent(r, householdId: householdId) }
        return r
    }

    private func householdRecordID(_ household: Household) -> CKRecord.ID {
        if let zoneName = household.recordZoneName {
            let owner = household.recordOwnerName ?? CKCurrentUserDefaultName
            return CKRecord.ID(recordName: household.id,
                               zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: owner))
        }
        return cloud.makeRecordID(household.id)
    }

    /// The CloudKit zone a household's records live in. For groups the user
    /// owns this is their local private zone; for groups they joined it's the
    /// owner's zone (reached through the shared database). Falling back to the
    /// local zone keeps owner-only flows working before any household loads.
    private func zoneID(forHousehold householdId: String) -> CKRecordZone.ID {
        if let household = households.first(where: { $0.id == householdId }),
           let zoneName = household.recordZoneName {
            return CKRecordZone.ID(zoneName: zoneName,
                                   ownerName: household.recordOwnerName ?? CKCurrentUserDefaultName)
        }
        return cloud.localZoneID
    }

    /// Builds a record ID for a child record in its household's zone. Using the
    /// household's zone (rather than always the local private zone) is what lets
    /// a participant's edits land in the shared group so the owner and other
    /// members actually receive them.
    private func childRecordID(_ name: String, householdId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID(forHousehold: householdId))
    }

    private func recordID(for pending: PendingCloudRecord) -> CKRecord.ID {
        switch pending {
        case .household(let household):
            return householdRecordID(household)
        case .member(let member):
            return recordID(for: member)
        case .list(let list):
            return childRecordID(list.id, householdId: list.householdId)
        case .item(let item):
            return childRecordID(item.id, householdId: item.householdId)
        case .session(let session):
            return childRecordID(session.id, householdId: session.householdId)
        case .tripItem(let tripItem):
            return childRecordID(tripItem.id, householdId: tripItem.householdId)
        case .event(let event):
            return childRecordID(event.id, householdId: event.householdId)
        }
    }

    /// Links a child record to its Household root via a `parent` reference so
    /// it belongs to the shared record hierarchy.
    ///
    /// `CKShare(rootRecord:)` only covers the root record and descendants whose
    /// `parent` references chain up to it. Without this link a share participant
    /// can neither see child records nor create new ones — the server rejects
    /// participant creates with "CREATE operation not permitted" (CKError
    /// 10/2007). Parent references must stay within a single zone, so we only
    /// set it when the child and household share a zone.
    private func setHouseholdParent(_ record: CKRecord, householdId: String) {
        guard let household = households.first(where: { $0.id == householdId }) else { return }
        let parentID = householdRecordID(household)
        guard parentID.zoneID == record.recordID.zoneID else { return }
        record.parent = CKRecord.Reference(recordID: parentID, action: .none)
    }

    /// Member record names must be unique per household since one user can
    /// belong to multiple groups but all records live in the same zone.
    private func recordID(for member: HouseholdMember) -> CKRecord.ID {
        let name = "\(member.id)_\(member.householdId)"
        guard let zoneName = member.recordZoneName, let ownerName = member.recordOwnerName else {
            return cloud.makeRecordID(name)
        }
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
        return CKRecord.ID(recordName: name, zoneID: zoneID)
    }

}

struct SessionProgress: Equatable {
    var total: Int, found: Int, replaced: Int, outOfStock: Int, skipped: Int, remaining: Int
}

extension GroceryRepository {
    static func shortError(_ error: Error) -> String {
        if let ck = error as? CKError {
            return "CKError.\(ck.code.rawValue): \(ck.localizedDescription)"
        }
        return error.localizedDescription
    }

    /// True only for errors that genuinely mean the device can't reach iCloud.
    ///
    /// Best-effort persistence throws for many *non*-connectivity reasons —
    /// throttling (`.requestRateLimited`, `.zoneBusy`, `.serviceUnavailable`),
    /// write conflicts (`.serverRecordChanged`), partial batch failures, or a
    /// missing shared database (`CloudKitUnavailable`). Treating those as
    /// "offline" makes the banner flash even on full cellular, so only true
    /// network errors should surface it.
    static func isConnectivityError(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        switch ck.code {
        case .networkUnavailable, .networkFailure:
            return true
        default:
            return false
        }
    }

    /// Recoverable CloudKit write/fetch failures should stay in diagnostics and
    /// the outbox retry loop, but they should not interrupt the app with a red
    /// "Sync issue" chip. The chip is reserved for problems that need the user.
    static func shouldSuppressUserVisibleSyncFailure(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        switch ck.code {
        case .requestRateLimited,
             .serviceUnavailable,
             .zoneBusy,
             .serverRecordChanged,
             .batchRequestFailed,
             .partialFailure,
             .limitExceeded,
             .operationCancelled:
            return true
        default:
            return false
        }
    }

    /// True when the target zone no longer exists — the user was removed from
    /// the share or the owner deleted the group. This is terminal: retrying a
    /// write against a dead zone can never succeed, so the write is discarded
    /// rather than deferred.
    static func isZoneGone(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        return ck.code == .zoneNotFound || ck.code == .userDeletedZone
    }
}

struct CloudSharingUnavailable: LocalizedError {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }

    var errorDescription: String? { reason }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var itemSuggestionKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private extension Array {
    /// Splits into consecutive sub-arrays of at most `size` elements. Used to
    /// keep a CloudKit modify batch under the per-operation record cap.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
