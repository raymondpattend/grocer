import CloudKit
import Foundation

/// Conversions between domain models and `CKRecord`. Record name == model id.

protocol CloudKitApplicable {
    func apply(to record: CKRecord)
}

private func string(_ r: CKRecord, _ key: String) -> String? { r[key] as? String }
private func date(_ r: CKRecord, _ key: String) -> Date? { r[key] as? Date }
private func double(_ r: CKRecord, _ key: String) -> Double? { r[key] as? Double }
private func bool(_ r: CKRecord, _ key: String) -> Bool { (r[key] as? Int64).map { $0 != 0 } ?? false }
private func assetData(_ r: CKRecord, _ key: String) -> Data? {
    guard let url = (r[key] as? CKAsset)?.fileURL else { return nil }
    return try? Data(contentsOf: url)
}

private let profileAssetDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("grocer-profile-assets", isDirectory: true)

private func imageAsset(from data: Data?) -> CKAsset? {
    guard let data else { return nil }
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: profileAssetDirectory, withIntermediateDirectories: true)
        pruneStaleProfileAssets(in: profileAssetDirectory)
        let url = profileAssetDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: url, options: .atomic)
        return CKAsset(fileURL: url)
    } catch {
        print("[CloudKitMapping] failed to write profile image asset: \(error)")
        return nil
    }
}

/// Best-effort cleanup of profile-image asset temp files from earlier saves.
/// CloudKit copies a `CKAsset`'s file into its own store during the
/// `modifyRecords` upload, so once a file is older than this window any save that
/// referenced it has finished and it's safe to delete. Without this, every member
/// save (including conflict re-saves) would leak a uniquely-named temp file.
private func pruneStaleProfileAssets(in directory: URL, olderThan maxAge: TimeInterval = 3600) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return }
    let cutoff = Date().addingTimeInterval(-maxAge)
    for entry in entries {
        let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, modified < cutoff {
            try? fm.removeItem(at: entry)
        }
    }
}

// MARK: - Household

extension Household: CloudKitApplicable {
    init?(record r: CKRecord) {
        guard let name = string(r, CK.Field.name),
              let owner = string(r, CK.Field.ownerMemberId) else { return nil }
        self.init(
            id: r.recordID.recordName,
            name: name,
            ownerMemberId: owner,
            storeName: string(r, CK.Field.storeName),
            storeLatitude: double(r, CK.Field.storeLatitude),
            storeLongitude: double(r, CK.Field.storeLongitude),
            storeRadius: double(r, CK.Field.storeRadius),
            icon: string(r, CK.Field.icon) ?? GROUP_ICON_CHOICES[0],
            colorTheme: string(r, CK.Field.colorTheme)
                .flatMap(ListColorTheme.init(rawValue:)) ?? .default,
            createdAt: date(r, CK.Field.createdAt) ?? r.creationDate ?? Date(),
            updatedAt: date(r, CK.Field.updatedAt) ?? r.modificationDate ?? Date(),
            recordZoneName: r.recordID.zoneID.zoneName,
            recordOwnerName: r.recordID.zoneID.ownerName
        )
    }

    func apply(to r: CKRecord) {
        r[CK.Field.name] = name as CKRecordValue
        r[CK.Field.ownerMemberId] = ownerMemberId as CKRecordValue
        r[CK.Field.storeName] = storeName as CKRecordValue?
        r[CK.Field.storeLatitude] = storeLatitude as CKRecordValue?
        r[CK.Field.storeLongitude] = storeLongitude as CKRecordValue?
        r[CK.Field.storeRadius] = storeRadius as CKRecordValue?
        r[CK.Field.icon] = icon as CKRecordValue
        r[CK.Field.colorTheme] = colorTheme.rawValue as CKRecordValue
        r[CK.Field.createdAt] = createdAt as CKRecordValue
        r[CK.Field.updatedAt] = updatedAt as CKRecordValue
    }
}

