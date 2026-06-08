import CloudKit
import Foundation
import Observation

/// Central observable store for the family grocery space.
///
/// CloudKit is the source of truth. This repository keeps an in-memory working
/// set (the cache the UI binds to), loads it from CloudKit on launch, and
/// writes every mutation back best-effort. When CloudKit is unavailable (no
/// iCloud account, schema not created, offline first run) it seeds local
/// sample data so the app is fully usable, and sync resumes later.
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

    private(set) var households: [Household] = []
    private(set) var members: [HouseholdMember] = []
    private(set) var lists: [GroceryList] = []
    private(set) var items: [GroceryItem] = []
    private(set) var sessions: [ShoppingSession] = []
    private(set) var events: [ItemEvent] = []

    private(set) var selectedHouseholdId: String?

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
    private let settings = SettingsStore.shared
    private let shoppingTripInactivityLimit: TimeInterval = 60 * 60
    private var remoteRefreshTask: Task<Void, Never>?
    private var foregroundRefreshTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var lastActivationRefreshAt: Date?
    private var cloudWriteTask: Task<Void, Never>?
    private var pendingItemSaves: [String: GroceryItem] = [:]
    private var pendingItemDeletes = Set<String>()
    private var pendingItemWriteVersions: [String: Int] = [:]

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
        return members.filter { $0.householdId == hid }.sorted { $0.joinedAt < $1.joinedAt }
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
        currentMembers.first { $0.id == currentMemberId }
            ?? currentMembers.first { $0.role == .owner }
            ?? currentMembers.first
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
            .sorted { $0.createdAt < $1.createdAt }
    }

    var pendingItems: [GroceryItem] { pendingItems(forList: currentList?.id) }

    var removedItems: [GroceryItem] {
        guard let listId = currentList?.id else { return [] }
        return items.filter { $0.listId == listId && ($0.status == .removed || $0.status == .found || $0.status == .replaced) }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
    }

    var currentAuditEvents: [ItemEvent] {
        guard let householdId = currentHousehold?.id else { return [] }
        return events
            .filter { $0.householdId == householdId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Distinct item names from this list that aren't currently pending — for "add again" UI.
    var pastItemNames: [String] {
        guard let listId = currentList?.id else { return [] }
        let pendingNames = Set(pendingItems.map(\.name))
        var seen = Set<String>()
        return items
            .filter { $0.listId == listId && !pendingNames.contains($0.name) && $0.status != .needed }
            .sorted { ($0.completedAt ?? $0.updatedAt) > ($1.completedAt ?? $1.updatedAt) }
            .compactMap { item in
                let lower = item.name.lowercased()
                guard !seen.contains(lower) else { return nil }
                seen.insert(lower)
                return item.name
            }
    }

    func addedDuringTrip(session: ShoppingSession) -> [GroceryItem] {
        items.filter { $0.listId == session.listId && $0.status == .needed && $0.createdAt > session.startedAt }
    }

    func handledItems(session: ShoppingSession) -> [GroceryItem] {
        items.filter { $0.activeSessionId == session.id && $0.status != .needed }
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

        syncState = .syncing
        print("[Repo] checking iCloud account status…")
        let status = await cloud.accountStatus()
        guard status == .available else {
            print("[Repo] ⚠️ iCloud not available (status=\(status.rawValue)), using sample data")
            usingCloudKit = false
            seedSampleData()
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

            print("[Repo] step 2: refresh (fetch all records)…")
            try await refresh()

            print("[Repo] step 3: households=\(households.count), checking if empty…")
            if households.isEmpty {
                print("[Repo] no households found, creating default group…")
                try await createDefaultGroup()
            }
            ensureValidSelection()
            syncState = .idle
            print("[Repo] ✅ bootstrap succeeded — \(households.count) group(s), sync=idle")
            await registerForRealtimeSync()
        } catch {
            print("[Repo] ❌ bootstrap failed: \(error)")
            if households.isEmpty {
                print("[Repo] trying fallback: create default group despite error…")
                do {
                    try await createDefaultGroup()
                    ensureValidSelection()
                    syncState = .idle
                    print("[Repo] ✅ fallback group created OK")
                    await registerForRealtimeSync()
                } catch {
                    print("[Repo] ❌ fallback group creation also failed: \(error)")
                    syncState = .error("Sync failed: \(Self.shortError(error))")
                }
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
        print("[Repo] refresh → fetching snapshot…")
        let snapshot = try await cloud.fetchSnapshot()
        applySnapshot(snapshot)
        print("[Repo] refresh → \(households.count) households, \(members.count) members, \(lists.count) lists, \(items.count) items, \(events.count) events")
        ensureValidSelection()
        ensureCurrentUserMemberRecords()
        syncPersonalProfileCache()
        await expireInactiveShoppingTrips()
        await backfillParentReferencesIfNeeded()
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
        guard let household = currentHousehold, let member = currentMember else { return }
        liveActivity.configure(householdId: household.id, memberId: member.id)
        notifications.configure(householdId: household.id, memberId: member.id)
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
        // Save sequentially — all members share the same record ID, so parallel
        // saves race and produce "record already exists" conflicts.
        if !added.isEmpty {
            Task {
                for member in added {
                    await saveMemberBestEffort(member)
                }
            }
        }
    }

    // MARK: - Group management (a group is the list)

    private func createDefaultGroup() async throws {
        if let userRecordName = await cloud.currentUserRecordName() {
            settings.memberId = Self.sanitizeRecordName(userRecordName)
        }
        _ = try await makeGroup(name: "My Groceries", store: nil,
                                icon: GROUP_ICON_CHOICES[0], theme: .default)
    }

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
            print("[Repo] saving new group to CloudKit…")
            let houseRecord = CKRecord(recordType: CK.RecordType.household, recordID: cloud.makeRecordID(house.id))
            house.apply(to: houseRecord)
            let memberRecord = CKRecord(recordType: CK.RecordType.member, recordID: recordID(for: member))
            member.apply(to: memberRecord)
            setHouseholdParent(memberRecord, householdId: house.id)
            let listRecord = CKRecord(recordType: CK.RecordType.list, recordID: cloud.makeRecordID(list.id))
            list.apply(to: listRecord)
            setHouseholdParent(listRecord, householdId: house.id)

            _ = try await cloud.saveToPrivateZone([houseRecord, memberRecord, listRecord])
            syncState = .idle
            print("[Repo] ✅ group saved to CloudKit")
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
        guard usingCloudKit else { return }
        Task {
            do {
                let names = Set([member.id, member.iCloudUserRecordName].compactMap { $0?.nilIfBlank })
                _ = try await cloud.revokeParticipant(
                    matching: names,
                    from: householdRecordID(household)
                )
                await deleteBestEffort(recordID: recordID(for: member), context: "Remove member failed")
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
            Task { await deleteBestEffort(recordID: recordID(for: me), context: "Leave group failed") }
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
            replacementItemName: nil, createdAt: now, updatedAt: now, completedAt: nil,
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
        updated.activeSessionId = nil
        updated.updatedAt = Date()
        replaceInWorkingSet(updated)
        persist(updated)
        logEvent(.itemEdited, householdId: item.householdId, itemId: item.id,
                 sessionId: activeSession(for: item.listId)?.id,
                 metadata: ["name": updated.name, "status": updated.status.rawValue])
    }

    func delete(_ item: GroceryItem) {
        items.removeAll { $0.id == item.id }
        persistDeletion(item)
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
        var deleted: [GroceryItem] = []
        items = items.compactMap { item in
            guard item.listId == session.listId else { return item }
            var item = item
            switch item.status {
            case .found, .replaced:
                if clearCompleted {
                    deleted.append(item)
                    return nil
                }
            case .outOfStock:
                if !keepOutOfStock { item.status = .needed; item.completedAt = nil; changed.append(item) }
            case .skipped:
                item.status = .needed; item.completedAt = nil; changed.append(item)
            default: break
            }
            item.activeSessionId = nil
            return item
        }
        changed.forEach { persist($0) }
        deleted.forEach { persistDeletion($0) }
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

    func acceptShare(_ metadata: CKShare.Metadata) async {
        do {
            try await cloud.accept(metadata)
            try await refresh()
            await registerForRealtimeSync(force: true)
            await configureLiveActivity()
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

    private func applySnapshot(_ snapshot: CloudSnapshot) {
        households = snapshot.households
        members = snapshot.members
        lists = snapshot.lists
        items = mergePendingItemChanges(into: snapshot.items)
        sessions = snapshot.sessions
        events = snapshot.events
    }

    private func mergePendingItemChanges(into snapshotItems: [GroceryItem]) -> [GroceryItem] {
        guard !pendingItemSaves.isEmpty || !pendingItemDeletes.isEmpty else {
            return snapshotItems
        }

        var merged: [String: GroceryItem] = [:]
        for item in snapshotItems {
            if let existing = merged[item.id], existing.updatedAt > item.updatedAt {
                continue
            }
            merged[item.id] = item
        }

        for id in pendingItemDeletes {
            merged.removeValue(forKey: id)
        }
        for item in pendingItemSaves.values {
            merged[item.id] = item
        }
        return Array(merged.values)
    }

    private func persist(_ item: GroceryItem) {
        guard usingCloudKit else { return }
        let version = nextItemWriteVersion(for: item.id)
        pendingItemSaves[item.id] = item
        pendingItemDeletes.remove(item.id)
        enqueueCloudWrite { [weak self] in
            await self?.savePendingItem(item, version: version)
        }
    }

    private func persistDeletion(_ item: GroceryItem) {
        guard usingCloudKit else { return }
        let version = nextItemWriteVersion(for: item.id)
        pendingItemSaves.removeValue(forKey: item.id)
        pendingItemDeletes.insert(item.id)
        enqueueCloudWrite { [weak self] in
            await self?.deletePendingItem(item, version: version)
        }
    }

    private func persist(_ session: ShoppingSession) {
        guard usingCloudKit else { return }
        Task { await fetchAndSave(session, type: CK.RecordType.session, id: session.id, householdId: session.householdId) }
    }
    private func persist(_ member: HouseholdMember) {
        guard usingCloudKit else { return }
        Task { await saveMemberBestEffort(member) }
    }
    private func persistHousehold(_ house: Household) {
        guard usingCloudKit else { return }
        Task {
            let rid = householdRecordID(house)
            let record: CKRecord
            do {
                record = try await cloud.record(for: rid)
            } catch let error as CKError where error.code == .unknownItem {
                record = CKRecord(recordType: CK.RecordType.household, recordID: rid)
            } catch {
                print("[Repo] ⚠️ household fetch deferred: \(error)")
                recordSyncFailure(error, context: "Save group failed")
                return
            }
            house.apply(to: record)
            await saveBestEffort(record)
        }
    }

    private func enqueueCloudWrite(_ operation: @escaping () async -> Void) {
        let previous = cloudWriteTask
        cloudWriteTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    private func nextItemWriteVersion(for id: String) -> Int {
        let version = (pendingItemWriteVersions[id] ?? 0) + 1
        pendingItemWriteVersions[id] = version
        return version
    }

    private func savePendingItem(_ item: GroceryItem, version: Int) async {
        guard pendingItemWriteVersions[item.id] == version,
              pendingItemSaves[item.id] == item else {
            return
        }

        let saved = await fetchAndSave(item, type: CK.RecordType.item, id: item.id, householdId: item.householdId)
        guard pendingItemWriteVersions[item.id] == version else { return }
        if saved {
            pendingItemSaves.removeValue(forKey: item.id)
            pendingItemWriteVersions.removeValue(forKey: item.id)
        }
    }

    private func deletePendingItem(_ item: GroceryItem, version: Int) async {
        guard pendingItemWriteVersions[item.id] == version,
              pendingItemDeletes.contains(item.id) else {
            return
        }

        let deleted = await deleteBestEffort(
            recordID: childRecordID(item.id, householdId: item.householdId),
            context: "Delete item failed"
        )
        guard pendingItemWriteVersions[item.id] == version else { return }
        if deleted {
            pendingItemDeletes.remove(item.id)
            pendingItemWriteVersions.removeValue(forKey: item.id)
        }
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
        pendingItemSaves.removeAll()
        pendingItemDeletes.removeAll()
        pendingItemWriteVersions.removeAll()
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
        guard usingCloudKit else { return }
        Task { await saveBestEffort(newRecord(event, type: CK.RecordType.event, id: event.id, householdId: event.householdId)) }
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

    // MARK: - Sample data (CloudKit unavailable)

    private func seedSampleData() {
        let now = Date()
        let meId = "sample-me"
        settings.memberId = meId

        // Group 1: Home (green, Meijer)
        let home = Household(id: "group-home", name: "Home", ownerMemberId: meId,
                             storeName: "Meijer", icon: "cart.fill", colorTheme: .green,
                             createdAt: now, updatedAt: now, recordZoneName: nil, recordOwnerName: nil)
        let homeMe = HouseholdMember(id: meId, householdId: home.id, displayName: settings.displayName,
                                     profileImageData: settings.profileImageData, iCloudUserRecordName: nil,
                                     role: .owner, joinedAt: now, recordZoneName: nil, recordOwnerName: nil)
        let alex = HouseholdMember(id: "sample-alex", householdId: home.id, displayName: "Alex",
                                   profileImageData: nil, iCloudUserRecordName: nil, role: .member,
                                   joinedAt: now, recordZoneName: nil, recordOwnerName: nil)
        let homeList = GroceryList(id: "list-home", householdId: home.id, name: DEFAULT_LIST_NAME,
                                   createdAt: now, updatedAt: now, archived: false)

        // Group 2: Lake House (teal, Local Market)
        let lake = Household(id: "group-lake", name: "Lake House", ownerMemberId: meId,
                             storeName: "Local Market", icon: "takeoutbag.and.cup.and.straw.fill",
                             colorTheme: .teal, createdAt: now, updatedAt: now,
                             recordZoneName: nil, recordOwnerName: nil)
        let lakeMe = HouseholdMember(id: meId, householdId: lake.id, displayName: settings.displayName,
                                     profileImageData: settings.profileImageData, iCloudUserRecordName: nil,
                                     role: .owner, joinedAt: now, recordZoneName: nil, recordOwnerName: nil)
        let lakeList = GroceryList(id: "list-lake", householdId: lake.id, name: DEFAULT_LIST_NAME,
                                   createdAt: now, updatedAt: now, archived: false)
        let sampleSession = ShoppingSession(
            id: "session-home-sample",
            householdId: home.id,
            listId: homeList.id,
            startedByMemberId: alex.id,
            startedByDisplayName: alex.displayName,
            storeName: home.storeName,
            startedAt: now.addingTimeInterval(-7200),
            endedAt: now.addingTimeInterval(-5400),
            updatedAt: now.addingTimeInterval(-5400),
            status: .completed
        )

        func item(_ id: String, _ name: String, _ qty: String?, _ cat: GroceryCategory,
                  list: GroceryList, by: HouseholdMember, _ notes: String? = nil) -> GroceryItem {
            GroceryItem(id: "item-\(id)", householdId: list.householdId, listId: list.id,
                        name: name, quantity: qty, category: cat, notes: notes,
                        requestedByMemberId: by.id, requestedByDisplayName: by.displayName,
                        status: .needed, priority: .normal,
                        replacementPreference: nil, replacementItemName: nil,
                        createdAt: now.addingTimeInterval(Double.random(in: -50000 ... -100)),
                        updatedAt: now, completedAt: nil, activeSessionId: nil)
        }

        func event(_ id: String, _ type: ItemEventType, household: Household,
                   itemId: String? = nil, sessionId: String? = nil,
                   by member: HouseholdMember, offset: TimeInterval,
                   metadata: [String: String] = [:]) -> ItemEvent {
            ItemEvent(
                id: "event-\(id)",
                householdId: household.id,
                itemId: itemId,
                sessionId: sessionId,
                type: type,
                createdByMemberId: member.id,
                createdByDisplayName: member.displayName,
                createdAt: now.addingTimeInterval(offset),
                metadata: metadata
            )
        }

        households = [home, lake]
        members = [homeMe, alex, lakeMe]
        lists = [homeList, lakeList]
        items = [
            item("1", "Bananas", "1 bunch", .produce, list: homeList, by: homeMe),
            item("2", "Strawberries", "Any brand", .produce, list: homeList, by: alex, "Organic if available"),
            item("3", "Milk", "1 gallon", .dairy, list: homeList, by: homeMe, "2%"),
            item("4", "Eggs", "1 dozen", .dairy, list: homeList, by: alex),
            item("5", "Chicken Breast", "2 lbs", .meatSeafood, list: homeList, by: alex),
            item("6", "Bread", nil, .bakery, list: homeList, by: homeMe),
            item("7", "Paper Towels", "12 pack", .household, list: homeList, by: homeMe),
            item("8", "Sunscreen", "SPF 50", .personalCare, list: lakeList, by: lakeMe),
            item("9", "Charcoal", nil, .household, list: lakeList, by: lakeMe),
            item("10", "Hot Dogs", "2 packs", .meatSeafood, list: lakeList, by: lakeMe),
        ]
        sessions = [sampleSession]
        events = [
            event("home-session-start", .sessionStarted, household: home,
                  sessionId: sampleSession.id, by: alex, offset: -7200,
                  metadata: ["store": sampleSession.storeName ?? ""]),
            event("home-session-complete", .sessionCompleted, household: home,
                  sessionId: sampleSession.id, by: alex, offset: -5400),
            event("home-bananas-added", .itemAdded, household: home,
                  itemId: "item-1", by: homeMe, offset: -3600,
                  metadata: ["name": "Bananas"]),
            event("home-strawberries-added", .itemAdded, household: home,
                  itemId: "item-2", by: alex, offset: -3000,
                  metadata: ["name": "Strawberries"]),
            event("lake-sunscreen-added", .itemAdded, household: lake,
                  itemId: "item-8", by: lakeMe, offset: -1800,
                  metadata: ["name": "Sunscreen"]),
        ]
        ensureValidSelection()
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
