import Foundation

/// 只读命令（AgentKit 的确定性判定）在两个自动档位下都直接运行；
/// 其余操作在「AI 代批」下仍受硬性规则和独立 AI 审查约束，敏感或不确定的交给用户。
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
        case .auto:     return "AI 代批"
        }
    }

    /// 拨盘项的副说明。
    var detail: String {
        switch self {
        case .readAuto: return "只读命令直接运行，其余操作人工确认"
        case .confirm:  return "任何命令执行前都要确认"
        case .auto:     return "只读命令直接运行，其余由 AI 代批，敏感或不确定的人工确认"
        }
    }

}
