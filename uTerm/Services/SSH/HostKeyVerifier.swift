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
    /// 按 host:port 取既有记录（应至多一条；多于一条时取第一条）。
    private func existing(host: String, port: Int) -> KnownHost? {
        let h = host
        let p = port
        let descriptor = FetchDescriptor<KnownHost>(
            predicate: #Predicate { $0.host == h && $0.port == p }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func classify(host: String, port: Int,
                  keyBlob: Data, fingerprint: String) -> HostKeyClassification {
        guard let known = existing(host: host, port: port) else {
            return .unknown(fingerprint: fingerprint)
        }
        if known.keyBlob == keyBlob {
            return .trusted
        }
        return .mismatch(newFingerprint: fingerprint, oldFingerprint: known.fingerprint)
    }

    /// 写入新记录，或用新密钥覆盖既有记录（不匹配后用户选择信任）。
    func trust(host: String, port: Int, keyBlob: Data,
               keyType: String, fingerprint: String) {
        if let known = existing(host: host, port: port) {
            known.keyBlob = keyBlob
            known.keyTypeRaw = keyType
            known.fingerprint = fingerprint
            known.firstTrustedAt = Date()
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
        let h = host
        let p = port
        let descriptor = FetchDescriptor<KnownHost>(
            predicate: #Predicate { $0.host == h && $0.port == p }
        )
        return (try? modelContext.fetch(descriptor).count) ?? 0
    }
}
