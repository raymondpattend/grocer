import XCTest

final class SyncSourceGuardrailTests: XCTestCase {
    func testSavingChildRecordsSetsHouseholdParentBeforeCloudKitSave() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")

        let buildRecord = try excerpt(repo, from: "private func buildRecord(for pending", to: "/// Applies a pending record's fields")
        XCTAssertTrue(buildRecord.contains("pending.recordType != CK.RecordType.household"))
        XCTAssertTrue(buildRecord.contains("setHouseholdParent(record, householdId: householdId)"))

        let fetchAndSave = try excerpt(repo, from: "private func fetchAndSave", to: "@discardableResult\n    private func saveBestEffort")
        XCTAssertTrue(fetchAndSave.contains("if let householdId { setHouseholdParent(record, householdId: householdId) }"))

        let saveMember = try excerpt(repo, from: "private func saveMemberBestEffort", to: "private func recordSyncFailure")
        XCTAssertTrue(saveMember.contains("setHouseholdParent(record, householdId: member.householdId)"))
    }

    func testChangeTokenExpiryClearsTokenAndRefetchesFullZone() throws {
        let cloud = try source("Grocer/Services/CloudKitService.swift")
        let accumulate = try excerpt(cloud, from: "private func accumulate", to: "// MARK: - Save / delete")

        XCTAssertTrue(accumulate.contains("error.code == .changeTokenExpired"))
        XCTAssertTrue(accumulate.contains("clearChangeToken(for: zoneRef)"))
        XCTAssertTrue(accumulate.contains("result.markFullZone(zoneRef)"))
        XCTAssertTrue(accumulate.contains("var changeToken: CKServerChangeToken?"))
    }

    func testSharedZoneDisappearanceRequiresTwoConsecutiveMisses() throws {
        let cloud = try source("Grocer/Services/CloudKitService.swift")
        let reconcile = try excerpt(cloud, from: "private func reconcileVanishedSharedZones", to: "private func accumulate")

        let confirmedMiss = try excerpt(reconcile, from: "if suspectedVanishedSharedZones.contains(missing) {", to: "} else {")
        XCTAssertTrue(confirmedMiss.contains("result.markVanishedZone(missing)"))
        XCTAssertTrue(confirmedMiss.contains("clearChangeToken(for: missing)"))
        XCTAssertTrue(confirmedMiss.contains("suspectedVanishedSharedZones.remove(missing)"))

        let firstMiss = try excerpt(reconcile, from: "} else {", to: "saveKnownSharedZones(persistedZones)")
        XCTAssertTrue(firstMiss.contains("suspectedVanishedSharedZones.insert(missing)"))
        XCTAssertTrue(firstMiss.contains("persistedZones.insert(missing)"))
        XCTAssertLessThan(
            try sourceIndex(of: "suspectedVanishedSharedZones.subtract(liveRefs)", in: reconcile),
            try sourceIndex(of: "for missing in loadKnownSharedZones().subtracting(liveRefs)", in: reconcile)
        )
        XCTAssertTrue(reconcile.contains("saveKnownSharedZones(persistedZones)"))
    }

    func testRealtimeFetchCanUseKnownSharedZonesWithoutRediscovery() throws {
        let cloud = try source("Grocer/Services/CloudKitService.swift")
        let fetch = try excerpt(cloud, from: "func fetchChanges", to: "/// Detects shared zones")
        let hotPath = try excerpt(
            fetch,
            from: "let zones = knownSharedZoneIDs()",
            to: "} else {\n            print(\"[CK]   ⚠️ no sharedDB"
        )
        let knownZones = try excerpt(cloud, from: "private func knownSharedZoneIDs", to: "private func accumulate")

        XCTAssertTrue(fetch.contains("discoverSharedZones: Bool = true"))
        XCTAssertTrue(fetch.contains("if discoverSharedZones {"))
        XCTAssertTrue(fetch.contains("knownSharedZoneIDs()"))
        XCTAssertTrue(hotPath.contains("try await accumulate(from: sharedDB, into: &result, scope: zones, label: \"shared\", forceFull: forceFull)"))
        XCTAssertTrue(knownZones.contains("loadKnownSharedZones()"))
        XCTAssertTrue(knownZones.contains("CKRecordZone.ID(zoneName: $0.zoneName, ownerName: $0.ownerName)"))
    }

    func testApplySyncResultPurgesVanishedZoneWritesBeforePendingOverlay() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let applySyncResult = try excerpt(repo, from: "private func applySyncResult", to: "private func alertForNewActiveTripItems")

        XCTAssertLessThan(
            try sourceIndex(of: "let removedHouseholdIds = snapshot.householdIds(in: result.vanishedZones)", in: applySyncResult),
            try sourceIndex(of: "purgePendingWrites(forHouseholds: removedHouseholdIds)", in: applySyncResult)
        )
        XCTAssertLessThan(
            try sourceIndex(of: "purgePendingWrites(forHouseholds: removedHouseholdIds)", in: applySyncResult),
            try sourceIndex(of: "applyPendingWrites(to: &snapshot)", in: applySyncResult)
        )
    }

    func testFullZoneRefreshClearsStaleZoneRecordsBeforeApplyingFreshData() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let applySyncResult = try excerpt(repo, from: "private func applySyncResult", to: "private func alertForNewActiveTripItems")

        XCTAssertLessThan(
            try sourceIndex(of: "snapshot.removeRecords(in: result.fullZones)", in: applySyncResult),
            try sourceIndex(of: "snapshot.upsert(contentsOf: result.snapshot)", in: applySyncResult)
        )
        XCTAssertLessThan(
            try sourceIndex(of: "snapshot.upsert(contentsOf: result.snapshot)", in: applySyncResult),
            try sourceIndex(of: "applyPendingWrites(to: &snapshot)", in: applySyncResult)
        )
    }

    func testCloudKitRetryPolicyIncludesTransientFailuresAndRetryAfter() throws {
        let cloud = try source("Grocer/Services/CloudKitService.swift")
        let retry = try excerpt(cloud, from: "private static func shouldRetry", to: "// MARK: - Debug helpers")

        for code in [
            ".networkUnavailable",
            ".networkFailure",
            ".requestRateLimited",
            ".serviceUnavailable",
            ".zoneBusy",
            ".partialFailure",
        ] {
            XCTAssertTrue(retry.contains(code), "Retry policy should include \(code)")
        }
        XCTAssertTrue(retry.contains("CKErrorRetryAfterKey"))
        XCTAssertTrue(retry.contains("return min(pow(2, Double(attempt - 1)), 8)"))
    }

    func testSoftDeletesAreUsedForGroceryItemRemoval() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let deleteItem = try excerpt(repo, from: "func delete(_ item: GroceryItem)", to: "// MARK: - Siri / App Intents entry point")

        XCTAssertTrue(deleteItem.contains("updated.status = .removed"))
        XCTAssertTrue(deleteItem.contains("updated.deletedAt = now"))
        XCTAssertTrue(deleteItem.contains("persist(updated)"))
        XCTAssertFalse(deleteItem.contains("enqueueDelete(.item"))
    }

    func testOfflineGroupCreationQueuesBaseRecordsBeforeCloudKitAvailabilityCheck() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let makeGroup = try excerpt(repo, from: "private func makeGroup", to: "/// Update the current group's appearance")

        XCTAssertTrue(makeGroup.contains("enqueueSave(.household(house))"))
        XCTAssertTrue(makeGroup.contains("enqueueSave(.member(member))"))
        XCTAssertTrue(makeGroup.contains("enqueueSave(.list(list))"))
        XCTAssertLessThan(
            try sourceIndex(of: "enqueueSave(.household(house))", in: makeGroup),
            try sourceIndex(of: "if usingCloudKit {", in: makeGroup)
        )
    }

    func testKnownGapConflictRetryStillBlindlyOverwritesServerFields() throws {
        XCTExpectFailure("Conflict retry should become semantic/field-aware instead of copying every local key onto the server record.")
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let saveBestEffort = try excerpt(repo, from: "private func saveBestEffort", to: "private func saveMemberBestEffort")

        XCTAssertFalse(saveBestEffort.contains("for key in r.allKeys() { serverRecord[key] = r[key] }"))
        XCTAssertTrue(saveBestEffort.localizedCaseInsensitiveContains("merge"))
    }

    func testParticipantLeaveRemovesCloudKitShareMembership() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let leave = try excerpt(repo, from: "private func removeSelfFromGroup", to: "/// Owner leaving")

        XCTAssertFalse(leave.contains("enqueueDelete(.member"))
        XCTAssertTrue(leave.contains("cloud.leaveShare"))
        XCTAssertTrue(leave.contains("householdRecordID(house)"))
    }

    func testMainScreensExposeSyncStatus() throws {
        XCTAssertTrue(try hasUncommentedLine(containing: "SyncStatusBar(state: repo.syncState, pendingCount: repo.pendingCloudWriteCount)", in: "Grocer/Views/HomeView.swift"))
        XCTAssertTrue(try hasUncommentedLine(containing: "SyncStatusBar(state: repo.syncState, pendingCount: repo.pendingCloudWriteCount)", in: "Grocer/Views/GroceryListView.swift"))
        XCTAssertTrue(try hasUncommentedLine(containing: "SyncStatusBar(state: repo.syncState, pendingCount: repo.pendingCloudWriteCount)", in: "Grocer/Views/RootView.swift"))
    }

    func testForegroundRefreshUsesFastAdaptiveRealtimeCadence() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let loop = try excerpt(repo, from: "func startForegroundRefreshLoop", to: "func stopForegroundRefreshLoop")
        let poll = try excerpt(repo, from: "private func pollWhileForeground", to: "/// Entry point for the periodic")

        XCTAssertFalse(loop.contains(".seconds(4)"))
        XCTAssertTrue(loop.contains("activeSession"))
        XCTAssertTrue(loop.contains("activeTripForegroundPollInterval"))
        XCTAssertTrue(poll.contains("idleForegroundPollMinimumSpacing"))
        XCTAssertTrue(poll.contains("activeTripForegroundPollMinimumSpacing"))
        XCTAssertTrue(poll.contains("discoverSharedZones: force"))
        XCTAssertFalse(poll.contains("< 5"))
    }

    func testRemoteNotificationsUseLightweightRealtimeRefresh() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let handler = try excerpt(repo, from: "func handleRemoteNotification", to: "private func refreshSnapshot")

        XCTAssertTrue(handler.contains("Self.remoteNotificationDebounce"))
        XCTAssertTrue(handler.contains("registerSubscriptions: false"))
        XCTAssertTrue(handler.contains("showSyncing: false"))
        XCTAssertTrue(handler.contains("maintenance: false"))
        XCTAssertTrue(handler.contains("discoverSharedZones: false"))
        XCTAssertFalse(handler.contains("maintenance: true"))
    }

    func testOwnerRepairDoesNotPromoteFallbackOwners() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let ownerCheck = try excerpt(repo, from: "var isOwnerOfCurrentGroup", to: "var sharingUnavailableReason")
        let repair = try excerpt(repo, from: "private func repairOrphanedGroupOwners", to: "/// Writes `newValue`")

        XCTAssertTrue(ownerCheck.contains("recordOwnerName"))
        XCTAssertFalse(ownerCheck.contains("role == .owner"))
        XCTAssertTrue(repair.contains("owner member missing"))
        XCTAssertFalse(repair.contains("memberOwnerPromotionOrder"))
        XCTAssertFalse(repair.contains("householdsToPersist"))
    }

    func testFinishShoppingFlushesSessionBeforeTripSnapshots() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let finish = try excerpt(repo, from: "func finishShopping", to: "func cancelShopping")

        XCTAssertLessThan(
            try sourceIndex(of: "await flushCriticalSessionWrites(sessionId: session.id)", in: finish),
            try sourceIndex(of: "captureTripItems(for: session, at: now)", in: finish)
        )
    }

    func testOutboxPrioritizesSessionTerminationBeforeTripItems() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let priority = try excerpt(repo, from: "private static func outboxPriority", to: "/// Flushes the session record")

        XCTAssertTrue(priority.contains("case .session: return 0"))
        XCTAssertTrue(priority.contains("case .tripItem: return 3"))
    }

    func testOutboxRetriesOmitUnsupportedTripItemReplacementField() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")

        XCTAssertTrue(repo.contains("isTripItemReplacementNameSchemaError"))
        XCTAssertTrue(repo.contains("retryTripItemWithoutReplacementName"))
        XCTAssertTrue(repo.contains("includeReplacementItemName: supportsTripItemReplacementNameField"))
        XCTAssertTrue(repo.contains("CloudKitSchemaTelemetry.parseMismatch"))
        XCTAssertTrue(repo.contains("reportSchemaMismatch"))
    }

    func testCloudKitSchemaTelemetryReportsToSentry() throws {
        let telemetry = try source("Grocer/Services/CloudKitSchemaTelemetry.swift")

        XCTAssertTrue(telemetry.contains("enum CloudKitSchemaTelemetry"))
        XCTAssertTrue(telemetry.contains("static func parseMismatch(from error: Error)"))
        XCTAssertTrue(telemetry.contains("SentrySDK.capture(event:"))
        XCTAssertTrue(telemetry.contains("cloudkit-schema-mismatch"))
    }

    func testOutboxRetriesHaveDurableBackoffMetadata() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let pendingWrite = try excerpt(repo, from: "private struct PendingCloudWrite", to: "struct GroceryItemInput")
        let retry = try excerpt(repo, from: "private func markWriteDeferred", to: "private struct SaveFailureResolution")

        XCTAssertTrue(pendingWrite.contains("failureCount"))
        XCTAssertTrue(pendingWrite.contains("retryAfter"))
        XCTAssertTrue(pendingWrite.contains("lastError"))
        XCTAssertTrue(retry.contains("outboxRetryDelay"))
        XCTAssertTrue(retry.contains("CKErrorRetryAfterKey"))
        XCTAssertTrue(repo.contains("eligiblePendingWrites"))
        XCTAssertTrue(repo.contains("scheduleOutboxFlush()"))
    }

    func testRecoverableCloudKitFailuresDoNotSurfaceSyncIssueChip() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let recordFailure = try excerpt(repo, from: "private func recordSyncFailure", to: "private func shouldKeepLocalCompletedSession")
        let suppression = try excerpt(repo, from: "static func shouldSuppressUserVisibleSyncFailure", to: "/// True when the target zone")

        XCTAssertTrue(recordFailure.contains("shouldSuppressUserVisibleSyncFailure"))
        XCTAssertTrue(recordFailure.contains("syncState = .idle"))
        for code in [
            ".requestRateLimited",
            ".serviceUnavailable",
            ".zoneBusy",
            ".serverRecordChanged",
            ".batchRequestFailed",
            ".partialFailure",
        ] {
            XCTAssertTrue(suppression.contains(code), "Expected sync chip suppression for \(code)")
        }
    }

    func testOutOfStockCleanupKeepsCheckedItemsOnListAndRemovesUncheckedItems() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let cleanup = try excerpt(repo, from: "private func applyCleanup", to: "/// Writes an immutable per-item snapshot")
        let outOfStock = try excerpt(cleanup, from: "case .outOfStock:", to: "case .skipped:")

        XCTAssertTrue(outOfStock.contains("if keepOutOfStock"))
        XCTAssertTrue(outOfStock.contains("item.status = .needed"))
        XCTAssertTrue(outOfStock.contains("item.status = .removed"))
        XCTAssertLessThan(
            try sourceIndex(of: "if keepOutOfStock", in: outOfStock),
            try sourceIndex(of: "item.status = .removed", in: outOfStock)
        )
    }

    func testShoppingSessionRowsUseSectionScopedIdentity() throws {
        let view = try source("Grocer/Views/ShoppingSessionView.swift")

        XCTAssertTrue(view.contains("shoppingPendingRowID"))
        XCTAssertTrue(view.contains("shoppingAddedRowID"))
        XCTAssertTrue(view.contains("shoppingHandledRowID"))
        XCTAssertTrue(view.contains("ForEach(group.items, id: \\.shoppingPendingRowID)"))
        XCTAssertTrue(view.contains("ForEach(handled, id: \\.shoppingHandledRowID)"))
    }

    func testTripHistoryNavigationHasHaptics() throws {
        let history = try source("Grocer/Views/TripHistoryView.swift")
        let detail = try source("Grocer/Views/TripDetailView.swift")

        XCTAssertTrue(history.contains("Haptics.selection()"))
        XCTAssertTrue(history.contains("HapticBackButton()"))
        XCTAssertTrue(detail.contains("HapticBackButton()"))
    }

    func testTripHistoryRowsAreFullyTappableAndCanReaddItems() throws {
        let history = try source("Grocer/Views/TripHistoryView.swift")
        let detail = try source("Grocer/Views/TripDetailView.swift")

        XCTAssertTrue(history.contains("@State private var selectedTrip: ShoppingSession?"))
        XCTAssertTrue(history.contains("selectedTrip = trip"))
        XCTAssertTrue(history.contains(".navigationDestination(item: $selectedTrip)"))
        XCTAssertTrue(history.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(detail.contains("Add All to List"))
        XCTAssertTrue(detail.contains("repo.addItems"))
    }

    func testItemHistorySupportsSwipeRemoval() throws {
        let add = try source("Grocer/Views/AddItemView.swift")
        let repo = try source("Grocer/Services/GroceryRepository.swift")

        XCTAssertTrue(add.contains("HistorySwipeToRemoveRow"))
        XCTAssertTrue(add.contains("onDeleteHistory"))
        XCTAssertTrue(add.contains("deleteFromHistory(name:"))
        XCTAssertTrue(add.contains("Remove from history"))
        XCTAssertTrue(repo.contains("func removeCurrentItemSuggestion(named name: String)"))
        XCTAssertTrue(repo.contains("$0.name.itemSuggestionKey == key && $0.status != .needed"))
    }

    func testItemDetailBackNavigationHasHaptics() throws {
        let detail = try source("Grocer/Views/ItemDetailView.swift")
        let itemDetail = try excerpt(detail, from: "struct ItemDetailView", to: "/// Simple editor reused")

        XCTAssertTrue(itemDetail.contains(".navigationBarBackButtonHidden(true)"))
        XCTAssertTrue(itemDetail.contains(".swipeBackEnabled()"))
        XCTAssertTrue(itemDetail.contains("ToolbarItem(placement: .topBarLeading) { HapticBackButton() }"))
    }

    func testHistoryRetentionPrunesOldSnapshotsAndTombstones() throws {
        let repo = try source("Grocer/Services/GroceryRepository.swift")
        let prune = try excerpt(repo, from: "private func pruneHistoricalRecords", to: "private func lastActivityDate")

        XCTAssertTrue(prune.contains("removedItemTombstoneRetention"))
        XCTAssertTrue(prune.contains("eventRetention"))
        XCTAssertTrue(prune.contains("completedTripRetentionCount"))
        XCTAssertTrue(prune.contains("enqueueDelete(.item"))
        XCTAssertTrue(prune.contains("enqueueDelete(.event"))
        XCTAssertTrue(prune.contains("enqueueDelete(.tripItem"))
        XCTAssertTrue(prune.contains("enqueueDelete(.session"))
    }

    func testKnownGapReusablePublicInviteLinksAreStillAllowed() throws {
        XCTExpectFailure("Contacts invite currently uses a reusable read-write public share URL.")
        let cloud = try source("Grocer/Services/CloudKitService.swift")
        let invite = try excerpt(cloud, from: "func invitableShareURL", to: "@available(iOS 26.0, *)")

        XCTAssertFalse(invite.contains("share.publicPermission = .readWrite"))
    }
}
