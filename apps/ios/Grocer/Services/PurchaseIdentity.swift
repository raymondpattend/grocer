import Foundation
import Security

protocol PurchaseUIDKeychain {
    func loadPurchaseUID() throws -> String?
    func savePurchaseUID(_ uid: String) throws
}

protocol PurchaseUIDCloudStore {
    func synchronize()
    func purchaseUID() -> String?
    func setPurchaseUID(_ uid: String)
}

enum PurchaseIdentity {
    static let shared = PurchaseUIDStore(
        keychain: KeychainPurchaseUIDStore(),
        cloud: UbiquitousPurchaseUIDStore()
    )
}

final class PurchaseUIDStore {
    typealias Sleep = (UInt64) async -> Void
    typealias UUIDFactory = () -> String

    private let keychain: PurchaseUIDKeychain
    private let cloud: PurchaseUIDCloudStore
    private let cloudWaitNanoseconds: UInt64
    private let pollNanoseconds: UInt64
    private let sleep: Sleep
    private let makeUUID: UUIDFactory

    init(
        keychain: PurchaseUIDKeychain,
        cloud: PurchaseUIDCloudStore,
        cloudWaitNanoseconds: UInt64 = 3_000_000_000,
        pollNanoseconds: UInt64 = 250_000_000,
        sleep: @escaping Sleep = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        makeUUID: @escaping UUIDFactory = { UUID().uuidString }
    ) {
        self.keychain = keychain
        self.cloud = cloud
        self.cloudWaitNanoseconds = cloudWaitNanoseconds
        self.pollNanoseconds = pollNanoseconds
        self.sleep = sleep
        self.makeUUID = makeUUID
    }

    func getOrCreateUID() async -> String {
        if let uid = canonicalUID(try? keychain.loadPurchaseUID()) {
            mirrorToCloud(uid)
            return uid
        }

        cloud.synchronize()
        if let uid = canonicalUID(cloud.purchaseUID()) {
            mirrorToKeychain(uid)
            return uid
        }

        var remaining = cloudWaitNanoseconds
        while remaining > 0 {
            let delay = min(pollNanoseconds, remaining)
            await sleep(delay)
            remaining -= delay
            cloud.synchronize()
            if let uid = canonicalUID(cloud.purchaseUID()) {
                mirrorToKeychain(uid)
                return uid
            }
        }

        let generated = canonicalUID(makeUUID()) ?? UUID().uuidString.lowercased()
        mirrorToKeychain(generated)
        mirrorToCloud(generated)
        return generated
    }

    private func mirrorToKeychain(_ uid: String) {
        do {
            try keychain.savePurchaseUID(uid)
        } catch {
            print("[Billing] Could not save purchase UID to Keychain: \(error)")
        }
    }

    private func mirrorToCloud(_ uid: String) {
        cloud.setPurchaseUID(uid)
    }

    private func canonicalUID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let uuid = UUID(uuidString: value) else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }
}

enum PurchaseUIDKeychainError: Error {
    case unhandledStatus(OSStatus)
    case invalidString
}

final class KeychainPurchaseUIDStore: PurchaseUIDKeychain {
    private let service = Bundle.main.bundleIdentifier ?? "org.narro.grocer"
    private let account = "purchaseUID"

    func loadPurchaseUID() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw PurchaseUIDKeychainError.unhandledStatus(status)
        }
        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            throw PurchaseUIDKeychainError.invalidString
        }
        return string
    }

    func savePurchaseUID(_ uid: String) throws {
        guard let data = uid.data(using: .utf8) else {
            throw PurchaseUIDKeychainError.invalidString
        }

        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw PurchaseUIDKeychainError.unhandledStatus(updateStatus)
        }

        var item = baseQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw PurchaseUIDKeychainError.unhandledStatus(addStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

final class UbiquitousPurchaseUIDStore: PurchaseUIDCloudStore {
    private let key = "grocer.purchaseUID"
    private let store = NSUbiquitousKeyValueStore.default

    func synchronize() {
        store.synchronize()
    }

    func purchaseUID() -> String? {
        store.string(forKey: key)
    }

    func setPurchaseUID(_ uid: String) {
        store.set(uid, forKey: key)
        store.synchronize()
    }
}