// MARK: - HouseholdMember

extension HouseholdMember: CloudKitApplicable {
    init?(record r: CKRecord) {
        guard let householdId = string(r, CK.Field.householdId),
              let displayName = string(r, CK.Field.displayName),
              let roleRaw = string(r, CK.Field.role),
              let role = MemberRole(rawValue: roleRaw) else { return nil }
        // Record name is "memberId_householdId" (composite key).
        // Extract just the memberId portion; fall back to full name for
        // legacy records that used the plain memberId.
        let recordName = r.recordID.recordName
        let memberId: String
        if recordName.hasSuffix("_\(householdId)") {
            memberId = String(recordName.dropLast(householdId.count + 1))
        } else {
            memberId = recordName
        }
        self.init(
            id: memberId,
            householdId: householdId,
            displayName: displayName,
            profileImageData: assetData(r, CK.Field.profileImage),
            iCloudUserRecordName: string(r, CK.Field.iCloudUserRecordName),
            role: role,
            joinedAt: date(r, CK.Field.joinedAt) ?? Date(),
            recordZoneName: r.recordID.zoneID.zoneName,
            recordOwnerName: r.recordID.zoneID.ownerName
        )
    }

    func apply(to r: CKRecord) {
        applyMetadata(to: r)
        applyProfileImage(to: r)
    }

    /// Every member field *except* the profile-image asset. The outbox sets the
    /// asset separately so it can skip re-uploading an unchanged avatar (a
    /// CKAsset is re-uploaded in full on every save that includes the key).
    func applyMetadata(to r: CKRecord) {
        r[CK.Field.householdId] = householdId as CKRecordValue
        r[CK.Field.displayName] = displayName as CKRecordValue
        r[CK.Field.iCloudUserRecordName] = iCloudUserRecordName as CKRecordValue?
        r[CK.Field.role] = role.rawValue as CKRecordValue
        r[CK.Field.joinedAt] = joinedAt as CKRecordValue
    }

    /// Writes (or clears) the profile-image asset. Kept separate from
    /// `applyMetadata` so callers can conditionally skip it.
    func applyProfileImage(to r: CKRecord) {
        r[CK.Field.profileImage] = imageAsset(from: profileImageData)
    }
}

// MARK: - GroceryList

extension GroceryList: CloudKitApplicable {
    init?(record r: CKRecord) {
        guard let householdId = string(r, CK.Field.householdId),
              let name = string(r, CK.Field.listName) else { return nil }
        self.init(
            id: r.recordID.recordName,
            householdId: householdId,
            name: name,
            createdAt: date(r, CK.Field.createdAt) ?? Date(),
            updatedAt: date(r, CK.Field.updatedAt) ?? Date(),
            archived: bool(r, CK.Field.archived)
        )
    }

    func apply(to r: CKRecord) {
        r[CK.Field.householdId] = householdId as CKRecordValue
        r[CK.Field.listName] = name as CKRecordValue
        r[CK.Field.createdAt] = createdAt as CKRecordValue
        r[CK.Field.updatedAt] = updatedAt as CKRecordValue
        r[CK.Field.archived] = (archived ? 1 : 0) as CKRecordValue
    }
}

// MARK: - GroceryItem

