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
    /// 对端握手时报的机型（如「iPhone 16 Pro」）。老版本不报，解出来是 nil。
    var model: String? = nil
    /// 本机给它起的名字（设置里「重命名」）。有了它就不再跟着对端报的名字走。
    var alias: String? = nil

    /// 列表、横幅里显示的名字：本机起的别名优先，其次对端报的名字。
    var displayName: String { alias ?? name }

    /// 本机改名后的样子。空白、或与对端报的名字相同 = 去掉别名，回到跟着对端报的名字走。
    func renamed(_ input: String) -> RemotePeer {
        var peer = self
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        peer.alias = trimmed.isEmpty || trimmed == name ? nil : trimmed
        return peer
    }

    /// 副标题里的机型：与标题相同（名字本来就是退回的机型名）就不重复。
    var modelDetail: String? {
        guard let model, model != displayName else { return nil }
        return model
    }
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
    private static let blockedAccount = "blockedPeers"
    private static let relayHostKeyAccount = "relayHostKey"

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

    /// 这台 Mac 在中继上的身份（P-256）。中继第一次见到它就和设备 ID 绑定，别的成员顶替不了这台 Mac。
    /// 长期密钥是 X25519，只能协商不能签名，所以单独一把。
    func relayHostKey() throws -> P256.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if let data = try storage.load(Self.relayHostKeyAccount),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        try storage.save(key.rawRepresentation, account: Self.relayHostKeyAccount)
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

    /// 记住（或更新）一个对端。同一 `id` 只保留一条；之前拉黑过的，一并解除。
    func trust(_ peer: RemotePeer) throws {
        lock.lock()
        defer { lock.unlock() }
        var peers = loadPeers().filter { $0.id != peer.id }
        peers.append(peer)
        try storage.save(try JSONEncoder().encode(peers), account: Self.peersAccount)
        let blocked = loadBlocked()
        if blocked.contains(peer.id) { try saveBlocked(blocked.subtracting([peer.id])) }
    }

    /// 撤销信任并拉黑：同一 Apple ID 的名册里还有它，也不再自动信任，直到重新扫码配对（`trust`）。
    func revoke(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let peers = loadPeers().filter { $0.id != id }
        try storage.save(try JSONEncoder().encode(peers), account: Self.peersAccount)
        try saveBlocked(loadBlocked().union([id]))
    }

    func isBlocked(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadBlocked().contains(id)
    }

    /// 这个对端可以直接放行：本机信任过它，或者同一 Apple ID 的名册替它担保（且没被本机拉黑）。
    /// 两种都要设备 ID 与公钥同时对得上。
    func recognizes(id: UUID, publicKey: Data, roster: RemoteCloudRoster?) -> Bool {
        if peer(id: id)?.publicKey == publicKey { return true }
        guard let roster, !isBlocked(id) else { return false }
        return roster.vouches(for: id, publicKey: publicKey)
    }

    private func loadBlocked() -> Set<UUID> {
        guard let data = try? storage.load(Self.blockedAccount) else { return [] }
        return (try? JSONDecoder().decode(Set<UUID>.self, from: data)) ?? []
    }

    private func saveBlocked(_ ids: Set<UUID>) throws {
        try storage.save(try JSONEncoder().encode(ids), account: Self.blockedAccount)
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
    private static let idKey = DefaultsKey.remoteDeviceID

    static func id(defaults: UserDefaults = .standard) -> UUID {
        if let raw = defaults.string(forKey: idKey), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: idKey)
        return id
    }
}
