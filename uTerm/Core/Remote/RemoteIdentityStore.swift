import CryptoKit
import Foundation
import Security

/// 配对过的对端：Mac 记住的是手机，手机记住的是 Mac。
nonisolated struct RemotePeer: Codable, Equatable, Sendable, Identifiable {
    /// 对端握手时报的 `deviceID`。
    var id: UUID
    var name: String
    /// 对端长期公钥（X25519 原始 32 字节）。之后每次握手都用它认证对方。
    var publicKey: Data
    var pairedAt: Date
}

/// 远控身份：本机长期密钥 + 已信任的对端列表。
///
/// 存钥匙串，**不同步、只限本机**（`ThisDeviceOnly`）：同一 Apple ID 下的另一台设备拿到这把
/// 私钥就能冒充本机，所以它不能跟着 iCloud 钥匙串走。这也是不复用 `KeychainStore` 的原因，
/// 那边一律写成可同步。可访问性取 `AfterFirstUnlock`：Mac 锁屏时远控服务仍要能认证手机。
nonisolated final class RemoteIdentityStore: @unchecked Sendable {
    private let storage: any RemoteSecretStorage
    private let lock = NSLock()
    private var cachedIdentity: Curve25519.KeyAgreement.PrivateKey?

    private static let identityAccount = "identity"
    private static let peersAccount = "trustedPeers"

    init(storage: any RemoteSecretStorage = RemoteKeychainStorage()) {
        self.storage = storage
    }

    /// 本机长期私钥；第一次调用时生成并保存。
    func localIdentity() throws -> Curve25519.KeyAgreement.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedIdentity { return cachedIdentity }
        if let data = try storage.load(Self.identityAccount),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            cachedIdentity = key
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try storage.save(key.rawRepresentation, account: Self.identityAccount)
        cachedIdentity = key
        return key
    }

    func trustedPeers() -> [RemotePeer] {
        lock.lock()
        defer { lock.unlock() }
        return loadPeers()
    }

    func peer(id: UUID) -> RemotePeer? {
        trustedPeers().first { $0.id == id }
    }

    /// 记住（或更新）一个对端。同一 `id` 只保留一条。
    func trust(_ peer: RemotePeer) throws {
        lock.lock()
        defer { lock.unlock() }
        var peers = loadPeers().filter { $0.id != peer.id }
        peers.append(peer)
        try storage.save(try JSONEncoder().encode(peers), account: Self.peersAccount)
    }

    func revoke(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let peers = loadPeers().filter { $0.id != id }
        try storage.save(try JSONEncoder().encode(peers), account: Self.peersAccount)
    }

    private func loadPeers() -> [RemotePeer] {
        guard let data = try? storage.load(Self.peersAccount) else { return [] }
        return (try? JSONDecoder().decode([RemotePeer].self, from: data)) ?? []
    }
}

/// 远控身份的持久化后端。生产用钥匙串，测试注入内存实现。
nonisolated protocol RemoteSecretStorage: Sendable {
    func load(_ account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
}

nonisolated struct RemoteKeychainStorage: RemoteSecretStorage {
    private let service: String

    init(service: String = "com.uozi.uTerm.remote") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func load(_ account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return result as? Data
    }

    func save(_ data: Data, account: String) throws {
        let q = query(account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }
}

/// 测试用的内存存储。
nonisolated final class RemoteMemoryStorage: RemoteSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    init() {}

    func load(_ account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[account]
    }

    func save(_ data: Data, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[account] = data
    }
}

/// 本机在远控里的身份信息（握手时报给对端）。
nonisolated enum RemoteLocalDevice {
    private static let idKey = "remote.deviceID"

    static func id(defaults: UserDefaults = .standard) -> UUID {
        if let raw = defaults.string(forKey: idKey), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: idKey)
        return id
    }
}
