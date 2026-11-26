import Foundation

/// 对话记录排成的一行（两端共用）：一条普通消息，或连续几次工具调用折成的一组（同 Claude Code Desktop）。
nonisolated enum AgentTranscriptEntry: Identifiable, Equatable, Sendable {
    case item(AgentTranscriptItem)
    /// 连续两次以上的工具调用。ID 取组里第一条的 ID：往前加了一页、这一组又并进了更早的调用时，
    /// 组的 ID 会变成更早那条的，所以找行一律经 `AgentTranscriptLayout.rowID(for:)`。
    case tools(id: String, items: [AgentTranscriptItem])

    var id: String {
        switch self {
        case .item(let item): return item.id
        case .tools(let id, _): return id
        }
    }

    var role: AgentTranscriptItem.Role {
        switch self {
        case .item(let item): return item.role
        case .tools: return .assistant
        }
    }

    /// 展开状态（`expanded` 集合里的键）。
    var groupKey: String { "\(id).group" }
}

nonisolated struct AgentTranscriptLayout: Equatable, Sendable {
    let rows: [AgentTranscriptEntry]
    /// 每一条消息落在哪一行（不在组里的就是它自己）。
    private let rowOfItem: [String: String]
    /// 换了说话的一方的那几行：上面多空一点。
    let runStarts: Set<String>

    /// - Parameter isGroupable: 这次工具调用能不能并进组。派出了子代理、找得到它记录的调用单独一行（入口要露在外面）。
    init(items: [AgentTranscriptItem], isGroupable: (AgentToolCall) -> Bool = { _ in true }) {
        var rows: [AgentTranscriptEntry] = []
        var rowOfItem: [String: String] = [:]
        var pending: [AgentTranscriptItem] = []

        func flush() {
            guard let first = pending.first else { return }
            if pending.count == 1 {
                rows.append(.item(first))
            } else {
                rows.append(.tools(id: first.id, items: pending))
            }
            for item in pending { rowOfItem[item.id] = first.id }
            pending.removeAll(keepingCapacity: true)
        }

        for item in items {
            let groupable: Bool
            switch item.kind {
            case .toolCall(let call): groupable = isGroupable(call)
            case .toolResult: groupable = true
            default: groupable = false
            }
            if groupable {
                pending.append(item)
            } else {
                flush()
                rows.append(.item(item))
                rowOfItem[item.id] = item.id
            }
        }
        flush()

        var starts: Set<String> = []
        var last: AgentTranscriptItem.Role?
        for row in rows {
            let role = row.role
            if role != .system, role != last { starts.insert(row.id) }
            last = role
        }

        self.rows = rows
        self.rowOfItem = rowOfItem
        self.runStarts = starts
    }

    /// 这条消息所在的那一行；不认识的 ID 原样返回。
    func rowID(for itemID: String) -> String { rowOfItem[itemID] ?? itemID }

    /// 这条消息在一个折起来的组里：返回那一组展开用的键。
    func groupKey(containing itemID: String) -> String? {
        let rowID = rowID(for: itemID)
        for case .tools(let id, _) in rows where id == rowID { return "\(id).group" }
        return nil
    }
}

/// 工具调用一行上的图标与组的摘要（两端共用）。名字按各家工具记录里的原样（Claude、Codex、Cursor……）。
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

    /// 组里出现过的工具名，按第一次出现的先后，去重。
    static func distinctNames(_ items: [AgentTranscriptItem]) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for item in items {
            guard case .toolCall(let call) = item.kind, seen.insert(call.name).inserted else { continue }
            names.append(call.name)
        }
        return names
    }

    /// 组里有没有出错的结果。
    static func hasError(_ items: [AgentTranscriptItem]) -> Bool {
        items.contains { item in
            switch item.kind {
            case .toolCall(let call): return call.result?.isError == true
            case .toolResult(let result): return result.isError
            default: return false
            }
        }
    }
}
