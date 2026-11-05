import CryptoKit
import Foundation
import Security

// 配对的两条路（两端共用）：
// - 同一 Apple ID：各自把**公开**身份（设备 ID、名字、长期公钥）写进 iCloud 钥匙串的名册（`RemoteCloudRoster`），
//   名册里设备 ID 与公钥都对得上的对端直接信任。私钥仍只在本机（`RemoteIdentityStore`）。
// - 扫码：Mac 出一张一次性邀请（`RemotePairingInvitation`），手机扫到就知道该信任哪台 Mac、哪把公钥；
//   连接时在握手消息里带上凭据（`RemotePairingInvitation.proof`），Mac 核对通过就信任这台手机，不用人点。

/// Mac 出示的配对邀请，编成二维码给手机扫。
///
/// 一次性、有时限：令牌用过一次或过期就作废（Mac 端管）。凭据绑定两端的长期公钥，旁观者截到握手消息也
/// 换不到别的设备上用。
nonisolated struct RemotePairingInvitation: Equatable, Sendable {
    static let scheme = "uterm"
    static let host = "pair"
    static let version = 1
    static let tokenLength = 16

    var macID: UUID
    var macName: String
    /// Mac 的长期公钥（X25519 原始 32 字节）。
    var macKey: Data
    var token: Data

    init(macID: UUID, macName: String, macKey: Data, token: Data) {
        self.macID = macID
        self.macName = macName
        self.macKey = macKey
        self.token = token
    }

    /// 新的随机令牌。
    static func newToken() -> Data {
        var bytes = [UInt8](repeating: 0, count: tokenLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, tokenLength, &bytes)
        return Data(bytes)
    }

    /// `uterm://pair?v=1&d=<设备 ID>&n=<名字>&k=<公钥>&t=<令牌>`，二进制用 base64url。
    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: "v", value: String(Self.version)),
            URLQueryItem(name: "d", value: macID.uuidString),
            URLQueryItem(name: "n", value: macName),
            URLQueryItem(name: "k", value: macKey.base64URLEncoded),
            URLQueryItem(name: "t", value: token.base64URLEncoded),
        ]
        return components.url!
    }

    /// 解析扫到的内容。不是 uTerm 的配对码、版本不认识、字段不全都返回 nil。
    init?(scanned text: String) {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == Self.scheme, components.host == Self.host else { return nil }
        let items = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                               uniquingKeysWith: { first, _ in first })
        guard items["v"] == String(Self.version),
              let id = items["d"].flatMap(UUID.init(uuidString:)),
              let name = items["n"], !name.isEmpty,
              let key = items["k"].flatMap(Data.init(base64URLEncoded:)), key.count == 32,
              let token = items["t"].flatMap(Data.init(base64URLEncoded:)), token.count == Self.tokenLength
        else { return nil }
        self.init(macID: id, macName: name, macKey: key, token: token)
    }

    /// 手机放进握手消息的凭据：HMAC(令牌, 用途 ‖ 手机公钥 ‖ Mac 公钥)。
    static func proof(token: Data, phoneKey: Data, macKey: Data) -> Data {
        var message = Data("uterm-remote-pair-v1".utf8)
        message.append(phoneKey)
        message.append(macKey)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: token)))
    }

    static func verify(_ proof: Data, token: Data, phoneKey: Data, macKey: Data) -> Bool {
        let expected = Self.proof(token: token, phoneKey: phoneKey, macKey: macKey)
        guard proof.count == expected.count else { return false }
        // 常数时间比较。
        return zip(proof, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

// MARK: - iCloud 名册

/// 名册里的一台设备：只有公开信息。
nonisolated struct RemoteRosterEntry: Codable, Equatable, Sendable, Identifiable {
    enum Platform: String, Codable, Sendable {
        case mac
        case mobile
    }

    var id: UUID
    var name: String
    var publicKey: Data
    var platform: Platform
    var updatedAt: Date

    var peer: RemotePeer {
        RemotePeer(id: id, name: name, publicKey: publicKey, pairedAt: updatedAt)
    }
}

/// 同一 Apple ID 下各台设备的远控身份，经 iCloud 钥匙串同步（端到端加密）。
///
/// 每台设备只写自己那一条（account = 设备 ID），读全部。名册只决定「该信任谁」，信任与否在握手里
/// 按设备 ID + 公钥核对；本机拉黑的设备（`RemoteIdentityStore.isBlocked`）名册里有也不认。
nonisolated final class RemoteCloudRoster: @unchecked Sendable {
    private let storage: any RemoteRosterStorage

    init(storage: any RemoteRosterStorage = RemoteKeychainRosterStorage()) {
        self.storage = storage
    }

    func entries() -> [RemoteRosterEntry] {
        storage.loadAll().compactMap { try? JSONDecoder().decode(RemoteRosterEntry.self, from: $0) }
    }

    func entry(id: UUID) -> RemoteRosterEntry? {
        entries().first { $0.id == id }
    }

    /// 写入（或更新）本机这一条。内容没变就不写，免得每次启动都推一次同步。
    func publish(_ entry: RemoteRosterEntry) {
        if let existing = self.entry(id: entry.id), existing.name == entry.name, existing.publicKey == entry.publicKey,
           existing.platform == entry.platform { return }
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? storage.save(data, account: entry.id.uuidString)
    }

    /// 撤下一条（本机关掉远控，或在别的设备上「忘记」它）。
    func withdraw(id: UUID) {
        try? storage.delete(account: id.uuidString)
    }

    /// 名册里设备 ID 与公钥都对得上：同一 Apple ID 下的设备。
    func vouches(for id: UUID, publicKey: Data) -> Bool {
        entry(id: id)?.publicKey == publicKey
    }
}

nonisolated protocol RemoteRosterStorage: Sendable {
    func loadAll() -> [Data]
    func save(_ data: Data, account: String) throws
    func delete(account: String) throws
}

/// 名册的钥匙串存储：可同步、设备首次解锁后可读（Mac 锁屏时远控服务仍要能核对来连的手机）。
///
/// 读、删一律用 `kSecAttrSynchronizableAny`（见 `KeychainStore.baseQuery` 的说明）。
nonisolated struct RemoteKeychainRosterStorage: RemoteRosterStorage {
    private let service: String

    init(service: String = "com.uozi.uTerm.remote.roster") {
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

/// 测试用的内存名册。
nonisolated final class RemoteMemoryRosterStorage: RemoteRosterStorage, @unchecked Sendable {
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

// MARK: - base64url

nonisolated extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
