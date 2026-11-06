import Foundation

/// iOS 的「本地网络」授权：App 第一次连局域网里的地址时系统弹框。按 Apple 的做法，授权应在用户真正用到时
/// 才请求——首启就弹，用户不知道为什么要给，多半拒绝（1.2.6 的首启卡死也与这个授权有关，见 `7df5a09a`）。
///
/// 这里记一笔「用户已经用过本地网络」：主动连过 SSH 主机、开过局域网同步接收、点过「连接我的 Mac」。
/// 在那之前，后台的在线探测（`HostReachabilityMonitor`）不碰看起来在局域网里的地址。macOS 不受此限。
nonisolated enum LocalNetworkUse {
    /// 用户发起了一次连接（终端 / SFTP / 测试连接）：授权框若弹出，是在用户能理解的上下文里。
    static func markUsed(defaults: UserDefaults = .standard) {
        guard !TestHostEnvironment.isActive, !defaults.bool(forKey: DefaultsKey.localNetworkUsed) else { return }
        defaults.set(true, forKey: DefaultsKey.localNetworkUsed)
    }

    static func hasBeenUsed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: DefaultsKey.localNetworkUsed)
            || defaults.bool(forKey: DefaultsKey.lanSyncReceiverActivated)
            || defaults.bool(forKey: DefaultsKey.remoteBrowseActivated)
    }

    /// 后台探测能不能碰这个地址。macOS 一律可以；iOS 在用户用过本地网络之前只碰明显在公网上的地址。
    static func allowsBackgroundProbe(host: String, defaults: UserDefaults = .standard) -> Bool {
        #if os(iOS)
        return hasBeenUsed(defaults: defaults) || !mayBeLocal(host)
        #else
        return true
        #endif
    }

    /// 看起来可能在局域网里：私有 / 链路本地 / 唯一本地地址的字面量、`.local` 等局域网惯用后缀、不带点的单段主机名。
    /// 宁可多判：判错的代价只是这台主机暂时不显示在线圆点。
    static func mayBeLocal(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return true }
        if let octets = ipv4Octets(host) { return isLocalIPv4(octets) }
        if host.contains(":") { return isLocalIPv6(host) }
        guard host.contains(".") else { return true }
        let suffix = host.split(separator: ".").last.map(String.init) ?? host
        return localSuffixes.contains(suffix)
    }

    private static let localSuffixes: Set<String> = [
        "local", "lan", "home", "internal", "intranet", "corp", "localdomain", "arpa", "localhost", "private",
    ]

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func isLocalIPv4(_ o: [Int]) -> Bool {
        switch (o[0], o[1]) {
        case (10, _), (127, _), (169, 254), (192, 168): return true
        case (172, 16...31): return true
        case (100, 64...127): return true  // CGNAT：运营商级 NAT，也常见于 Tailscale 这类组网，按本地处理。
        default: return false
        }
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        let address = host.split(separator: "%").first.map(String.init) ?? host
        if address == "::1" { return true }
        guard let first = address.split(separator: ":", omittingEmptySubsequences: false).first,
              let head = UInt16(first, radix: 16) else { return true }
        return head & 0xFFC0 == 0xFE80 || head & 0xFE00 == 0xFC00
    }
}
