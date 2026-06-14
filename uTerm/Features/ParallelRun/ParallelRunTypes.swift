import Foundation

/// 并行执行窗口的视图模式（标题栏 Shell | AI 分段切换）。
nonisolated enum ParallelViewMode: String, Hashable, Sendable, CaseIterable {
    case shell
    case ai
}

/// Shell 视图单台运行状态。
nonisolated enum ParallelRunStatus: Sendable, Equatable {
    case running
    case succeeded
    case failed
}

/// AI 视图单台泳道语气：
/// - `running` 执行/诊断中；`ok` 正常；`healed` 出错后已自动修复；`failed` 仍失败/需人工。
nonisolated enum ParallelLaneTone: Sendable, Equatable {
    case running
    case ok
    case healed
    case failed
}

/// Shell 视图里的一行输出。渲染：`cmd`→强调色 `$`、`ok`→绿 `✓`、`err`→红 `✕`、`out`→普通。
nonisolated struct ParallelTermLine: Identifiable, Sendable, Equatable {
    nonisolated enum Kind: Sendable, Equatable { case cmd, out, ok, err }
    let id: UUID
    let kind: Kind
    let text: String

    init(kind: Kind, text: String, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// 单台服务器在并行执行窗口里的统一状态——Shell 与 AI 两视图共用同一次真实执行，
/// 各取所需字段渲染（不重复跑命令）。`@MainActor` 模型持有并增量更新。
@MainActor
struct ParallelServerState: Identifiable {
    let id: UUID            // serverID
    let name: String
    let endpoint: String    // user@host:port（落库 / 提示词用）
    let endpointDisplay: String   // user@host（窄 header 展示用，对齐原型不带端口）

    // Shell 视图
    var status: ParallelRunStatus = .running
    var exitCode: Int?
    var durationMs: Int?
    var lines: [ParallelTermLine] = []

    // AI 视图
    var tone: ParallelLaneTone = .running
    /// 失败后、修复落定前的「诊断中…」过渡态。
    var diagnosing: Bool = false
    var summary: String = ""
    var steps: [String] = []

    /// AI 泳道右侧状态徽标文案。
    var laneStatusText: String {
        switch tone {
        case .running: return diagnosing ? "诊断中…" : "执行中…"
        case .ok:      return "正常"
        case .healed:  return "已自愈"
        case .failed:  return "需处理"
        }
    }
}
