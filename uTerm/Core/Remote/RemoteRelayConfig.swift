import CryptoKit
import Foundation
import Security

/// 一台自建中继的连接信息，由 `uterm-relay config` 生成（格式见 `relay/PROTOCOL.md`）。
///
/// `key` 是成员私钥，等同口令：凭它能注册主机、看到谁在线、发起中继。但它进不了端到端加密的会话，
/// 连上来的人还要过配对身份和「允许经公网接入」。
///
/// 主机交给配对设备的是**成员证书**（`cert` / `scope` 非空，中继 1.2.0 起）：`key` 是这台设备自己的成员私钥，
/// `cert` 是中继成员密钥对它的签名，只能连 `scope` 那一台主机、不能注册主机；主机忘记这台设备时吊销它。
nonisolated struct RemoteRelayConfig: Codable, Hashable, Sendable {
    static let format = "uterm-relay"
    static let version = 1
    static let scheme = "uterm"
    static let urlHost = "relay"

    var format: String = Self.format
    var version: Int = Self.version
    var name: String
    var host: String
    var port: Int
    var relayID: String
    /// 成员私钥：P-256 标量 32 字节的 base64。
    var key: String
    /// 成员证书只能连的那台主机（主机 ID）。nil = 中继自己的成员密钥，什么都能做。
    var scope: String?
    /// 中继成员密钥对 `certificateMessage` 的签名（DER 的 base64）。
    var cert: String?

    init(name: String, host: String, port: Int, relayID: String, key: String, scope: String? = nil,
         cert: String? = nil) {
        self.name = name
        self.host = host
        self.port = port
        self.relayID = relayID
        self.key = key
        self.scope = scope
        self.cert = cert
    }

    static let certificatePrefix = "uterm-relay-member-v1"

    /// 是主机发的成员证书（只能连一台主机），不是中继本身的成员密钥。
    var isCertificate: Bool { cert != nil }

    /// 中继按它认这份证书：成员公钥（SubjectPublicKeyInfo DER 的 base64），吊销时也用它。
    var memberPublicKey: String? {
        memberKey?.publicKey.derRepresentation.base64EncodedString()
    }

    /// 证书签的内容：`uterm-relay-member-v1\n<relayID>\n<成员公钥>\n<主机 ID>`。
    static func certificateMessage(relayID: String, member: String, scope: String) -> Data {
        Data([certificatePrefix, relayID, member, scope].joined(separator: "\n").utf8)
    }

    /// 用这份（中继本身的）成员密钥给一把新钥匙签证书，只能连 `host` 这台主机。
    func certificate(for host: UUID) throws -> RemoteRelayConfig {
        guard !isCertificate, let root = memberKey else { throw RemoteRelayError.notConfigured }
        let member = P256.Signing.PrivateKey()
        let scope = host.uuidString
        let publicKey = member.publicKey.derRepresentation.base64EncodedString()
        let signature = try root.signature(for: Self.certificateMessage(relayID: relayID, member: publicKey,
                                                                        scope: scope))
        return RemoteRelayConfig(name: name, host: self.host, port: port, relayID: relayID,
                                 key: member.rawRepresentation.base64EncodedString(), scope: scope,
                                 cert: signature.derRepresentation.base64EncodedString())
    }

    /// 同一台中继、同一个身份（成员密钥或证书）。地址、名字可以不同。
    func sameMember(as other: RemoteRelayConfig) -> Bool {
        relayID == other.relayID && key == other.key && cert == other.cert
    }

    /// 在线查询、中继客户端按它分开：同一台中继上，不同主机的证书各自只看得见自己那台。
    var memberIdentity: String {
        scope.map { "\(relayID)/\($0)" } ?? relayID
    }

    /// 导入配置文件。格式、版本或字段不对都返回 nil。
    init?(importing data: Data) {
        guard let decoded = try? JSONDecoder().decode(Self.self, from: data), decoded.isValid else { return nil }
        self = decoded
    }

    /// 解析二维码内容。不是中继配置时返回 nil。
    init?(scanned text: String) {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == Self.scheme, components.host == Self.urlHost else { return nil }
        let items = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                               uniquingKeysWith: { first, _ in first })
        guard items["v"] == String(Self.version),
              let host = items["h"], let port = items["p"].flatMap(Int.init),
              let relayID = items["i"], let raw = items["k"].flatMap(Data.init(base64URLEncoded:)) else { return nil }
        self.init(name: items["n"] ?? host, host: host, port: port, relayID: relayID, key: raw.base64EncodedString(),
                  scope: items["s"], cert: items["c"].flatMap(Data.init(base64URLEncoded:))?.base64EncodedString())
        guard isValid else { return nil }
    }

    /// 二维码内容。
    var url: URL? {
        guard let raw = Data(base64Encoded: key) else { return nil }
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.urlHost
        components.queryItems = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "n", value: name),
            URLQueryItem(name: "h", value: host),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "i", value: relayID),
            URLQueryItem(name: "k", value: raw.base64URLEncoded),
        ]
        if let scope, let cert = cert.flatMap({ Data(base64Encoded: $0) }) {
            components.queryItems? += [URLQueryItem(name: "s", value: scope),
                                       URLQueryItem(name: "c", value: cert.base64URLEncoded)]
        }
        return components.url
    }

    var endpointDescription: String { "\(host):\(port)" }

    var memberKey: P256.Signing.PrivateKey? {
        guard let raw = Data(base64Encoded: key) else { return nil }
        return try? P256.Signing.PrivateKey(rawRepresentation: raw)
    }

    var isValid: Bool {
        format == Self.format && version == Self.version && !host.isEmpty && (1...65535).contains(port)
            && !relayID.isEmpty && memberKey != nil
            && (cert == nil) == (scope == nil) && scope?.isEmpty != true
            && cert.map { Data(base64Encoded: $0) != nil } != false
    }
}

