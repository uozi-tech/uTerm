import CryptoKit
import Foundation
import Security

/// 一台自建中继的连接信息，由 `uterm-relay config` 生成（格式见 `relay/PROTOCOL.md`）。
///
/// `key` 是成员私钥，等同口令：凭它能注册主机、看到谁在线、发起中继。但它进不了端到端加密的会话，
/// 连上来的人还要过配对身份和「允许经公网接入」。
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

    init(name: String, host: String, port: Int, relayID: String, key: String) {
        self.name = name
        self.host = host
        self.port = port
        self.relayID = relayID
        self.key = key
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
        self.init(name: items["n"] ?? host, host: host, port: port, relayID: relayID, key: raw.base64EncodedString())
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
    }
}

/// 主机带来的中继配置（邀请里的、或连上后主机发来的）该记在哪。
nonisolated enum RemoteRelayPlacement: Equatable, Sendable {
    /// 本机还没有默认中继，或就是默认那台（换了成员密钥）：存成默认。
    case setDefault
    /// 和默认的不是同一台：只给这台主机用，不顶掉默认（本机连的其他主机还在默认中继上）。
    case perHost

    static func place(_ incoming: RemoteRelayConfig, current: RemoteRelayConfig?) -> RemoteRelayPlacement {
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
