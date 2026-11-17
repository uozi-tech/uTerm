import CryptoKit
import Foundation
@testable import uTerm

/// 测试用的「本机配对过的 Mac」：哪几台配对过、哪几台在线、每台怎么回担保请求，请求可以卡住（`held`）。
/// `adopt` 照 `RemoteMacDirectory.adopt` 的规则：同 ID 公钥不同不覆盖、忘记过的不加回。
@MainActor
final class RemoteGroupFakeHosts: RemoteGroupHostAccess {
    enum Reply {
        case outcome(RemoteVouchResult.Outcome, reason: String? = nil, internetAccess: Bool? = nil,
                     relay: RemoteRelayConfig? = nil)
        /// 连不上。
        case unreachable
        /// Mac 上的 uTerm 太旧（`RemoteMacClient.vouch(for:)` 抛的那个）。
        case tooOld
    }

    struct Call: Equatable {
        let device: UUID
        let host: UUID
    }

    /// 每台 Mac 上发生的事，按先后（撤销与开通的先后用）。
    enum Event: Equatable {
        case vouch(device: UUID, key: Data)
        case revoke(device: UUID, key: Data)
    }

    enum RevokeReply {
        /// `requesterRevoked`：Mac 按资历规则把发请求的本机也一起撤了（§18）。
        case outcome(RemoteSiblingRevokeResult.Outcome, requesterRevoked: Bool? = nil)
        case unreachable
        case tooOld
    }

    var paired: [RemoteGroupVouchTarget] = []
    var online: Set<UUID> = []
    /// 每台 Mac 怎么回；没写的回 `added`。
    var replies: [UUID: Reply] = [:]
    /// 这几台 Mac 的请求卡住，直到从这里拿掉。
    var held: Set<UUID> = []
    var forgotten: Set<UUID> = []
    private(set) var calls: [Call] = []
    /// 卡住的请求被取消了几次。
    private(set) var cancelled = 0
    private(set) var adopted: [RemoteGroupGrant] = []
    /// 每台 Mac 怎么回撤销请求；没写的回 `revoked`。
    var revokeReplies: [UUID: RevokeReply] = [:]
    private(set) var revokeCalls: [Call] = []
    private(set) var events: [UUID: [Event]] = [:]
    /// 信任表里每台 Mac 的记下时间（回滚核对用）。
    var pairedAt: [UUID: Date] = [:]
    /// `dropAdoptedHost` 拿掉的 Mac。
    private(set) var dropped: [UUID] = []
    /// 设备组请目录补问在不在线的次数（`refreshReachability`）。
    private(set) var reachabilityRefreshes = 0

    /// 加一台配对过的 Mac（默认在线）。
    @discardableResult
    func addMac(_ name: String, id: UUID = UUID(), publicKey: Data? = nil, online isOnline: Bool = true,
                relay: RemoteRelayConfig? = nil) -> RemoteGroupVouchTarget {
        let target = RemoteGroupVouchTarget(id: id, name: name,
                                            publicKey: publicKey ?? Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                            model: "Mac mini", platform: RemoteDevicePlatform.mac.rawValue, relay: relay)
        paired.removeAll { $0.id == id }
        paired.append(target)
        pairedAt[id] = Date(timeIntervalSince1970: 1_700_000_000 + Double(paired.count))
        if isOnline { online.insert(id) }
        return target
    }

    /// 本机给这台 Mac 记的公钥换了（Mac 重装后重新配对）。
    func repair(_ id: UUID, publicKey: Data) {
        guard let index = paired.firstIndex(where: { $0.id == id }) else { return }
        paired[index].publicKey = publicKey
    }

    func calls(at host: UUID) -> [UUID] { calls.filter { $0.host == host }.map(\.device) }

    func vouchTargets() -> [RemoteGroupVouchTarget] { paired.filter { online.contains($0.id) } }

    func pairedHosts() -> [RemoteGroupVouchTarget] { paired }

