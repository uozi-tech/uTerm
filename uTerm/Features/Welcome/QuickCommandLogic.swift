import Foundation

/// 快捷命令两端（macOS 欢迎页 / iOS 命令页）共用的纯逻辑：主机引用、目标解析、
/// 保存校验与运行文案。不依赖任何 UI 框架。

// MARK: - 主机引用（解耦 @Model，便于纯函数分组 / 单测）

/// 多选用的轻量主机值快照。从 `ServerProfile` 映射而来，`Sendable`、可在纯函数里分组。
nonisolated struct QuickCommandHostRef: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let group: String?
    let username: String
    let host: String
    let port: Int

    var endpoint: String { "\(username)@\(host):\(port)" }
}

// MARK: - 目标服务器解析（统一显示名 / 端点 / 已删除占位）

/// 把命令的 `serverIDs` 解析为展示信息。集中「名为空回退主机名」与「已删除服务器」占位，
/// 避免列表行 / 详情 / 执行器各写一份且行为不一致。`@MainActor`（读 @Model 属性）。
enum QuickCommandTargets {
    static let deletedLabel = String(localized: "已删除的主机")

    static func displayName(_ profile: ServerProfile) -> String {
        profile.name.isEmpty ? profile.host : profile.name
    }

    static func endpoint(_ profile: ServerProfile) -> String {
        "\(profile.username)@\(profile.host):\(profile.port)"
    }

    /// 一条解析结果（已删除的服务器 `endpoint == nil`、`exists == false`）。
    struct Resolved: Identifiable, Equatable {
        let id: UUID
        let name: String
        let endpoint: String?
        let exists: Bool
    }

    /// 按 `serverIDs` 顺序解析，未找到的服务器用占位名占位。
    static func resolve(_ serverIDs: [UUID], in hosts: [ServerProfile]) -> [Resolved] {
        serverIDs.map { id in
            if let host = hosts.first(where: { $0.id == id }) {
                return Resolved(id: id, name: displayName(host), endpoint: endpoint(host), exists: true)
            }
            return Resolved(id: id, name: deletedLabel, endpoint: nil, exists: false)
        }
    }

    /// 真正可以下发命令的目标主机：按 `serverIDs` 顺序、同一 id 只算一次，
    /// 剔除已删除的主机与「仅 SFTP」主机（它们禁命令执行）。两端的运行入口都走这里。
    static func runnable(_ serverIDs: [UUID], in hosts: [ServerProfile]) -> [ServerProfile] {
        var seen = Set<UUID>()
        return serverIDs.compactMap { id in
            guard seen.insert(id).inserted,
                  let host = hosts.first(where: { $0.id == id }),
                  !host.sftpOnly else { return nil }
            return host
        }
    }
}

// MARK: - 纯逻辑（可单测）

nonisolated enum QuickCommandLogic {
    static let ungroupedLabel = String(localized: "未分组")

    /// 按 `group` 分组（空 → 「未分组」），保持出现顺序。纯函数。
    static func grouped(_ refs: [QuickCommandHostRef]) -> [(group: String, hosts: [QuickCommandHostRef])] {
        var order: [String] = []
        var map: [String: [QuickCommandHostRef]] = [:]
        for ref in refs {
            let g = (ref.group?.isEmpty ?? true) ? ungroupedLabel : ref.group!
            if map[g] == nil { order.append(g) }
            map[g, default: []].append(ref)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    /// 某组的三态：`all`（整组都已选）/ `some`（部分已选，含全选）。
    static func groupState(_ groupHosts: [QuickCommandHostRef], selected: Set<UUID>) -> (all: Bool, some: Bool) {
        guard !groupHosts.isEmpty else { return (false, false) }
        let picked = groupHosts.filter { selected.contains($0.id) }.count
        return (picked == groupHosts.count, picked > 0)
    }

    /// 触发器摘要：0 台 → nil；1 台名称；2 台「A、B」；更多「A 等 N 台」。
    /// 按 `refs` 顺序取已选项。
    static func selectionSummary(_ refs: [QuickCommandHostRef], selected: Set<UUID>) -> String? {
        let chosen = refs.filter { selected.contains($0.id) }
        switch chosen.count {
        case 0: return nil
        case 1: return chosen[0].name
        case 2: return String(localized: "\(chosen[0].name)、\(chosen[1].name)", comment: "两台主机名并列")
        default: return String(localized: "\(chosen[0].name) 等 \(chosen.count) 台")
        }
    }

    /// 运行按钮文案（复刻原型 `QcDetail.runLabel`）：多台优先显示并行，单台按 AI 区分。
    static func runLabel(serverCount: Int, ai: Bool) -> String {
        if serverCount > 1 { return String(localized: "并行运行 · \(serverCount) 台") }
        return ai ? String(localized: "运行 · AI 介入") : String(localized: "运行命令")
    }

    /// AI 命令的「说人话」文案（复刻原型 `qcAiIntent`）：优先 `intent`（去空白），
    /// 缺失时由名称兜底成一句。列表行副标题 / 详情指令块共用，保证两处一致。
    static func aiIntentText(name: String, intent: String) -> String {
        let trimmed = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return String(localized: "执行「\(name)」：运行后让 AI 读取输出、自动诊断并续接下一步。")
    }

    /// AI 命令运行时交给 Agent 的预填文案：自然语言意图优先，其次等效命令，
    /// 两者皆空再兜底成一句——保证 Agent 输入框总有可读内容。
    static func agentPrefill(name: String, intent: String, command: String) -> String {
        let i = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !i.isEmpty { return i }
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { return c }
        return aiIntentText(name: name, intent: "")
    }

    /// 保存校验（复刻原型 `QcForm.valid`）：名称非空 + 至少一台服务器 +
    /// （AI 时 `intent` 或 `command` 至少有一；非 AI 时 `command` 必填）。纯函数、可单测。
    static func isSaveable(name: String, hasServers: Bool,
                           command: String, intent: String, ai: Bool) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, hasServers else { return false }
        let hasCommand = !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasIntent = !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ai ? (hasIntent || hasCommand) : hasCommand
    }
}
