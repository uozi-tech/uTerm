import Foundation

/// 连续两次以上的工具调用，折成一行（同 Claude Code Desktop）。
nonisolated struct AgentToolGroup: Equatable, Sendable {
    let items: [AgentTranscriptItem]
    /// 组里出现过的工具名，按第一次出现的先后，去重。
    let names: [String]
    /// 组里有出错的结果。
    let hasError: Bool

    init(items: [AgentTranscriptItem]) {
        self.items = items
        var seen: Set<String> = []
        var names: [String] = []
        var hasError = false
        for item in items {
            switch item.kind {
            case .toolCall(let call):
                if seen.insert(call.name).inserted { names.append(call.name) }
                if call.result?.isError == true { hasError = true }
            case .toolResult(let result):
                if result.isError { hasError = true }
            default:
                break
            }
        }
        self.names = names
        self.hasError = hasError
    }

    /// 取组里第一条的 ID：往前加了一页、这一组又并进了更早的调用时，组的 ID 会变成更早那条的，
    /// 所以找行一律经 `AgentTranscriptLayout.rowID(for:)`。
    var id: String { items[0].id }

    /// 展开状态（`expanded` 集合里的键）。
    var expansionKey: String { "\(id).group" }
}

/// 对话记录排成的一行（两端共用）：一条普通消息，或连续几次工具调用折成的一组。
nonisolated enum AgentTranscriptEntry: Equatable, Sendable {
    case item(AgentTranscriptItem)
    case tools(AgentToolGroup)

    var id: String {
        switch self {
        case .item(let item): return item.id
        case .tools(let group): return group.id
        }
    }

    fileprivate var role: AgentTranscriptItem.Role {
        switch self {
        case .item(let item): return item.role
        case .tools: return .assistant
        }
    }

    fileprivate func contains(_ itemID: String) -> Bool {
        switch self {
        case .item(let item): return item.id == itemID
        case .tools(let group): return group.items.contains { $0.id == itemID }
        }
    }
}

nonisolated struct AgentTranscriptLayout: Sendable {
    nonisolated struct Row: Identifiable, Equatable, Sendable {
        let entry: AgentTranscriptEntry
        /// 换了说话的一方。
        let startsRun: Bool
        /// 上面多空一截：换了说话的一方，且不是第一行（代替原来的「你」/「Claude」标签）。
        let hasGapAbove: Bool

        var id: String { entry.id }
    }

    let rows: [Row]

    /// - Parameter isGroupable: 这次工具调用能不能并进组。派出了子代理、找得到它记录的调用单独一行（入口要露在外面）。
    init(items: [AgentTranscriptItem], isGroupable: (AgentToolCall) -> Bool = { _ in true }) {
        var entries: [AgentTranscriptEntry] = []
        var pending: [AgentTranscriptItem] = []

        func flush() {
            if pending.count == 1 {
                entries.append(.item(pending[0]))
            } else if pending.count > 1 {
                entries.append(.tools(AgentToolGroup(items: pending)))
            }
            pending.removeAll(keepingCapacity: true)
        }

        for item in items where item.isDisplayed {
            switch item.kind {
            case .toolCall(let call) where isGroupable(call):
                pending.append(item)
            case .toolResult:
                pending.append(item)
            default:
                flush()
                entries.append(.item(item))
            }
        }
        flush()

        var rows: [Row] = []
        rows.reserveCapacity(entries.count)
        var last: AgentTranscriptItem.Role?
        for entry in entries {
            let role = entry.role
            let starts = role != .system && role != last
            rows.append(Row(entry: entry, startsRun: starts, hasGapAbove: starts && !rows.isEmpty))
            last = role
        }
        self.rows = rows
    }

    /// 这条消息所在的那一行；不认识的 ID 原样返回。只在往前加页、搜索命中时用，现找即可。
    func rowID(for itemID: String) -> String {
        rows.first { $0.entry.contains(itemID) }?.id ?? itemID
    }

    /// 末尾整段排（不进懒栈）的那一段从第几行起，见 `AgentTranscriptMessages`。`itemID` 是打开时读进来的那一页的第一条
    /// （`AgentTranscriptModel.tailStartID`），从它所在的那一行起；nil、找不到就是全部。这一段最多 `limit` 行：
    /// 实时跟随接了很久之后，前面的行退回懒栈。
    func eagerTailStart(from itemID: String?, limit: Int = AgentTranscriptLimits.eagerTailRows) -> Int {
        let start = itemID.flatMap { id in rows.firstIndex { $0.entry.contains(id) } } ?? 0
        return max(start, rows.count - max(0, limit))
    }

    /// 要露出这条消息：它在折起来的组里就把那一组展开。返回要滚到的那一行。
    func reveal(_ itemID: String, expanding expanded: inout Set<String>) -> String {
        guard let row = rows.first(where: { $0.entry.contains(itemID) }) else { return itemID }
        if case .tools(let group) = row.entry { expanded.insert(group.expansionKey) }
        return row.id
    }
}

/// 工具调用一行上的图标（两端共用）。名字按各家工具记录里的原样（Claude、Codex、Antigravity……）。
nonisolated enum AgentToolSymbol {
    static func systemImage(for name: String) -> String {
        switch name.lowercased() {
        case "bash", "shell", "exec_command", "local_shell", "bashoutput", "killshell", "run_terminal_cmd":
            return "terminal"
        case "read", "readtodos", "view_file", "read_file", "notebookread":
            return "doc.text"
        case "edit", "write", "multiedit", "notebookedit", "apply_patch", "write_file", "edit_file", "delete":
            return "pencil"
        case "grep", "glob", "search", "ls", "list_dir", "codebase_search", "grep_search", "file_search":
            return "magnifyingglass"
        case "webfetch", "websearch", "web_search", "fetch":
            return "globe"
        case "agent", "task":
            return "person.2"
        case "todowrite", "update_plan":
            return "checklist"
        default:
            return name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}
