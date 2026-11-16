import CryptoKit
import Foundation
import Security

/// 配对过的对端：被控端记住的是来控制它的设备，主控端记住的是它控制的主机。
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
    /// 对端握手时报的设备类别（`RemoteDevicePlatform` 的原始值）。老版本不报，解出来是 nil，当手机看。
    var platform: String? = nil

    /// 主控端记的、这台主机所在的中继，和本机默认中继不是同一台时才有（凭邀请配的别人的 Mac、或主机发来的
    /// 配置与默认不同）。nil = 走本机默认中继。存在本机专属的钥匙串里，不同步。
    var relay: RemoteRelayConfig? = nil
    /// 被控端记的、发给这台设备的中继成员证书（只能连本机）。忘记这台设备时吊销它；主控端不用。
    var relayGrant: RemoteRelayConfig? = nil

    /// 对端是 Mac（另一台 Mac 来控制本机，或本机控制的主机）。
    var isMac: Bool { platform == RemoteDevicePlatform.mac.rawValue }

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

/// 一张信任表管哪个方向。两个方向必须分开存：Mac 既能被控制、又能去控制别的 Mac，若共用一张表，
/// 「我要控制 B」记下的 B 会被被控端当成「允许来控制我」，B 就能免审批反过来控制本机。
nonisolated enum RemoteTrustRole: Sendable {
    /// 允许来控制本机的设备（被控端）。
    case controllers
    /// 本机去控制的主机（主控端）。
    case hosts

    /// iOS 只当主控端，主机一直记在最早那个账号里，沿用它免得迁移。
    fileprivate var accounts: (peers: String, blocked: String) {
        switch self {
        case .controllers:
            return ("trustedPeers", "blockedPeers")
        case .hosts:
            #if os(iOS)
            return ("trustedPeers", "blockedPeers")
            #else
            return ("trustedHosts", "blockedHosts")
            #endif
        }
    }
}

