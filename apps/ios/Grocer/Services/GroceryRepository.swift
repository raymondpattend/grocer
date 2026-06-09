import CloudKit
import Foundation
import Observation

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
    case event(ItemEvent)

    var recordType: String {
        switch self {
        case .household: return CK.RecordType.household
        case .member: return CK.RecordType.member
        case .list: return CK.RecordType.list
        case .item: return CK.RecordType.item
        case .session: return CK.RecordType.session
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
        case .event(let value): value.apply(to: record)
        }
    }
}

private struct PendingCloudWrite: Codable, Equatable {
    var operation: PendingCloudOperation
    var record: PendingCloudRecord
    var revision: Int
    var enqueuedAt: Date

    var key: String { record.key }
}

private final class LocalSyncStore {
    private let fileManager = FileManager.default
    private let snapshotURL: URL
    private let outboxURL: URL

    init() {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("GrocerSync", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        snapshotURL = directory.appendingPathComponent("snapshot.json")
        outboxURL = directory.appendingPathComponent("outbox.json")
    }

    func loadSnapshot() -> CloudSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? Self.decoder.decode(CloudSnapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: CloudSnapshot) {
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
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
        guard let data = try? Self.encoder.encode(ordered) else { return }
        try? data.write(to: outboxURL, options: .atomic)
    }

    func reset() {
        try? fileManager.removeItem(at: snapshotURL)
        try? fileManager.removeItem(at: outboxURL)
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
        joinedHouseholdId: String? = nil
    ) -> GroceryRepository {
        let repo = GroceryRepository()
        repo.households = households
        repo.members = members
        repo.joinedHouseholdId = joinedHouseholdId
        repo.hasCompletedInitialLoad = true
        return repo
    }
    #endif

    private(set) var households: [Household] = []
    private(set) var members: [HouseholdMember] = []
    private(set) var lists: [GroceryList] = []
    private(set) var items: [GroceryItem] = []
    private(set) var sessions: [ShoppingSession] = []
    private(set) var events: [ItemEvent] = []

    private(set) var selectedHouseholdId: String?

    /// Set after successfully joining a group; the UI shows a welcome sheet.
    var joinedHouseholdId: String?

    enum SyncState: Equatable { case idle, syncing, offline, error(String) }
    private(set) var syncState: SyncState = .idle
    private(set) var subscriptionStatus = CloudSubscriptionRegistrationResult(
        privateZoneRegistered: false,
        sharedDatabaseRegistered: false,
        errors: []
    )
    private(set) var usingCloudKit = false
    private(set) var hasCompletedInitialLoad = false

    private let cloud = CloudKitService.shared
    private let api = APIClient.shared
    private let liveActivity = LiveActivityManager.shared
    private let notifications = PushNotificationCoordinator.shared
    private let tripItemAlerts = ShoppingTripItemAddedAlertCoordinator.shared
    private let settings = SettingsStore.shared
    private let localStore = LocalSyncStore()
    private let shoppingTripInactivityLimit: TimeInterval = 60 * 60
    private var remoteRefreshTask: Task<Void, Never>?
    private var foregroundRefreshTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var lastActivationRefreshAt: Date?
    private var cloudWriteTask: Task<Void, Never>?
    private var pendingCloudWrites: [String: PendingCloudWrite] = [:]
    private var nextCloudWriteRevision = 0
    private var hasEstablishedTripItemAlertBaseline = false
    private var alertedTripItemIds: Set<String> = []

    // MARK: - Current selection

    var currentHousehold: Household? {
        households.first { $0.id == selectedHouseholdId } ?? households.first
    }

    /// The single (non-archived) list backing the current group.
    var currentList: GroceryList? {
        guard let hid = currentHousehold?.id else { return nil }
        return lists.first { $0.householdId == hid && !$0.archived }
    }

    var currentMembers: [HouseholdMember] {
        guard let hid = currentHousehold?.id else { return [] }
        return members
            .filter { $0.householdId == hid }
            .sorted(by: HouseholdMember.stableDisplayOrder)
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

    var isOwnerOfCurrentGroup: Bool {
        guard let h = currentHousehold else { return false }
        return h.ownerMemberId == currentMemberId
            || currentMembers.contains { $0.id == currentMemberId && $0.role == .owner }
    }

    var sharingUnavailableReason: String? {
        guard currentHousehold != nil else {
            return "Create a group before inviting members."
        }
        if case .error = syncState {
            return "iCloud sync is unavailable right now. Sharing will be available after this group syncs to iCloud."
        }
        guard usingCloudKit else {
            return "Sign in to iCloud to invite members. Group sharing needs CloudKit, which isn't available in this build/session."
        }
        switch syncState {
        case .idle:
            break
        case .syncing:
            return "Wait for iCloud sync to finish before inviting members."
        case .offline:
            return "Reconnect to iCloud before inviting members."
        case .error:
            return "iCloud sync is unavailable right now. Sharing will be available after this group syncs to iCloud."
        }
        guard isOwnerOfCurrentGroup else {
            return "Only the group owner can invite members."
        }
        return nil
    }

    var canShare: Bool { sharingUnavailableReason == nil }
    var displayName: String { currentMember?.displayName ?? settings.displayName }
    var profileImageData: Data? { currentMember?.profileImageData ?? settings.profileImageData }

    func selectHousehold(_ id: String) {
        selectedHouseholdId = id
        settings.selectedHouseholdId = id
        Task { await configureLiveActivity() }
    }

    // MARK: - Derived state (scoped to the current list)

    func activeSession(for listId: String?) -> ShoppingSession? {
        guard let listId else { return nil }
        return sessions.first { $0.listId == listId && $0.status == .active }
    }

    var activeSession: ShoppingSession? { activeSession(for: currentList?.id) }

    func isStartedByCurrentUser(_ session: ShoppingSession) -> Bool {
        let starter = Self.sanitizeRecordName(session.startedByMemberId)
        return starter == currentMemberId || session.startedByMemberId == settings.deviceId
    }

    func pendingItems(forList listId: String?) -> [GroceryItem] {
        guard let listId else { return [] }
        return items.filter { $0.listId == listId && $0.status == .needed }
            .sorted(by: GroceryItem.listDisplayOrder)
    }

    var pendingItems: [GroceryItem] { pendingItems(forList: currentList?.id) }

    var removedItems: [GroceryItem] {
        guard let listId = currentList?.id else { return [] }
        return items.filter { $0.listId == listId && $0.deletedAt == nil && ($0.status == .removed || $0.status == .found || $0.status == .replaced) }
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
        guard let listId = currentList?.id else { return [] }
        let pendingKeys = Set(pendingItems.map { $0.name.itemSuggestionKey })
        var seen = Set<String>()
        return items
            .filter { $0.listId == listId }
            .sorted {
                let lhsDate = Self.itemSuggestionDate(for: $0)
                let rhsDate = Self.itemSuggestionDate(for: $1)
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return GroceryItem.listDisplayOrder($0, $1)
            }
            .compactMap { item in
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
    }

    /// Distinct item names from this list that aren't currently pending — for "add again" UI.
    var pastItemNames: [String] {
        currentItemSuggestions
            .filter { !$0.isPending }
            .map(\.name)
    }

    private static func itemSuggestionDate(for item: GroceryItem) -> Date {
        item.completedAt ?? item.updatedAt
    }

    func addedDuringTrip(session: ShoppingSession) -> [GroceryItem] {
        items
            .filter { $0.listId == session.listId && $0.status == .needed && $0.createdAt > session.startedAt }
            .sorted(by: GroceryItem.listDisplayOrder)
    }

    func handledItems(session: ShoppingSession) -> [GroceryItem] {
        items
            .filter { $0.activeSessionId == session.id && $0.status != .needed }
            .sorted(by: GroceryItem.handledDisplayOrder)
    }

    func progress(for session: ShoppingSession) -> SessionProgress {
        let scoped = items.filter {
            $0.listId == session.listId && $0.status != .removed
                && ($0.status == .needed || $0.activeSessionId == session.id)
        }
        return SessionProgress(
            total: scoped.count,
            found: scoped.filter { $0.status == .found }.count,
            replaced: scoped.filter { $0.status == .replaced }.count,
            outOfStock: scoped.filter { $0.status == .outOfStock }.count,
            skipped: scoped.filter { $0.status == .skipped }.count,
            remaining: scoped.filter { $0.status == .needed }.count
        )
    }

    private func expireInactiveShoppingTrips(now: Date = Date()) async {
        let expired = sessions.filter { session in
            guard session.status == .active else { return false }
            return now.timeIntervalSince(lastActivityDate(for: session)) >= shoppingTripInactivityLimit
        }

        for session in expired {
            guard sessions.contains(where: { $0.id == session.id && $0.status == .active }) else { continue }
            print("[Repo] auto-ending inactive shopping session \(session.id)")
            await cancelShopping(session)
        }
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
        ShareCoordinator.shared.setHandler { [weak self] metadata in
            await self?.acceptShare(metadata)
        }

        selectedHouseholdId = settings.selectedHouseholdId.nilIfBlank
        print("[Repo] restored selectedHouseholdId: \(selectedHouseholdId ?? "nil")")
        loadLocalSyncState()

        syncState = .syncing
        print("[Repo] checking iCloud account status…")
        let status = await cloud.accountStatus()
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
                syncState = .error("Sync failed: \(Self.shortError(error))")
            } else {
                syncState = .error("Sync failed: \(Self.shortError(error))")
            }
        }
        hasCompletedInitialLoad = true
        await configureLiveActivity()
        print("[Repo] ── bootstrap END (sync=\(syncState)) ──")
    }

    func refresh() async throws {
        guard usingCloudKit else {
            print("[Repo] refresh skipped (not using CloudKit)")
            return
        }
        print("[Repo] refresh → fetching changes…")
        let changes = try await cloud.fetchChanges(forceFull: currentSnapshot().isEmpty)
        applySyncResult(changes)
        saveLocalSnapshot()
        print("[Repo] refresh → \(households.count) households, \(members.count) members, \(lists.count) lists, \(items.count) items, \(events.count) events")
        ensureValidSelection()
        ensureCurrentUserMemberRecords()
        syncPersonalProfileCache()
        await expireInactiveShoppingTrips()
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
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let ownedHouseholdIds = households
            .filter { $0.ownerMemberId == currentMemberId
                && ($0.recordOwnerName ?? CKCurrentUserDefaultName) == CKCurrentUserDefaultName }
            .map(\.id)
        guard !ownedHouseholdIds.isEmpty else {
            UserDefaults.standard.set(true, forKey: key)
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
            for event in events where event.householdId == hid {
                await fetchAndSave(event, type: CK.RecordType.event, id: event.id, householdId: hid)
            }
            for member in members where member.householdId == hid {
                await saveMemberBestEffort(member)
            }
        }
        UserDefaults.standard.set(true, forKey: key)
        print("[Repo] ✅ parent-ref backfill complete")
    }

    /// User-initiated pull-to-refresh. CloudKit silent pushes can be delayed
    /// (and are unreliable on the Simulator), so this gives an explicit way to
    /// pull the latest shared changes on demand.
    func manualRefresh() async {
        await refreshSnapshot(context: "Refresh failed", registerSubscriptions: true, showSyncing: true)
    }

    /// Refresh after the app becomes active. This is intentionally light-touch:
    /// subscriptions should do the real work, while foreground activation repairs
    /// any delayed silent pushes.
    func refreshAfterActivation() async {
        await refreshWhileForeground(force: true)
    }

    func startForegroundRefreshLoop() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = Task { [weak self] in
            await self?.refreshWhileForeground(force: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await self?.refreshWhileForeground(force: false)
            }
        }
    }

