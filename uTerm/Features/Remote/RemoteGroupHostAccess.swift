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
    /// 本机信任表里此刻记着的这台 Mac（公钥与记下的时间）。没有返回 nil。
    func trustedHost(_ id: UUID) -> RemoteGroupTrustedHost?
    /// 拿掉一台只因为别的组员开通才记下的 Mac（G3）：**不拉黑**，不算「忘记」，以后别的组员再开通还能记回来。
    /// 本机此刻记着的公钥与记下的时间都和收下时一样才拿（你在这台设备上重新配对过的不动）。返回拿掉没有。
    func dropAdoptedHost(_ id: UUID, publicKey: Data, pairedAt: Date) -> Bool
}

/// 信任表里的一台 Mac（只要回滚时核对的那两项）。
struct RemoteGroupTrustedHost: Equatable {
    var publicKey: Data
    var pairedAt: Date

    /// 记下时间相同（经 JSON 来回可能差一个 ulp，按 1 毫秒内算）。
    func matches(publicKey: Data, pairedAt: Date) -> Bool {
        self.publicKey == publicKey && abs(self.pairedAt.timeIntervalSince(pairedAt)) < 0.001
    }
}

/// 这台 Mac 自己的被控端（只有 Mac 有；App 里是 `RemoteHostServer`，`RemoteHostServer+DeviceGroup.swift`）。
/// 设备组在 App 里把组员记成这台 Mac 的主控端（§7.3「组里的 Mac 互认」）；远控进程不读名册，
/// 远控进程在服务时由 `RemoteHostServer` 经 XPC 转过去（`RemoteHostAgentCommand.groupAddController` / `groupDropController`）。
@MainActor
protocol RemoteGroupLocalHost: AnyObject {
    /// 开着被控（「允许控制这台 Mac」）和「允许已配对的设备开通主人的其它设备」。
    var acceptsGroupControllers: Bool { get }
    /// 此刻信任的主控端。
    func groupControllerPeers() -> [RemoteGroupLocalController]
    /// Mac 主人在这台 Mac 上撤销过（拉黑）：永远不自动加回来。
    func isControllerBlocked(_ id: UUID) -> Bool
    /// 记下这台组员。转不过去（远控进程不在、版本太旧）回 nil。
    func addGroupController(_ device: RemoteGroupDevice) async -> RemoteVouchResult?
    /// 不拉黑地撤掉这台（被移除的）组员。转不过去回 nil。
    func dropGroupController(_ id: UUID, publicKey: Data) async -> RemoteSiblingRevokeResult?
}

/// 这台 Mac 信任的一台主控端。
struct RemoteGroupLocalController: Equatable {
    var id: UUID
    var publicKey: Data
    /// 经担保记下的（设备组，或别的设备担保的）。手动配对的为 false：设备组不动它。
    var isVouched: Bool
    /// 由这台 Mac 按设备组记下的（担保者是这台 Mac 自己）。
    var isFromGroup: Bool
    /// 担保它的设备（经担保记下的才有）。
    var vouchedBy: UUID? = nil
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

    func trustedHost(_ id: UUID) -> RemoteGroupTrustedHost? {
        identity.peer(id: id).map { RemoteGroupTrustedHost(publicKey: $0.publicKey, pairedAt: $0.pairedAt) }
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
