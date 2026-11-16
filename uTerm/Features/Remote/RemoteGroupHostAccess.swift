import Foundation

// 设备组替组员向 Mac 开通、撤销要用到的那一层（两端共用）：本机配对过的 Mac 有哪些、经那条远控连接请 Mac
// 记下（消息 50 / 51，`RemoteMacClient.vouch(for:)`）或撤销（消息 52 / 53，`RemoteMacClient.revokeSibling`）一台
// 设备、把别的组员替本机开通的 Mac 记进信任表（`RemoteMacDirectory.adopt`）。
//
// 调用方是 `RemoteDeviceGroup+Hosts.swift`（G2，docs/remote-device-group-design.md §7.2）。

/// 本机配对过的一台 Mac（`vouchTargets` 里是此刻能问到的那些）。
struct RemoteGroupVouchTarget: Equatable {
    var id: UUID
    var name: String
    var publicKey: Data
    var model: String?
    var platform: String?
    /// 本机给这台 Mac 单独记的中继，交给新设备用。成员证书是发给本机的，不交出去。
    var relay: RemoteRelayConfig?

    /// 写进 `host` / `grant` 的公开信息。
    var hostInfo: RemoteGroupHostInfo {
        RemoteGroupHostInfo(id: id, name: name, publicKey: publicKey, model: model,
                            platform: platform ?? RemoteDevicePlatform.mac.rawValue)
    }
}

/// 新设备收下一台 Mac 的结果。
enum RemoteGroupAdoption: Equatable {
    case added
    case alreadyKnown
    case conflict
    case forgotten
}

/// 一台 Mac 对一台组员的开通结果（明文）。名册里是签了名的 `RemoteGroupHostGrant`，中继配置单独封给那台组员。
nonisolated struct RemoteGroupGrant: Codable, Equatable, Sendable {
    /// 那台 Mac 的公开身份。
    var hostID: UUID
    var hostName: String
    var hostKey: Data
    var hostModel: String?
    var hostPlatform: String?
    /// `RemoteVouchResult.Outcome` 的原始值，另加 `unsupported`（Mac 版本太旧，没问）。
    var outcome: String
    var reason: String?
    var internetAccess: Bool?
    /// 新设备连这台 Mac 用的中继：Mac 发的成员证书，或担保者给这台 Mac 单独记的中继。
    var relay: RemoteRelayConfig?

    static let unsupported = "unsupported"

    /// Mac 记下了新设备（或早就认识它）：新设备可以把这台 Mac 记进自己的信任表。
    var isUsable: Bool {
        outcome == RemoteVouchResult.Outcome.added.rawValue || outcome == RemoteVouchResult.Outcome.alreadyTrusted.rawValue
    }

    /// 不用再问这台 Mac 了。`not-allowed` 与 `unsupported` 过一阵再问（Mac 的主人可能会打开开关、更新 uTerm）。
    var isFinal: Bool {
        isUsable || outcome == RemoteVouchResult.Outcome.rejected.rawValue
    }
}

/// 开通要用到的、本机配对过的 Mac。App 里是 `RemoteMacDirectory`，测试里换成直连测试服务端的。
@MainActor
protocol RemoteGroupHostAccess: AnyObject {
    /// 配对过、此刻在线、问得到的 Mac。
    func vouchTargets() -> [RemoteGroupVouchTarget]
    /// 所有配对过的 Mac（不管在不在线）：发 `host`、判断哪台本机已经能用。
    func pairedHosts() -> [RemoteGroupVouchTarget]
    /// 请这台 Mac 记下那台组员。连不上抛错。
    func vouch(_ device: RemoteGroupDevice, at host: UUID) async throws -> RemoteVouchResult
    /// 新设备：把别的组员替本机开通的 Mac 记进信任表。
    func adopt(_ grant: RemoteGroupGrant) -> RemoteGroupAdoption
    /// 请这台 Mac 撤销被移除的那台设备。连不上抛错，Mac 太旧抛 `RemoteAttachError.rejected`。
    func revokeSibling(_ deviceID: UUID, publicKey: Data, at host: UUID) async throws -> RemoteSiblingRevokeResult
}

extension RemoteGroupHostAccess {
    /// 所有配对过的 Mac：id → 名字。
    func pairedHostNames() -> [UUID: String] {
        Dictionary(pairedHosts().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - App 里：配对过的 Mac 就是目录里那些

extension RemoteMacDirectory: RemoteGroupHostAccess {
    func vouchTargets() -> [RemoteGroupVouchTarget] {
        groupTargets(macs.filter(\.isOnline))
    }

    func pairedHosts() -> [RemoteGroupVouchTarget] {
        groupTargets(macs)
    }

    /// 名字取 Mac 自己报的（不取本机起的别名，也不取 Bonjour 看到的电脑名：两样都会变，变一次就重签一次 `host`）。
    /// 设备组每一轮都调：信任表只读一次。
    private func groupTargets(_ list: [Mac]) -> [RemoteGroupVouchTarget] {
        let paired = list.filter { $0.source == .paired && $0.deviceID != nil && $0.publicKey != nil }
        guard !paired.isEmpty else { return [] }
        let peers = Dictionary(identity.trustedPeers().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return paired.compactMap { mac in
            guard let id = mac.deviceID, let key = mac.publicKey else { return nil }
            let peer = peers[id]
            return RemoteGroupVouchTarget(id: id, name: peer?.name ?? mac.name, publicKey: key, model: peer?.model,
                                          platform: peer?.platform,
                                          relay: peer?.relay.flatMap { $0.isCertificate ? nil : $0 })
        }
    }

    func vouch(_ device: RemoteGroupDevice, at host: UUID) async throws -> RemoteVouchResult {
        guard let mac = macs.first(where: { $0.deviceID == host }) else { throw RemoteProtocolError.closed }
        // 已经开着这台 Mac 的连接就借用；没开就临时连一下，问完放掉（Mac 上按窗口计数，iOS 留着，退后台时一起收）。
        if let existing = existingClient(macID: mac.id) { return try await existing.vouch(for: device) }
        #if os(macOS)
        let client = acquireClient(for: mac)
        defer { releaseClient(macID: mac.id) }
        return try await client.vouch(for: device)
        #else
        return try await client(for: mac).vouch(for: device)
        #endif
    }

    func revokeSibling(_ deviceID: UUID, publicKey: Data, at host: UUID) async throws -> RemoteSiblingRevokeResult {
        guard let mac = macs.first(where: { $0.deviceID == host }) else { throw RemoteProtocolError.closed }
        if let existing = existingClient(macID: mac.id) { return try await existing.revokeSibling(deviceID, publicKey: publicKey) }
        #if os(macOS)
        let client = acquireClient(for: mac)
        defer { releaseClient(macID: mac.id) }
        return try await client.revokeSibling(deviceID, publicKey: publicKey)
        #else
        return try await client(for: mac).revokeSibling(deviceID, publicKey: publicKey)
        #endif
    }
}