/// 主机带来的中继配置（邀请里的、或连上后主机发来的）该记在哪。
nonisolated enum RemoteRelayPlacement: Equatable, Sendable {
    /// 本机还没有默认中继，或就是默认那台（换了成员密钥）：存成默认。
    case setDefault
    /// 和默认的不是同一台：只给这台主机用，不顶掉默认（本机连的其他主机还在默认中继上）。
    case perHost
    /// 和默认的一模一样：什么都不用记。
    case keep

    /// `adoptsAsDefault` 为 false（Mac 当主控端）时从不改默认中继：默认的那台也是它自己被控时用的。
    ///
    /// 成员证书只能连发证的那台主机，从不当默认：默认中继存在 iCloud 钥匙串里，会同步到本人的 Mac，而 Mac
    /// 被控时要拿它注册，证书注册不了。默认就是同一台中继的成员密钥（什么都能连）时证书也不用记。
    static func place(_ incoming: RemoteRelayConfig, current: RemoteRelayConfig?,
                      adoptsAsDefault: Bool = true) -> RemoteRelayPlacement {
        if incoming == current { return .keep }
        if incoming.isCertificate {
            if let current, current.relayID == incoming.relayID, !current.isCertificate { return .keep }
            return .perHost
        }
        guard adoptsAsDefault else { return .perHost }
        guard let current, current.relayID != incoming.relayID else { return .setDefault }
        return .perHost
    }
}

/// 中继配置的存放处：iCloud 钥匙串，同一 Apple ID 的设备自动拿到。
nonisolated final class RemoteRelayConfigStore: @unchecked Sendable {
    private static let account = "default"
    private let storage: any RemoteSyncedStorage

    init(storage: any RemoteSyncedStorage = RemoteKeychainSyncedStorage(service: "com.uozi.uTerm.remote.relay")) {
        self.storage = storage
    }

    func load() -> RemoteRelayConfig? {
        storage.loadAll().lazy.compactMap { RemoteRelayConfig(importing: $0) }.first
    }

    func save(_ config: RemoteRelayConfig) throws {
        try storage.save(try JSONEncoder().encode(config), account: Self.account)
    }

    func clear() {
        try? storage.delete(account: Self.account)
    }
}