/// 远控身份：本机长期密钥 + 一个方向上已信任的对端列表（见 `RemoteTrustRole`）。
///
/// 本机长期密钥两个方向共用，设备 ID 也只有一个。
///
/// 存钥匙串，**不同步、只限本机**（`ThisDeviceOnly`）：同一 Apple ID 下的另一台设备拿到这把
/// 私钥就能冒充本机，所以它不能跟着 iCloud 钥匙串走。这也是不复用 `KeychainStore` 的原因，
/// 那边一律写成可同步。可访问性取 `AfterFirstUnlock`：Mac 锁屏时远控服务仍要能认证手机。
nonisolated final class RemoteIdentityStore: @unchecked Sendable {
    private let storage: any RemoteSecretStorage
    private let lock = NSLock()
    private var cachedIdentity: Curve25519.KeyAgreement.PrivateKey?

    private let peersAccount: String
    private let blockedAccount: String

    private static let identityAccount = "identity"
    private static let relayHostKeyAccount = "relayHostKey"
    /// 被担保的设备是谁添加的（`RemotePeerVouch`），只有被控端（`.controllers`）用。
    static let vouchAccount = "peerVouches"

    let role: RemoteTrustRole

    init(role: RemoteTrustRole, storage: any RemoteSecretStorage = RemoteLocalState.secrets) {
        self.role = role
        self.storage = storage
        (peersAccount, blockedAccount) = role.accounts
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

    /// 已经有的本机长期私钥；还没生成过返回 nil，**不生成**。后台线程上只读身份时用它：
    /// 两个 store 同时第一次 `localIdentity()` 会各生成一把，后存的顶掉先存的，先存的那份缓存就成了钥匙串里没有的钥匙。
    func existingIdentity() -> Curve25519.KeyAgreement.PrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedIdentity { return cachedIdentity }
        guard let data = try? storage.load(Self.identityAccount) else { return nil }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
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

    /// 原样读一条存储（远控进程的镜像：App 把这些交过去）。
    func rawValue(account: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? storage.load(account)
    }

    /// 原样写一条存储（远控进程写回来的）。写的是本机长期密钥时连缓存一起换掉。
    func saveRaw(_ data: Data, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try storage.save(data, account: account)
        if account == Self.identityAccount { cachedIdentity = nil }
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
        try storage.save(try JSONEncoder().encode(peers), account: peersAccount)
        let blocked = loadBlocked()
        if blocked.contains(peer.id) { try saveBlocked(blocked.subtracting([peer.id])) }
    }

    /// 撤销信任：再来连要重新配对。它的担保记录一并去掉。
    ///
    /// `blocks`（默认）时同时拉黑，之后谁担保它都不认，只有重新配对（`trust`）才解除——这是 Mac 主人在 Mac 上撤销、
    /// 主控端「忘记」一台 Mac 时的做法。同组设备请 Mac 撤销（消息 52）、设备组撤掉被移除的组员、主控端撤掉只凭被移除的
    /// 组员开通才记下的 Mac 时不拉黑：那不是这台设备主人的决定，设备找回来重新进组后要能自动开通回来
    /// （docs/remote-device-group-design.md §8）。原来就拉黑着的不会因此解除。
    func revoke(id: UUID, blocks: Bool = true) throws {
        lock.lock()
        defer { lock.unlock() }
        let peers = loadPeers().filter { $0.id != id }
        try storage.save(try JSONEncoder().encode(peers), account: peersAccount)
        if blocks { try saveBlocked(loadBlocked().union([id])) }
        var vouches = loadVouches()
        if vouches.removeValue(forKey: id) != nil { try saveVouches(vouches) }
    }

    /// 被担保的设备 → 谁添加的。
    func vouches() -> [UUID: RemotePeerVouch] {
        lock.lock()
        defer { lock.unlock() }
        return loadVouches()
    }

    func recordVouch(_ vouch: RemotePeerVouch) throws {
        lock.lock()
        defer { lock.unlock() }
        var vouches = loadVouches()
        vouches[vouch.deviceID] = vouch
        try saveVouches(vouches)
    }

    private func loadVouches() -> [UUID: RemotePeerVouch] {
        guard let data = try? storage.load(Self.vouchAccount),
              let list = try? JSONDecoder().decode([RemotePeerVouch].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.deviceID, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private func saveVouches(_ vouches: [UUID: RemotePeerVouch]) throws {
        let list = vouches.values.sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
        try storage.save(try JSONEncoder().encode(list), account: Self.vouchAccount)
    }

    func isBlocked(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadBlocked().contains(id)
    }

    /// 这个对端可以直接放行：本机和它配对过，设备 ID 与公钥都对得上。同一 Apple ID 不再算数。
    func recognizes(id: UUID, publicKey: Data) -> Bool {
        peer(id: id)?.publicKey == publicKey
    }

    private func loadBlocked() -> Set<UUID> {
        guard let data = try? storage.load(blockedAccount) else { return [] }
        return (try? JSONDecoder().decode(Set<UUID>.self, from: data)) ?? []
    }

    private func saveBlocked(_ ids: Set<UUID>) throws {
        try storage.save(try JSONEncoder().encode(ids), account: blockedAccount)
    }

    private func loadPeers() -> [RemotePeer] {
        guard let data = try? storage.load(peersAccount) else { return [] }
        return (try? JSONDecoder().decode([RemotePeer].self, from: data)) ?? []
    }
}

/// 远控身份的持久化后端。生产用钥匙串，测试注入内存实现。
nonisolated protocol RemoteSecretStorage: Sendable {
    func load(_ account: String) throws -> Data?
    func save(_ data: Data, account: String) throws
    /// 没有这一条不算错。
    func delete(_ account: String) throws
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

    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
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

    func delete(_ account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        items[account] = nil
    }
}

/// 本机在远控里的身份信息（握手时报给对端）。
nonisolated enum RemoteLocalDevice {
    private static let idKey = DefaultsKey.remoteDeviceID

    static func id(defaults: UserDefaults = RemoteLocalState.defaults) -> UUID {
        if let raw = defaults.string(forKey: idKey), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: idKey)
        return id
    }
}
