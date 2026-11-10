import Foundation
import Security

/// 一组经 iCloud 钥匙串同步的条目（同一 Apple ID 的设备都看得到）。只放能给自己其他设备的东西，私钥不放这里。
nonisolated protocol RemoteSyncedStorage: Sendable {
    func loadAll() -> [Data]
    func save(_ data: Data, account: String) throws
    func delete(account: String) throws
}

/// 经 iCloud 钥匙串同步的存储（中继配置用）：设备首次解锁后可读，Mac 锁屏时远控服务仍要读得到。
///
/// 读、删一律用 `kSecAttrSynchronizableAny`（见 `KeychainStore.baseQuery` 的说明）。
nonisolated struct RemoteKeychainSyncedStorage: RemoteSyncedStorage {
    private let service: String

    init(service: String) {
        self.service = service
    }

    private var base: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    func loadAll() -> [Data] {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return result as? [Data] ?? []
    }

    func save(_ data: Data, account: String) throws {
        try delete(account: account)
        var add = base
        add[kSecAttrAccount as String] = account
        add[kSecAttrSynchronizable as String] = kCFBooleanTrue
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func delete(account: String) throws {
        var query = base
        query[kSecAttrAccount as String] = account
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }
}

/// 测试用的内存实现。
nonisolated final class RemoteMemorySyncedStorage: RemoteSyncedStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    init() {}

    func loadAll() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return items.keys.sorted().compactMap { items[$0] }
    }

    func save(_ data: Data, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[account] = data
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[account] = nil
    }
}
