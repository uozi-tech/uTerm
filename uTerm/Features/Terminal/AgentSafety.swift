import Foundation

/// 「自然语言 → 真实执行」之间的信任拨盘（设计稿 `terminal-agent.jsx` 的安全档位）。
///
/// 这是把 LLM 产出的命令落到真实 SSH exec 之间的闸门：
/// - `.readAuto`（默认，最安全）：只读命令可自动执行，写操作仍需用户确认。
///   当前后端对所有工具调用都走「待确认」审批流，等价于「写操作需确认」；
///   只读自动放行是后续按白名单 / `readOnly` 标注细化的方向。
/// - `.confirm`：任何命令执行前都要确认（等于始终走审批流）。
/// - `.auto`：读写均自动执行（谨慎）—— 进入「待确认」即自动批准。
nonisolated enum AgentSafety: String, CaseIterable, Codable, Sendable, Identifiable {
    case readAuto
    case confirm
    case auto

    var id: String { rawValue }

    /// 拨盘标签。
    var label: String {
        switch self {
        case .readAuto: return "只读自动"
        case .confirm:  return "每步确认"
        case .auto:     return "自动执行"
        }
    }

    /// 拨盘项的副说明。
    var detail: String {
        switch self {
        case .readAuto: return "只读命令自动执行，写操作需确认"
        case .confirm:  return "任何命令执行前都要确认"
        case .auto:     return "读写命令均自动执行（谨慎）"
        }
    }

    /// 进入「待确认」时是否自动批准全部工具调用。仅 `.auto` 为真；
    /// 其余档位保留人工确认（安全默认）。
    var autoApprovesPending: Bool { self == .auto }
}
