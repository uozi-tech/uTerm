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

    /// 加一台配对过的 Mac（默认在线）。
    @discardableResult
    func addMac(_ name: String, id: UUID = UUID(), publicKey: Data? = nil, online isOnline: Bool = true,
                relay: RemoteRelayConfig? = nil) -> RemoteGroupVouchTarget {
        let target = RemoteGroupVouchTarget(id: id, name: name,
                                            publicKey: publicKey ?? Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                            model: "Mac mini", platform: RemoteDevicePlatform.mac.rawValue, relay: relay)
        paired.removeAll { $0.id == id }
        paired.append(target)
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
        return .added
    }

    func revokeSibling(_ deviceID: UUID, publicKey: Data, at host: UUID) async throws -> RemoteSiblingRevokeResult {
        throw RemoteAttachError.rejected("测试里不撤销")
    }
}
