import Foundation

/// 已知主机指纹的展示与过滤规则（macOS「已知主机指纹」窗口与 iOS `FingerprintsView` 共用）。
///
/// 规则写成吃原始字段的纯函数（`nonisolated`，测试不必建 SwiftData 容器）；
/// `KnownHost` 上的同名属性只是转发。
nonisolated enum KnownHostDisplay {
    /// 「host」或「host:port」：22 是默认端口，不写。
    static func address(host: String, port: Int) -> String {
        port == 22 ? host : "\(host):\(port)"
    }

    /// 密钥类型去掉 `ssh-` 前缀：`ssh-ed25519` → `ed25519`，`rsa-sha2-256` 原样。
    static func keyTypeLabel(_ raw: String) -> String {
        raw.hasPrefix("ssh-") ? String(raw.dropFirst(4)) : raw
    }

    /// 搜索框过滤：按地址（含端口）或指纹做不区分大小写的子串匹配；空查询全部匹配。
    static func matches(query: String, host: String, port: Int, fingerprint: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return address(host: host, port: port).localizedCaseInsensitiveContains(needle)
            || fingerprint.localizedCaseInsensitiveContains(needle)
    }
}

/// 已知主机指纹相关的文案（删除确认 / 空状态），两端一字不差。
nonisolated enum KnownHostCopy {
    static func deleteTitle(address: String) -> String { "删除「\(address)」的指纹？" }
    static let deleteMessage = "下次连接这台主机时会重新要求确认指纹。经 iCloud 同步的设备上也会删除。"
    static let emptyTitle = "暂无已知主机"
    static let emptyMessage = "首次连接并信任一台主机后，它的密钥指纹会记录在此。"
}

extension KnownHost {
    var displayAddress: String { KnownHostDisplay.address(host: host, port: port) }
    var keyTypeLabel: String { KnownHostDisplay.keyTypeLabel(keyTypeRaw) }
    /// 信任日期「2026-09-28」。
    var trustedDateText: String { UTermFormat.date(firstTrustedAt) }

    func matches(_ query: String) -> Bool {
        KnownHostDisplay.matches(query: query, host: host, port: port, fingerprint: fingerprint)
    }
}
