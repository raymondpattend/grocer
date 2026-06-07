import CloudKit
import Foundation

/// Conversions between domain models and `CKRecord`. Record name == model id.

protocol CloudKitApplicable {
    func apply(to record: CKRecord)
}

private func string(_ r: CKRecord, _ key: String) -> String? { r[key] as? String }
private func date(_ r: CKRecord, _ key: String) -> Date? { r[key] as? Date }
private func bool(_ r: CKRecord, _ key: String) -> Bool { (r[key] as? Int64).map { $0 != 0 } ?? false }
private func assetData(_ r: CKRecord, _ key: String) -> Data? {
    guard let url = (r[key] as? CKAsset)?.fileURL else { return nil }
    return try? Data(contentsOf: url)
}

private func imageAsset(from data: Data?) -> CKAsset? {
    guard let data else { return nil }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("grocer-profile-\(UUID().uuidString).jpg")
    do {
        try data.write(to: url, options: .atomic)
        return CKAsset(fileURL: url)
    } catch {
        print("[CloudKitMapping] failed to write profile image asset: \(error)")
        return nil
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
        r[CK.Field.householdId] = householdId as CKRecordValue
        r[CK.Field.displayName] = displayName as CKRecordValue
        r[CK.Field.profileImage] = imageAsset(from: profileImageData)
        r[CK.Field.iCloudUserRecordName] = iCloudUserRecordName as CKRecordValue?
        r[CK.Field.role] = role.rawValue as CKRecordValue
        r[CK.Field.joinedAt] = joinedAt as CKRecordValue
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
        r[CK.Field.status] = status.rawValue as CKRecordValue
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