extension GroceryItem: CloudKitApplicable {
    init?(record r: CKRecord) {
        guard let householdId = string(r, CK.Field.householdId),
              let listId = string(r, CK.Field.listId),
              let name = string(r, CK.Field.itemName),
              let categoryRaw = string(r, CK.Field.category),
              let category = GroceryCategory(rawValue: categoryRaw),
              let statusRaw = string(r, CK.Field.status),
              let status = ItemStatus(rawValue: statusRaw) else { return nil }
        self.init(
            id: r.recordID.recordName,
            householdId: householdId,
            listId: listId,
            name: name,
            quantity: string(r, CK.Field.quantity),
            category: category,
            notes: string(r, CK.Field.notes),
            requestedByMemberId: string(r, CK.Field.requestedByMemberId) ?? "",
            requestedByDisplayName: string(r, CK.Field.requestedByDisplayName) ?? "",
            status: status,
            priority: string(r, CK.Field.priority).flatMap(ItemPriority.init(rawValue:)) ?? .normal,
            replacementPreference: string(r, CK.Field.replacementPreference),
            replacementItemName: string(r, CK.Field.replacementItemName),
            createdAt: date(r, CK.Field.createdAt) ?? Date(),
            updatedAt: date(r, CK.Field.updatedAt) ?? Date(),
            completedAt: date(r, CK.Field.completedAt),
            deletedAt: date(r, CK.Field.deletedAt),
            activeSessionId: string(r, CK.Field.activeSessionId)
        )
    }

    func apply(to r: CKRecord) {
        r[CK.Field.householdId] = householdId as CKRecordValue
        r[CK.Field.listId] = listId as CKRecordValue
        r[CK.Field.itemName] = name as CKRecordValue
        r[CK.Field.quantity] = quantity as CKRecordValue?
        r[CK.Field.category] = category.rawValue as CKRecordValue
        r[CK.Field.notes] = notes as CKRecordValue?
        r[CK.Field.requestedByMemberId] = requestedByMemberId as CKRecordValue
        r[CK.Field.requestedByDisplayName] = requestedByDisplayName as CKRecordValue
        r[CK.Field.status] = status.rawValue as CKRecordValue
        r[CK.Field.priority] = priority.rawValue as CKRecordValue
        r[CK.Field.replacementPreference] = replacementPreference as CKRecordValue?
        r[CK.Field.replacementItemName] = replacementItemName as CKRecordValue?
        r[CK.Field.createdAt] = createdAt as CKRecordValue
        r[CK.Field.updatedAt] = updatedAt as CKRecordValue
        r[CK.Field.completedAt] = completedAt as CKRecordValue?
        r[CK.Field.deletedAt] = deletedAt as CKRecordValue?
        r[CK.Field.activeSessionId] = activeSessionId as CKRecordValue?
    }
}

// MARK: - ShoppingSession

extension ShoppingSession: CloudKitApplicable {
    init?(record r: CKRecord) {
        guard let householdId = string(r, CK.Field.householdId),
              let listId = string(r, CK.Field.listId),
              let statusRaw = string(r, CK.Field.status),
              let status = SessionStatus(rawValue: statusRaw) else { return nil }
        self.init(
            id: r.recordID.recordName,
            householdId: householdId,
            listId: listId,
            startedByMemberId: string(r, CK.Field.startedByMemberId) ?? "",
            startedByDisplayName: string(r, CK.Field.startedByDisplayName) ?? "",
            storeName: string(r, CK.Field.storeName),
            startedAt: date(r, CK.Field.startedAt) ?? Date(),
            endedAt: date(r, CK.Field.endedAt),
            updatedAt: date(r, CK.Field.updatedAt) ?? r.modificationDate ?? date(r, CK.Field.startedAt) ?? Date(),
            status: status
        )
    }

    func apply(to r: CKRecord) {
        r[CK.Field.householdId] = householdId as CKRecordValue
        r[CK.Field.listId] = listId as CKRecordValue
        r[CK.Field.startedByMemberId] = startedByMemberId as CKRecordValue
        r[CK.Field.startedByDisplayName] = startedByDisplayName as CKRecordValue
        r[CK.Field.storeName] = storeName as CKRecordValue?
        r[CK.Field.startedAt] = startedAt as CKRecordValue
        r[CK.Field.endedAt] = endedAt as CKRecordValue?
        r[CK.Field.updatedAt] = updatedAt as CKRecordValue
        r[CK.Field.status] = status.rawValue as CKRecordValue
    }
}

// MARK: - ShoppingTripItem

