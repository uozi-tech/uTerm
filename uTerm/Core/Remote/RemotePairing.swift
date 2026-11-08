import CryptoKit
import Foundation
import Security

// 配对（两端共用）。不论是不是同一 Apple ID，每对设备都要配对一次，信任只记在本机（`RemoteIdentityStore`）：
// - 局域网审批：主控端连上来，被控端弹窗显示核对码，人点「允许」。
// - 邀请：被控端出一张一次性邀请（`RemotePairingInvitation`），主控端扫码或打开链接就知道该信任哪台主机、
//   哪把公钥；连接时在握手消息里带上凭据（`RemotePairingInvitation.proof`），被控端核对通过就信任它，不用人点。

/// 被控端出示的配对邀请，编成二维码给手机扫，或作为 `uterm://pair` 链接发给另一台设备。
///
/// 一次性、有时限：令牌用过一次或过期就作废（Mac 端管）。凭据绑定两端的长期公钥，旁观者截到握手消息也
/// 换不到别的设备上用。
///
/// 被控端开着公网接入时，邀请还带上它的中继配置（`relay`），对方不在同一网络、不是同一 Apple ID 也能配对。
/// 中继 1.2.0 起带的是只能连这台主机的成员证书（邀请没用掉就作废时吊销）；老中继上带的仍是所有成员共用的
/// 成员密钥，等于把中继分享给了对方。
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
    /// 被控端所在的中继。nil = 只能在局域网里配对。
    var relay: RemoteRelayConfig?

    init(macID: UUID, macName: String, macKey: Data, token: Data, relay: RemoteRelayConfig? = nil) {
        self.macID = macID
        self.macName = macName
        self.macKey = macKey
        self.token = token
        self.relay = relay
    }

    /// 新的随机令牌。
    static func newToken() -> Data {
        var bytes = [UInt8](repeating: 0, count: tokenLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, tokenLength, &bytes)
        return Data(bytes)
    }

    /// `uterm://pair?v=1&d=<设备 ID>&n=<名字>&k=<公钥>&t=<令牌>`，二进制用 base64url。带中继时再加
    /// `rn` / `rh` / `rp` / `ri` / `rk`（名字、地址、端口、中继 ID、成员密钥），成员证书再加 `rs` / `rc` / `re`
    /// （能连的主机、证书、到期时间）。版本号不变：老版本不认这几个键，照样能在局域网里配对。
    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        var items = [
            URLQueryItem(name: "v", value: String(Self.version)),
            URLQueryItem(name: "d", value: macID.uuidString),
            URLQueryItem(name: "n", value: macName),
            URLQueryItem(name: "k", value: macKey.base64URLEncoded),
            URLQueryItem(name: "t", value: token.base64URLEncoded),
        ]
        if let relay, let key = Data(base64Encoded: relay.key) {
            items += [
                URLQueryItem(name: "rn", value: relay.name),
                URLQueryItem(name: "rh", value: relay.host),
                URLQueryItem(name: "rp", value: String(relay.port)),
                URLQueryItem(name: "ri", value: relay.relayID),
                URLQueryItem(name: "rk", value: key.base64URLEncoded),
            ]
            if let scope = relay.scope, let cert = relay.cert.flatMap({ Data(base64Encoded: $0) }) {
                items += [URLQueryItem(name: "rs", value: scope), URLQueryItem(name: "rc", value: cert.base64URLEncoded)]
                if let expires = relay.expires { items.append(URLQueryItem(name: "re", value: String(expires))) }
            }
        }
        components.queryItems = items
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
        self.init(macID: id, macName: name, macKey: key, token: token, relay: Self.relay(from: items))
    }

    /// 中继参数缺一个或不合法就当没带：邀请仍能在局域网里用，不因为它整张作废。
    private static func relay(from items: [String: String]) -> RemoteRelayConfig? {
        guard let host = items["rh"], let port = items["rp"].flatMap(Int.init), let relayID = items["ri"],
              let key = items["rk"].flatMap(Data.init(base64URLEncoded:)) else { return nil }
        let config = RemoteRelayConfig(name: items["rn"] ?? host, host: host, port: port, relayID: relayID,
                                       key: key.base64EncodedString(), scope: items["rs"],
                                       cert: items["rc"].flatMap(Data.init(base64URLEncoded:))?.base64EncodedString(),
                                       expires: items["re"].flatMap(Int64.init))
        return config.isValid ? config : nil
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

// MARK: - 旧版 iCloud 名册的清理

/// 之前的测试版里，同一 Apple ID 的设备把公开身份写进 iCloud 钥匙串的名册，对得上就直接信任。现在所有设备都要
/// 配对，名册不再读；每台设备升级后撤下自己那一条，免得还没升级的设备继续凭它放行本机。
nonisolated enum RemoteLegacyRoster {
    static let service = "com.uozi.uTerm.remote.roster"

    static func withdraw(id: UUID, storage: any RemoteSyncedStorage = RemoteLocalState.syncedStorage(service: service)) {
        try? storage.delete(account: id.uuidString)
    }

    /// 启动时调：同步钥匙串的删除可能要等 iCloud，放到后台线程。
    static func withdrawLocalDevice() {
        let id = RemoteLocalDevice.id()
        DispatchQueue.global(qos: .utility).async { withdraw(id: id) }
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
