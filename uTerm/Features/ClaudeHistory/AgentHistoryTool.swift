import Foundation

/// 哪一种编码工具留下的记录。每种工具一个数据源（`AgentHistorySource` 的一份实现），列表、对话、搜索的界面共用。
///
/// 加一种工具：这里加一个 case，写它的数据源，在建数据源的地方接上。原始值会进偏好设置（分组、只看哪几种），
/// **已有的原始值不改**。
nonisolated enum AgentHistoryTool: String, CaseIterable, Hashable, Sendable, Identifiable {
    /// Claude Code：`~/.claude/projects/<目录换出来的名字>/<会话 ID>.jsonl`。
    case claude
    /// Codex CLI：`~/.codex/sessions/<年>/<月>/<日>/rollout-<时间>-<ID>.jsonl`（可能是 zstd 压缩过的 `.jsonl.zst`）。
    case codex
    /// Cursor 的命令行（`cursor-agent`）：`~/.cursor/chats/<工作区的哈希>/<会话 ID>/store.db`（SQLite）。
    case cursor
    /// Antigravity：`~/.gemini/antigravity/brain/<会话 ID>/.system_generated/logs/transcript.jsonl`。
    case antigravity

    var id: String { rawValue }

    /// 产品名，不翻译。
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        }
    }
}