extension ShoppingTripItem: CloudKitApplicable {
    init?(record r: CKRecord) {
        guard let householdId = string(r, CK.Field.householdId),
              let sessionId = string(r, CK.Field.sessionId),
              let name = string(r, CK.Field.itemName),
              let categoryRaw = string(r, CK.Field.category),
              let category = GroceryCategory(rawValue: categoryRaw),
              let outcomeRaw = string(r, CK.Field.status),
              let outcome = ItemStatus(rawValue: outcomeRaw) else { return nil }
        self.init(
            id: r.recordID.recordName,
            householdId: householdId,
            sessionId: sessionId,
            itemId: string(r, CK.Field.itemId) ?? "",
            name: name,
            quantity: string(r, CK.Field.quantity),
            category: category,
            outcome: outcome,
            replacementItemName: string(r, CK.Field.replacementItemName),
            requestedByMemberId: string(r, CK.Field.requestedByMemberId) ?? "",
            requestedByDisplayName: string(r, CK.Field.requestedByDisplayName) ?? "",
            createdAt: date(r, CK.Field.createdAt) ?? r.creationDate ?? Date()
        )
    }

    func apply(to r: CKRecord) {
        apply(to: r, includeReplacementItemName: true)
    }

    /// Production CloudKit may lag behind the app on new fields. Callers that
    /// know the schema is missing `replacementItemName` can omit it and still
    /// save the rest of the trip snapshot.
    func apply(to r: CKRecord, includeReplacementItemName: Bool) {
        r[CK.Field.householdId] = householdId as CKRecordValue
        r[CK.Field.sessionId] = sessionId as CKRecordValue
        r[CK.Field.itemId] = itemId as CKRecordValue
        r[CK.Field.itemName] = name as CKRecordValue
        r[CK.Field.quantity] = quantity as CKRecordValue?
        r[CK.Field.category] = category.rawValue as CKRecordValue
        r[CK.Field.status] = outcome.rawValue as CKRecordValue
        if includeReplacementItemName {
            r[CK.Field.replacementItemName] = replacementItemName as CKRecordValue?
        }
        r[CK.Field.requestedByMemberId] = requestedByMemberId as CKRecordValue
        r[CK.Field.requestedByDisplayName] = requestedByDisplayName as CKRecordValue
        r[CK.Field.createdAt] = createdAt as CKRecordValue
    }
}

// MARK: - ItemEvent

extension ItemEvent: CloudKitApplicable {
    init?(record r: CKRecord) {
        guard let householdId = string(r, CK.Field.householdId),
              let typeRaw = string(r, CK.Field.eventType),
              let type = ItemEventType(rawValue: typeRaw) else { return nil }
        var metadata: [String: String] = [:]
        if let data = r[CK.Field.metadata] as? Data,
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            metadata = decoded
        }
        self.init(
            id: r.recordID.recordName,
            householdId: householdId,
            itemId: string(r, CK.Field.itemId),
            sessionId: string(r, CK.Field.sessionId),
            type: type,
            createdByMemberId: string(r, CK.Field.createdByMemberId) ?? "",
            createdByDisplayName: string(r, CK.Field.createdByDisplayName) ?? "",
            createdAt: date(r, CK.Field.createdAt) ?? Date(),
            metadata: metadata
        )
    }

    func apply(to r: CKRecord) {
        r[CK.Field.householdId] = householdId as CKRecordValue
        r[CK.Field.itemId] = itemId as CKRecordValue?
        r[CK.Field.sessionId] = sessionId as CKRecordValue?
        r[CK.Field.eventType] = type.rawValue as CKRecordValue
        r[CK.Field.createdByMemberId] = createdByMemberId as CKRecordValue
        r[CK.Field.createdByDisplayName] = createdByDisplayName as CKRecordValue
        r[CK.Field.createdAt] = createdAt as CKRecordValue
        if let data = try? JSONEncoder().encode(metadata) {
            r[CK.Field.metadata] = data as CKRecordValue
        }
    }
}
