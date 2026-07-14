import Foundation
import SwiftData

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
struct HostKeyChallenge: Equatable, Sendable, Identifiable {
    enum Kind: Sendable { case unknown, mismatch }
    let id = UUID()
    let host: String
    let port: Int
    let kind: Kind
    let newFingerprint: String
    /// 仅 `.mismatch` 时非 nil。
    let oldFingerprint: String?
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
}
