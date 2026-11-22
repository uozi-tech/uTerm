import Foundation

extension SSHHostKeyPolicy {
    /// 设置页「主机密钥校验」随当前档位变化的说明（两端同一句）。
    var settingsHint: String {
        switch self {
        case .strict: return String(localized: "未知 / 不匹配的主机密钥直接拒绝连接，不弹窗。")
        case .ask:    return String(localized: "未知 / 不匹配时弹窗让你决定（默认，推荐）。")
        case .none:   return String(localized: "不安全：主机密钥未知或不匹配都直接信任，仅用于本地测试。")
        }
    }
}
