import Foundation

extension RemoteMacDirectory.Mac {
    /// 「这台 Mac 现在在哪能连上」的几种写法（两端共用，各处只挑样式，不再各写一份）。
    nonisolated enum ReachabilityStyle {
        /// 列表与详情的一行状态：「在线 · 局域网」「在线 · 公网」「不在线」；没配对的是「局域网 · 未配对」。
        case status
        /// 只说走哪条路：「局域网」「公网」「不在线」（详情里的「网络路径」、手机列表行的右侧）。
        case path
        /// 网络诊断：两条路各自在不在，「在线 · 局域网 · 中继」「在线 · 中继」「不在线」。
        case routes
    }

    /// 局域网那一半看什么：`onLocalNetwork` 为 nil 时看 `endpoint`（正式连接的口径，「只走公网」打开时为 nil）；
    /// 网络诊断传 Bonjour 原始结果（`RemoteMacDirectory.isOnLocalNetwork`），它照样测局域网。
    nonisolated func reachabilityLabel(_ style: ReachabilityStyle, onLocalNetwork: Bool? = nil) -> String {
        let onLAN = onLocalNetwork ?? (endpoint != nil)
        switch style {
        case .status:
            if source == .nearby { return String(localized: "局域网 · 未配对") }
            if onLAN { return String(localized: "在线 · 局域网") }
            if isOnRelay { return String(localized: "在线 · 公网") }
            return String(localized: "不在线")
        case .path:
            if onLAN { return String(localized: "局域网") }
            if isOnRelay { return String(localized: "公网") }
            return String(localized: "不在线")
        case .routes:
            let parts = [onLAN ? String(localized: "局域网") : nil, isOnRelay ? String(localized: "中继") : nil]
                .compactMap { $0 }
            return parts.isEmpty ? String(localized: "不在线")
                : String(localized: "在线 · \(parts.joined(separator: " · "))")
        }
    }
}
