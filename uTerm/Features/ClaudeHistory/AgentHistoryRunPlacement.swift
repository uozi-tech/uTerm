import Foundation

/// Code 标签页里跑着的会话（含已结束、留着画面的）在侧栏里放哪。两端共用（Mac 的 `CodeTabModel`、iOS 的 `CodeRunBoard`），
/// 界面只画。
///
/// 不另起一块「正在运行」：列表里有它那份记录的，就在那份记录平常的位置——置顶了在「置顶」，否则在它那一组——
/// 行上标它此刻的状态（`AgentHistoryRunIndicator`）。跑着的会话排在组的最前面、它那一组排在前面
/// （`AgentHistoryListing.prioritizingRuns`）；状态变了不挪。
/// 列表里没有它那份记录的（还没对上记录的新会话；对上了但还没列出来、被「显示」筛掉、还没翻到；结束了也没有记录的）：
/// 知道它该在哪一组的（按它的目录、工具，见 `AgentHistoryListing.groupID(forRunIn:tool:in:)`）放在那一组的最上面，
/// 对上记录之后就是组里它那一行；哪一组都对不上的（在一个列表里还没有的目录里开的）放在列表最顶上。一个都不丢，也不重复。
nonisolated struct AgentHistoryRunPlacement<Run> {
    /// 列表最顶上的那几个，按 `runs` 的先后。
    let top: [Run]
    /// 组 ID → 放在那一组最上面的几个（列表里没有它们的记录行），按 `runs` 的先后。
    let leading: [String: [Run]]
    /// 记录路径 → 在跑的那个会话：列表里那一行画成跑着的样子（状态、操作）。
    let inList: [String: Run]

    /// `listed`：列表里显示着的记录（各组里的，含「置顶」）。`home`：列表里没有记录行的会话放进哪一组（组 ID），
    /// nil = 放在最顶上。
    init(runs: [Run], path: (Run) -> String?, listed: Set<String>, home: (Run) -> String? = { _ in nil }) {
        var top: [Run] = []
        var leading: [String: [Run]] = [:]
        var inList: [String: Run] = [:]
        for run in runs {
            // 同一份记录有两个会话（不该有）：第二个当成没有记录行的，不丢。
            if let path = path(run), listed.contains(path), inList[path] == nil {
                inList[path] = run
            } else if let group = home(run) {
                leading[group, default: []].append(run)
            } else {
                top.append(run)
            }
        }
        self.top = top
        self.leading = leading
        self.inList = inList
    }

    /// 按画出来的那几组（`AgentHistoryListing.groups`，含「置顶」）。列表里没有记录行的会话按 `directory`、`tool`
    /// 放进它该在的那一组（`AgentHistoryListing.groupID(forRunIn:tool:in:)`）。
    init(runs: [Run], path: (Run) -> String?, directory: (Run) -> String, tool: (Run) -> AgentHistoryTool,
         groups: [AgentHistoryGroup]) {
        self.init(runs: runs, path: path, listed: Set(groups.flatMap { $0.files.map(\.path) }), home: { run in
            AgentHistoryListing.groupID(forRunIn: directory(run), tool: tool(run), in: groups)
        })
    }

    /// 放在这一组最上面的那几个（列表里没有它们的记录行）。
    func leading(in group: AgentHistoryGroup) -> [Run] { leading[group.id] ?? [] }

    /// 在这一组里跑着的会话（最上面那几个，再按组里的先后）：收起的组标题上那个点照它们画（`CodeRunGroupMark`）。
    func runs(in group: AgentHistoryGroup) -> [Run] {
        leading(in: group) + group.files.compactMap { inList[$0.path] }
    }

    /// 这个会话（列表里没有它的记录行时）放在哪一组；在最顶上或者有记录行为 nil。
    func groupID(ofLeading match: (Run) -> Bool) -> String? {
        leading.first { $0.value.contains(where: match) }?.key
    }
}

nonisolated extension AgentHistoryListing {
    /// 运行中的会话始终排在前面（用户要的）：每一组里有它记录行的那几个挪到组的最前面（彼此照原来的先后），
    /// 有跑着的会话的组（含只放着还没对上记录的新会话的）排在没有的前面，其余照原来的先后。
    /// 「置顶」一组照旧在最上面，组里是用户自己排的顺序，不挪。组的 ID 不变，`placement` 照样能用。
    static func prioritizingRuns<Run>(_ groups: [AgentHistoryGroup],
                                      placement: AgentHistoryRunPlacement<Run>) -> [AgentHistoryGroup] {
        var withRuns: [AgentHistoryGroup] = []
        var rest: [AgentHistoryGroup] = []
        var pinned: [AgentHistoryGroup] = []
        for var group in groups {
            if group.kind == .pinned {
                pinned.append(group)
                continue
            }
            let running = group.files.filter { placement.inList[$0.path] != nil }
            if !running.isEmpty {
                group.files = running + group.files.filter { placement.inList[$0.path] == nil }
            }
            if !running.isEmpty || !placement.leading(in: group).isEmpty {
                withRuns.append(group)
            } else {
                rest.append(group)
            }
        }
        return pinned + withRuns + rest
    }

    /// 这份记录在哪一组（置顶了是「置顶」）。不在任何一组里为 nil。
    static func groupID(ofRecord path: String, in groups: [AgentHistoryGroup]) -> String? {
        groups.first { group in group.files.contains { $0.path == path } }?.id
    }

    /// 一个跑着、但列表里还没有它记录行的会话（多半是刚开的新会话）该在哪一组：
    /// 按项目分组时是它的目录那一组（目录一模一样；Claude Code 没对上真实目录的那种组按目录名换算对，只认 Claude Code）；
    /// 按日期是「今天」；按工具是它的工具那一组；不分组就是那一组。不进「置顶」，也不进上级目录那一组（记录写出来后
    /// Claude Code 会给这个目录单独起一个项目，行会从上级那一组跳走）。对不上为 nil（放在列表最顶上）。
    static func groupID(forRunIn directory: String, tool: AgentHistoryTool, in groups: [AgentHistoryGroup]) -> String? {
        let normalized = ClaudeProjectPath.normalized(directory) ?? directory
        let encoded = ClaudeProjectPath.encode(normalized)
        return groups.first { group in
            switch group.kind {
            case .project(let known?, _): return known == normalized
            case .project(nil, let name): return tool == .claude && group.files.contains { $0.tool == .claude } && name == encoded
            case .date(let bucket): return bucket == .today
            case .tool(let mine): return mine == tool
            case .all: return true
            case .noDirectory, .pinned: return false
            }
        }?.id
    }
}
