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

/// 单台「连接层失败」原因——命令根本没跑起来（区别于命令执行后非零退出）。
/// - `hostKeyUntrusted`：主机指纹未信任 / 已变更，并行路径无交互入口直接拒了连接 →
///   触发泳道内联「信任并重试」（携带与终端 / SFTP 征询同源的 `HostKeyChallenge`）。
/// - `connection`：其它连接 / 认证 / 超时失败，仅展示原因文案，无自动重试。
///
/// 不声明 `Equatable`：`HostKeyChallenge` 的 `Equatable` 遵从在本项目
///（`-default-isolation=MainActor` + `InferIsolatedConformances`）下被推断为 `@MainActor`
/// 隔离，无法用于本 `nonisolated` 枚举的合成 `==`；本类型也无处需要比较。
nonisolated enum ParallelLaneFailure: Sendable {
    case hostKeyUntrusted(HostKeyChallenge)
    case connection(String)
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

    /// 连接层失败原因（命令未能执行）。`hostKeyUntrusted` 触发泳道 / 窗格内联「信任并重试」。
    var failure: ParallelLaneFailure?

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
