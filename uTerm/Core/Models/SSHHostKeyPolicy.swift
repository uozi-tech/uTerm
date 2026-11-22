import Foundation

/// SSH 主机密钥校验策略。UserDefaults key: `sshHostKeyPolicy`。默认 `.ask`。
///
/// 由 `SSHClientFactory` 在创建共享包的主机密钥校验器时读取。
/// setting 改了只对**下次 SSH 连接**生效——老连接保留
/// 原 policy 行为。
enum SSHHostKeyPolicy: String, CaseIterable, Identifiable {
    /// 严格：未知 / 不匹配主机密钥直接 reject 连接（不弹窗）。
    case strict
    /// 询问：未知 / 不匹配时弹窗让用户决定（当前默认 + 历史行为）。
    case ask
    /// 忽略：未知 / 不匹配都静默接受并覆盖 known-hosts。仅本地实验用，**不安全**。
    case none

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .strict: return String(localized: "严格", comment: "主机密钥校验策略")
        case .ask:    return String(localized: "询问", comment: "主机密钥校验策略")
        case .none:   return String(localized: "忽略", comment: "主机密钥校验策略")
        }
    }
}