    func vouch(_ device: RemoteGroupDevice, at host: UUID) async throws -> RemoteVouchResult {
        calls.append(Call(device: device.id, host: host))
        events[host, default: []].append(.vouch(device: device.id, key: device.publicKey))
        while held.contains(host) {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        if Task.isCancelled {
            cancelled += 1
            throw CancellationError()
        }
        switch replies[host] ?? .outcome(.added) {
        case let .outcome(outcome, reason, internetAccess, relay):
            return RemoteVouchResult(requestID: UUID(), outcome: outcome, reason: reason, internetAccess: internetAccess,
                                     relay: relay)
        case .unreachable:
            throw RemoteAttachError.unreachable("连不上")
        case .tooOld:
            throw RemoteAttachError.rejected("这台 Mac 上的 uTerm 版本太旧")
        }
    }

    func adopt(_ grant: RemoteGroupGrant) -> RemoteGroupAdoption {
        adopted.append(grant)
        if let existing = paired.first(where: { $0.id == grant.hostID }) {
            return existing.publicKey == grant.hostKey ? .alreadyKnown : .conflict
        }
        if forgotten.contains(grant.hostID) { return .forgotten }
        paired.append(RemoteGroupVouchTarget(id: grant.hostID, name: grant.hostName, publicKey: grant.hostKey,
                                             model: grant.hostModel, platform: grant.hostPlatform, relay: grant.relay))
        pairedAt[grant.hostID] = Date(timeIntervalSince1970: 1_750_000_000 + Double(adopted.count))
        return .added
    }

    func revokeSibling(_ deviceID: UUID, publicKey: Data, at host: UUID) async throws -> RemoteSiblingRevokeResult {
        revokeCalls.append(Call(device: deviceID, host: host))
        events[host, default: []].append(.revoke(device: deviceID, key: publicKey))
        while held.contains(host) {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        if Task.isCancelled {
            cancelled += 1
            throw CancellationError()
        }
        switch revokeReplies[host] ?? .outcome(.revoked) {
        case let .outcome(outcome, requesterRevoked):
            return RemoteSiblingRevokeResult(requestID: UUID(), outcome: outcome, requesterRevoked: requesterRevoked)
        case .unreachable: throw RemoteAttachError.unreachable("连不上")
        case .tooOld: throw RemoteAttachError.rejected("这台 Mac 上的 uTerm 版本太旧")
        }
    }

    func revokeCalls(at host: UUID) -> [UUID] { revokeCalls.filter { $0.host == host }.map(\.device) }

    func trustedHost(_ id: UUID) -> RemoteGroupTrustedHost? {
        guard let target = paired.first(where: { $0.id == id }) else { return nil }
        return RemoteGroupTrustedHost(publicKey: target.publicKey, pairedAt: pairedAt[id] ?? .distantPast)
    }

    func refreshReachability() { reachabilityRefreshes += 1 }

    func dropAdoptedHost(_ id: UUID, publicKey: Data, pairedAt: Date) -> Bool {
        guard let trusted = trustedHost(id), trusted.matches(publicKey: publicKey, pairedAt: pairedAt) else { return false }
        paired.removeAll { $0.id == id }
        online.remove(id)
        self.pairedAt[id] = nil
        dropped.append(id)
        return true
    }
}

/// 测试用的「这台 Mac 自己的被控端」（`RemoteGroupLocalHost`）：规则照 `RemoteHostServer.handleGroupController` /
/// `handleGroupDrop`（拉黑的不加、公钥不同不替换、只撤经担保记下的）。`available` 为 false 时像远控进程不在：回 nil。
@MainActor
final class RemoteGroupFakeLocalHost: RemoteGroupLocalHost {
    /// 这台 Mac 自己的设备 ID（设备组记下的担保者就是它）。
    var hostID = UUID()
    var accepts = true
    var available = true
    var peers: [UUID: RemoteGroupLocalController] = [:]
    var blocked: Set<UUID> = []
    private(set) var addCalls: [UUID] = []
    private(set) var dropCalls: [UUID] = []

    var acceptsGroupControllers: Bool { accepts }

    func groupControllerPeers() -> [RemoteGroupLocalController] {
        peers.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func isControllerBlocked(_ id: UUID) -> Bool { blocked.contains(id) }

    /// Mac 主人在这台 Mac 上手动配对过它。
    func pairManually(_ device: RemoteGroupDevice) {
        peers[device.id] = RemoteGroupLocalController(id: device.id, publicKey: device.publicKey, isVouched: false,
                                                      isFromGroup: false)
    }

    /// 一台已信任的主控端经消息 50 替 `device` 担保（被控端照 `decide`：拉黑的、已认识的不加）。
    @discardableResult
    func vouch(_ device: RemoteGroupDevice, by voucher: UUID) -> Bool {
        guard peers[voucher] != nil, peers[device.id] == nil, !blocked.contains(device.id) else { return false }
        peers[device.id] = RemoteGroupLocalController(id: device.id, publicKey: device.publicKey, isVouched: true,
                                                      isFromGroup: false, vouchedBy: voucher)
        return true
    }

    /// Mac 主人在这台 Mac 上撤销（拉黑）。
    func ownerRevoke(_ id: UUID) {
        peers[id] = nil
        blocked.insert(id)
    }

    func addGroupController(_ device: RemoteGroupDevice) async -> RemoteVouchResult? {
        guard available else { return nil }
        addCalls.append(device.id)
        if blocked.contains(device.id) { return RemoteVouchResult(requestID: UUID(), outcome: .rejected, reason: "撤销过") }
        if let peer = peers[device.id] {
            return peer.publicKey == device.publicKey
                ? RemoteVouchResult(requestID: UUID(), outcome: .alreadyTrusted, internetAccess: false)
                : RemoteVouchResult(requestID: UUID(), outcome: .rejected, reason: "换过钥匙")
        }
        peers[device.id] = RemoteGroupLocalController(id: device.id, publicKey: device.publicKey, isVouched: true,
                                                      isFromGroup: true, vouchedBy: hostID)
        return RemoteVouchResult(requestID: UUID(), outcome: .added, internetAccess: false)
    }

    func dropGroupController(_ id: UUID, publicKey: Data) async -> RemoteSiblingRevokeResult? {
        guard available else { return nil }
        dropCalls.append(id)
        guard let peer = peers[id], peer.publicKey == publicKey else {
            return RemoteSiblingRevokeResult(requestID: UUID(), outcome: .notTrusted)
        }
        guard peer.isVouched else { return RemoteSiblingRevokeResult(requestID: UUID(), outcome: .notInFamily) }
        // 同 `handleGroupDrop`：连带撤掉一层层由它担保的。
        var vouches: [UUID: RemotePeerVouch] = [:]
        for peer in peers.values {
            guard let voucher = peer.vouchedBy else { continue }
            vouches[peer.id] = RemotePeerVouch(deviceID: peer.id, deviceName: "", vouchedBy: voucher, voucherName: "",
                                               family: hostID, vouchedAt: Date())
        }
        for removed in RemoteVouchPolicy.cascade(from: id, keeping: nil, trusted: Array(peers.keys), vouches: vouches) {
            peers[removed] = nil
        }
        return RemoteSiblingRevokeResult(requestID: UUID(), outcome: .revoked)
    }
}
