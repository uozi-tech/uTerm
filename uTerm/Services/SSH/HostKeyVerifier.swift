import Foundation
import SwiftData
import USSHKit

/// 主机密钥的分类结果。`keyBlob` 相等即视为同一密钥。
enum HostKeyClassification: Sendable {
    case trusted
    case unknown(fingerprint: String)
    case mismatch(newFingerprint: String, oldFingerprint: String)
}

extension HostKeyClassification: Equatable {
    nonisolated static func == (lhs: HostKeyClassification,
                                rhs: HostKeyClassification) -> Bool {
        switch (lhs, rhs) {
        case (.trusted, .trusted):
            return true
        case (.unknown(let a), .unknown(let b)):
            return a == b
        case (.mismatch(let an, let ao), .mismatch(let bn, let bo)):
            return an == bn && ao == bo
        default:
            return false
        }
    }
}

/// 向用户征询时所需的纯数据。
///
/// 除了主机密钥的两态，还有一种不是主机密钥的问题也走这条通路（`.weakAlgorithms`）：信任过的主机这次只肯用
/// SHA-1 时代的旧算法，连之前问用户（`LegacyAlgorithmGate`）。它没有指纹，`newFingerprint` 是空串。
/// 走同一条通路是为了复用现成的弹层、合并与「不能问用户就拒绝」的那些审批闭包——它们不认识这一种时也只会拒绝。
struct HostKeyChallenge: Equatable, Sendable, Identifiable {
    enum Kind: Sendable {
        case unknown, mismatch
        /// 以前用较新的连接方式连过，这次服务器只提供较旧的（SHA-1），要不要照样连。
        case weakAlgorithms
    }
    let id = UUID()
    let host: String
    let port: Int
    let kind: Kind
    let newFingerprint: String
    /// 仅 `.mismatch` 时非 nil。
    let oldFingerprint: String?
    /// `.weakAlgorithms` 时：问的是跳板机（`host` / `port` 是跳板机的）。
    var isJumpHost = false

    /// 是不是「连接方式变弱了」那一问。`nonisolated`：审批闭包在 NIO 线程上调，`Kind` 的 Equatable 是主线程隔离的。
    nonisolated var isWeakAlgorithms: Bool {
        if case .weakAlgorithms = kind { return true }
        return false
    }

    /// 同一个问题的合并键（`HostKeyApprovalCoalescer`）：主机密钥按「哪台 + 哪把钥匙」，连接方式按「哪台」。
    nonisolated var coalescingKey: String {
        if isWeakAlgorithms { return "\(host):\(port) weak-algorithms" }
        return "\(host):\(port) \(newFingerprint)"
    }

    /// 给人看的「主机:端口」。IPv6 字面量加方括号（`[fe80::1]:22`），不然端口和地址混在一起。
    nonisolated var address: String { SSHAddressText.format(host: host, port: port) }

    /// 「连接方式变弱了」那一问。
    nonisolated static func weakAlgorithms(_ request: SSHLegacyFallbackRequest) -> HostKeyChallenge {
        HostKeyChallenge(host: request.host, port: request.port, kind: .weakAlgorithms,
                         newFingerprint: "", oldFingerprint: nil, isJumpHost: request.hop == .jumpHost)
    }
}

/// 给人看的「主机:端口」：IPv6 字面量加方括号，其余原样。
nonisolated enum SSHAddressText {
    static func format(host: String, port: Int) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]:\(String(port))" : "\(host):\(String(port))"
    }
}

/// 用户在卡片上看过、点了放行的那一问（并行执行的「信任并重试」「仍然连接并重试」）。重连时只放行和它
/// 一模一样的那一问——哪台、哪个端口、哪一跳、什么问题、哪把钥匙都对得上；别的（跳板机后面的目标、换了一把钥匙、
/// 变成「密钥已变化」）照常拒绝、另出一张卡片，不会被这一下顺手放过去。
nonisolated struct HostKeyApprovalPin: Sendable, Equatable {
    let host: String
    let port: Int
    let isJumpHost: Bool
    let kind: String
    let fingerprint: String

    init(_ challenge: HostKeyChallenge) {
        host = challenge.host
        port = challenge.port
        isJumpHost = challenge.isJumpHost
        switch challenge.kind {
        case .unknown: kind = "unknown"
        case .mismatch: kind = "mismatch"
        case .weakAlgorithms: kind = "weak-algorithms"
        }
        fingerprint = challenge.newFingerprint
    }

    func matches(_ challenge: HostKeyChallenge) -> Bool {
        HostKeyApprovalPin(challenge) == self
    }
}