    func stopForegroundRefreshLoop() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = nil
    }

    private func refreshWhileForeground(force: Bool) async {
        guard hasCompletedInitialLoad else { return }
        let now = Date()
        if !force, let lastActivationRefreshAt,
           now.timeIntervalSince(lastActivationRefreshAt) < 5 {
            return
        }
        lastActivationRefreshAt = now
        if usingCloudKit {
            await refreshSnapshot(context: "Foreground refresh failed", registerSubscriptions: false, showSyncing: false)
        } else {
            await expireInactiveShoppingTrips(now: now)
        }
    }

    /// Called when CloudKit delivers a silent push after a subscription fires.
    /// Debounced so bursts of changes coalesce into one refresh.
    func handleRemoteNotification() async {
        guard usingCloudKit else { return }
        remoteRefreshTask?.cancel()
        remoteRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            print("[Repo] remote notification → refreshing…")
            await refreshSnapshot(context: "Remote refresh failed", registerSubscriptions: true, showSyncing: true)
        }
        await remoteRefreshTask?.value
    }

    private func refreshSnapshot(context: String, registerSubscriptions: Bool, showSyncing: Bool) async {
        guard usingCloudKit else { return }
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }

        if showSyncing { syncState = .syncing }
        do {
            try await refresh()
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
    }

    private func registerForRealtimeSync(force: Bool = false) async {
        guard usingCloudKit else { return }
        subscriptionStatus = await cloud.registerSubscriptions(force: force)
        guard !subscriptionStatus.isFullyRegistered else { return }
        syncState = .error("CloudKit subscriptions failed. Pull to refresh still works.")
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
        let householdMembers = members
            .filter { $0.householdId == household.id }
            .sorted(by: HouseholdMember.stableDisplayOrder)
        return householdMembers.first { $0.id == currentMemberId }
            ?? householdMembers.first { $0.role == .owner }
            ?? householdMembers.first
    }

    private func syncPersonalProfileCache() {
        guard let member = currentMembers.first(where: { $0.id == currentMemberId }) else { return }
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
            syncState = .error("Couldn't save group: \(Self.shortError(error))")
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

        if usingCloudKit {
            print("[Repo] queueing new group records for CloudKit…")
            enqueueSave(.household(house))
            enqueueSave(.member(member))
            enqueueSave(.list(list))
            await flushOutbox()
            if !pendingCloudWrites.keys.contains(PendingCloudRecord.household(house).key),
               !pendingCloudWrites.keys.contains(PendingCloudRecord.member(member).key),
               !pendingCloudWrites.keys.contains(PendingCloudRecord.list(list).key) {
                syncState = .idle
                print("[Repo] ✅ group saved to CloudKit")
            }
        } else {
            saveLocalSnapshot()
        }
        return house
    }

    /// Update the current group's appearance (name, store, icon, theme).
    func updateGroup(name: String, store: String?, icon: String, theme: ListColorTheme) {
        guard isOwnerOfCurrentGroup else {
            syncState = .error("Only the group owner can edit group details.")
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

    func renameGroup(_ name: String) {
        guard isOwnerOfCurrentGroup else {
            syncState = .error("Only the group owner can rename this group.")
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
            syncState = .error("Only the group owner can remove members.")
            return
        }
        guard let household = households.first(where: { $0.id == member.householdId }) else { return }
        guard member.role != .owner else { return }
        members.removeAll { $0.id == member.id && $0.householdId == member.householdId }
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

    func leaveCurrentGroup() {
        guard let house = currentHousehold else { return }
        let me = currentMember
        households.removeAll { $0.id == house.id }
        lists.removeAll { $0.householdId == house.id }
        items.removeAll { $0.householdId == house.id }
        events.removeAll { $0.householdId == house.id }
        if let me { members.removeAll { $0.id == me.id && $0.householdId == house.id } }
        selectedHouseholdId = households.first?.id
        ensureValidSelection()
        if usingCloudKit, let me {
            enqueueDelete(.member(me))
        } else {
            saveLocalSnapshot()
        }
    }

    // MARK: - Item CRUD

    @discardableResult
    func addItem(name: String, quantity: String?, category: GroceryCategory,
                 notes: String?, priority: ItemPriority = .normal,
                 replacementPreference: String?) -> GroceryItem? {
        guard let household = currentHousehold, let list = currentList else { return nil }
        let now = Date()
        let member = currentMember
        let item = GroceryItem(
            id: cloud.makeRecordID().recordName,
            householdId: household.id, listId: list.id,
            name: name, quantity: quantity?.nilIfBlank, category: category, notes: notes?.nilIfBlank,
            requestedByMemberId: member?.id ?? settings.deviceId,
            requestedByDisplayName: member?.displayName ?? settings.displayName,
            status: .needed, priority: priority,
            replacementPreference: replacementPreference?.nilIfBlank,
            replacementItemName: nil, createdAt: now, updatedAt: now, completedAt: nil, deletedAt: nil,
            activeSessionId: activeSession(for: list.id)?.id
        )
        items.append(item)
        persist(item)
        if let session = activeSession(for: list.id) {
            logEvent(.itemAdded, householdId: item.householdId, itemId: item.id, sessionId: session.id,
                     metadata: ["name": item.name])
            pushLiveActivityUpdate(for: session, lastItem: item, lastStatus: nil)
        } else {
            logEvent(.itemAdded, householdId: item.householdId, itemId: item.id, metadata: ["name": item.name])
        }
        // Prewarm the product image so it's a cache hit by the time it's viewed.
        Task { await api.prewarmImages([item.name]) }
        return item
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
        let groupStore = households.first { $0.id == list.householdId }?.storeName
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
        liveActivity.endLocalActivity(content: contentState(for: ended, overrideStatus: .completed))
        applyCleanup(session: session, clearCompleted: clearCompleted, keepOutOfStock: keepOutOfStock)
        Task { await api.endLiveActivity(payload) }
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
        liveActivity.endLocalActivity(content: contentState(for: cancelled, overrideStatus: .cancelled))
        Task { await api.endLiveActivity(payload) }
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
                }
            case .outOfStock:
                if !keepOutOfStock {
                    item.status = .needed
                    item.completedAt = nil
                    item.deletedAt = nil
                    changed.append(item)
                }
            case .skipped:
                item.status = .needed
                item.completedAt = nil
                item.deletedAt = nil
                changed.append(item)
            default: break
            }
            item.activeSessionId = nil
            return item
        }
        changed.forEach { persist($0) }
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
        liveActivity.updateLocalActivity(content: content)
        let payload = updatePayload(session: session, content: content)
        Task { await api.updateLiveActivity(payload) }
    }

    private func startPayload(session: ShoppingSession, content: GroceryActivityAttributes.ContentState) -> StartLiveActivityPayload {
        StartLiveActivityPayload(
            householdId: session.householdId, sessionId: session.id,
            sourceDeviceId: settings.deviceId,
            storeName: content.storeName, shopperName: content.shopperName, status: content.status,
            itemsFound: content.itemsFound, itemsRemaining: content.itemsRemaining, totalItems: content.totalItems,
            outOfStockCount: content.outOfStockCount, replacedCount: content.replacedCount,
            lastHandledItemName: content.lastHandledItemName, lastHandledItemStatus: content.lastHandledItemStatus,
            startedAt: ISO8601DateFormatter().string(from: session.startedAt)
        )
    }

    private func updatePayload(session: ShoppingSession, content: GroceryActivityAttributes.ContentState) -> UpdateLiveActivityPayload {
        UpdateLiveActivityPayload(
            householdId: session.householdId, sessionId: session.id,
            storeName: content.storeName, shopperName: content.shopperName, status: content.status,
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
            storeName: session.storeName,
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
            households = []; members = []; lists = []; items = []; sessions = []; events = []
            hasCompletedInitialLoad = false
            await bootstrap()
            return
        }
        try await cloud.deleteZone()
        resetLocalSyncState()
        households = []; members = []; lists = []; items = []; sessions = []; events = []
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
            events: events
        )
    }

    private func loadLocalSyncState() {
        pendingCloudWrites = localStore.loadOutbox()
        nextCloudWriteRevision = (pendingCloudWrites.values.map(\.revision).max() ?? 0) + 1
        guard var snapshot = localStore.loadSnapshot(), !snapshot.isEmpty else { return }
        applyPendingWrites(to: &snapshot)
        applySnapshot(snapshot)
        ensureValidSelection()
        hasCompletedInitialLoad = true
        print("[Repo] loaded local cache — \(households.count) group(s), \(items.count) item(s), \(pendingCloudWrites.count) pending write(s)")
    }

    private func saveLocalSnapshot() {
        localStore.saveSnapshot(currentSnapshot())
        localStore.saveOutbox(pendingCloudWrites)
    }

    private func applySnapshot(_ snapshot: CloudSnapshot) {
        // Only assign when the value actually changed. `@Observable` fires a
        // mutation on every assignment regardless of equality, so writing an
        // identical array here would needlessly re-render every observing view.
        // With the ~5s foreground refresh loop that meant the toolbar group
        // menu (and its liquid-glass material) visibly flashed each cycle.
        assignIfChanged(&households, snapshot.households.sorted(by: Household.stableDisplayOrder))
        assignIfChanged(&members, snapshot.members.sorted(by: HouseholdMember.stableDisplayOrder))
        assignIfChanged(&lists, snapshot.lists.sorted(by: GroceryList.stableDisplayOrder))
        assignIfChanged(&items, snapshot.items.sorted(by: GroceryItem.listDisplayOrder))
        assignIfChanged(&sessions, snapshot.sessions.sorted(by: ShoppingSession.stableDisplayOrder))
        assignIfChanged(&events, snapshot.events.sorted(by: ItemEvent.stableDisplayOrder))
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
        snapshot.removeRecords(in: result.fullZones)
        snapshot.upsert(contentsOf: result.snapshot)
        for deletion in result.deletions {
            snapshot.remove(deletion)
        }
        applyPendingWrites(to: &snapshot)
        applySnapshot(snapshot)

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
            saveLocalSnapshot()
            return
        }
        pendingCloudWrites[write.key] = write
        saveLocalSnapshot()
        scheduleOutboxFlush()
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
        guard usingCloudKit else { return }
        let previous = cloudWriteTask
        cloudWriteTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.flushOutbox()
        }
    }

    private func flushOutbox() async {
        guard usingCloudKit, !pendingCloudWrites.isEmpty else { return }
        let writes = pendingCloudWrites.values.sorted {
            if $0.revision != $1.revision { return $0.revision < $1.revision }
            return $0.enqueuedAt < $1.enqueuedAt
        }
        for write in writes {
            guard pendingCloudWrites[write.key] == write else { continue }
            let succeeded = await perform(write)
            guard pendingCloudWrites[write.key] == write else { continue }
            if succeeded {
                pendingCloudWrites.removeValue(forKey: write.key)
                saveLocalSnapshot()
            }
        }
    }

    private func perform(_ write: PendingCloudWrite) async -> Bool {
        switch write.operation {
        case .save:
            return await savePendingRecord(write.record)
        case .delete:
            return await deletePendingRecord(write.record)
        }
    }

    private func savePendingRecord(_ pending: PendingCloudRecord) async -> Bool {
        guard usingCloudKit else { return false }
        let rid = recordID(for: pending)
        let record: CKRecord
        do {
            record = try await cloud.record(for: rid)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: pending.recordType, recordID: rid)
        } catch {
            print("[Repo] ⚠️ fetch deferred for \(pending.recordType) \(pending.recordName): \(error)")
            recordSyncFailure(error, context: "Save \(pending.recordType) failed")
            return false
        }
        pending.apply(to: record)
        if let householdId = pending.householdId, pending.recordType != CK.RecordType.household {
            setHouseholdParent(record, householdId: householdId)
        }
        return await saveBestEffort(record)
    }

    private func deletePendingRecord(_ pending: PendingCloudRecord) async -> Bool {
        await deleteBestEffort(recordID: recordID(for: pending), context: "Delete \(pending.recordType) failed")
    }

    @discardableResult
    private func fetchAndSave<T: CloudKitApplicable>(_ model: T, type: String, id: String, householdId: String? = nil) async -> Bool {
        let rid = householdId.map { childRecordID(id, householdId: $0) } ?? cloud.makeRecordID(id)
        let record: CKRecord
        do {
            record = try await cloud.record(for: rid)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: type, recordID: rid)
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
            do {
                let serverRecord = try await cloud.record(for: r.recordID)
                for key in r.allKeys() { serverRecord[key] = r[key] }
                print("[Repo] ↻ retrying save for \(r.recordType) \(r.recordID.recordName) after conflict")
                return await saveBestEffort(serverRecord, retried: true)
            } catch {
                print("[Repo] ⚠️ conflict retry fetch failed for \(r.recordType) \(r.recordID.recordName): \(error)")
                recordSyncFailure(error, context: "Conflict retry failed")
                return false
            }
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
        } catch {
            print("[Repo] ⚠️ member fetch deferred: \(error)")
            recordSyncFailure(error, context: "Save member failed")
            return
        }

        member.apply(to: record)
        setHouseholdParent(record, householdId: member.householdId)
        await saveBestEffort(record)
    }

    @discardableResult
    private func deleteBestEffort(recordID: CKRecord.ID, context: String) async -> Bool {
        do {
            try await cloud.delete(recordID: recordID)
            if syncState != .idle { syncState = .idle }
            return true
        } catch let error as CKError where error.code == .unknownItem {
            print("[Repo] delete ignored missing record \(recordID.recordName)")
            if syncState != .idle { syncState = .idle }
            return true
        } catch {
            print("[Repo] ⚠️ delete failed for \(recordID.recordName): \(error)")
            recordSyncFailure(error, context: context)
            return false
        }
    }

    private func recordSyncFailure(_ error: Error, context: String) {
        if Self.isConnectivityError(error) {
            syncState = .offline
        } else {
            syncState = .error("\(context): \(Self.shortError(error))")
        }
    }

    private func resetLocalSyncState() {
        cloud.clearSubscriptionRegistrationFlag()
        UserDefaults.standard.removeObject(forKey: "grocer.migration.parentRefs.v1")
        UserDefaults.standard.removeObject(forKey: "grocer.migration.parentRefs.v2")
        cloudWriteTask?.cancel()
        cloudWriteTask = nil
        pendingCloudWrites.removeAll()
        nextCloudWriteRevision = 0
        localStore.reset()
        subscriptionStatus = CloudSubscriptionRegistrationResult(
            privateZoneRegistered: false,
            sharedDatabaseRegistered: false,
            errors: []
        )
        lastActivationRefreshAt = nil
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

private extension SettingsStore {
    var memberId: String {
        get { UserDefaults.standard.string(forKey: "grocer.memberId") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "grocer.memberId") }
    }
    var memberIdOrDevice: String { memberId.isEmpty ? deviceId : memberId }

    var selectedHouseholdId: String {
        get { UserDefaults.standard.string(forKey: "grocer.selectedHouseholdId") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "grocer.selectedHouseholdId") }
    }
}