/// known-hosts 存储与 TOFU 决策。`@ModelActor` 使其自带一个由 `ModelContainer`
/// 构造的隔离 `ModelContext`（`ModelContainer` 是 `Sendable`，`ModelContext` 不是）。
@ModelActor
actor HostKeyVerifier {
    /// 按 host:port 取全部既有记录。
    ///
    /// SwiftData + CloudKit 不能给 `host + port` 建唯一约束；离线设备合并时可能
    /// 产生重复记录。主机密钥是安全边界，绝不能像普通展示数据一样随便取 `.first`：
    /// 若重复记录里同时存在不同密钥，取值顺序会决定是否错误地静默信任旧密钥。
    private func existing(host: String, port: Int) -> [KnownHost] {
        let h = host
        let p = port
        let descriptor = FetchDescriptor<KnownHost>(
            predicate: #Predicate { $0.host == h && $0.port == p },
            sortBy: [SortDescriptor(\.firstTrustedAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func classify(host: String, port: Int,
                  keyBlob: Data, fingerprint: String) -> HostKeyClassification {
        let knownHosts = existing(host: host, port: port)
        guard !knownHosts.isEmpty else {
            return .unknown(fingerprint: fingerprint)
        }
        // 只有全部同步副本都同意当前密钥才可静默通过。一个匹配、一个冲突也必须
        // fail closed 进入 mismatch，让用户明确处理 CloudKit 冲突/主机换钥。
        if knownHosts.allSatisfy({ $0.keyBlob == keyBlob }) {
            return .trusted
        }
        let conflicting = knownHosts.first { $0.keyBlob != keyBlob } ?? knownHosts[0]
        return .mismatch(newFingerprint: fingerprint,
                         oldFingerprint: conflicting.fingerprint)
    }

    /// 写入新记录，或用新密钥覆盖既有记录（不匹配后用户选择信任）。
    func trust(host: String, port: Int, keyBlob: Data,
               keyType: String, fingerprint: String) {
        let knownHosts = existing(host: host, port: port)
        if let known = knownHosts.first {
            known.keyBlob = keyBlob
            known.keyTypeRaw = keyType
            known.fingerprint = fingerprint
            known.firstTrustedAt = Date()
            // 用户已经明确批准当前密钥：收敛 CloudKit 产生的重复项，避免下一次
            // classify 再被陈旧副本影响。保留排序后的最新项作为 canonical 记录。
            for duplicate in knownHosts.dropFirst() {
                modelContext.delete(duplicate)
            }
        } else {
            let h = KnownHost()
            h.host = host
            h.port = port
            h.keyBlob = keyBlob
            h.keyTypeRaw = keyType
            h.fingerprint = fingerprint
            modelContext.insert(h)
        }
        try? modelContext.save()
    }

    /// 测试辅助：某 host:port 的记录条数。
    func knownHostCount(host: String, port: Int) -> Int {
        existing(host: host, port: port).count
    }

    /// 信任库里有没有这台 host:port 的记录（不管密钥对不对得上）。有就说明以前连上过它（`LegacyAlgorithmGate` 用）。
    /// 这台以前信任过没有（「连接方式变弱了」那一问用）。主机名不分大小写、IPv6 方括号不算：同一台换个写法
    /// 不能被当成第一次连、静默放行旧算法。
    func hasTrustRecord(host: String, port: Int) -> Bool {
        if !existing(host: host, port: port).isEmpty { return true }
        let wanted = LegacyAlgorithmConsent.Address.normalized(host)
        let p = port
        let descriptor = FetchDescriptor<KnownHost>(predicate: #Predicate { $0.port == p })
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.contains { LegacyAlgorithmConsent.Address.normalized($0.host) == wanted }
    }
}

extension HostKeyVerifier: USSHKit.HostKeyStore {
    func verify(_ hostKey: USSHKit.SSHHostKey) -> USSHKit.SSHHostKeyVerification {
        switch classify(
            host: hostKey.host,
            port: hostKey.port,
            keyBlob: hostKey.keyBlob,
            fingerprint: hostKey.fingerprint
        ) {
        case .trusted:
            return .trusted
        case .unknown:
            return .unknown
        case .mismatch(_, let oldFingerprint):
            return .mismatch(previousFingerprint: oldFingerprint)
        }
    }

    func remember(_ hostKey: USSHKit.SSHHostKey) {
        trust(
            host: hostKey.host,
            port: hostKey.port,
            keyBlob: hostKey.keyBlob,
            keyType: hostKey.keyType,
            fingerprint: hostKey.fingerprint
        )
    }
}
