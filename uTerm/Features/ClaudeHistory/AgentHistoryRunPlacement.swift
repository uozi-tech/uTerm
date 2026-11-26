import Foundation

/// Code 标签页里跑着的会话（含已结束、留着画面的）在侧栏里放哪。两端共用（Mac 的 `CodeTabModel`、iOS 的 `CodeRunBoard`），
/// 界面只画。
///
/// 不另起一块「正在运行」：列表里有它那份记录的，就在那份记录平常的位置——置顶了在「置顶」，否则在它那一组——
/// 行上标它此刻的状态（`CodeRunStatus`）。状态变了不挪，组里照列表平常的先后排。
/// 列表里没有它那份记录的（还没对上记录的新会话；对上了但还没列出来、被「显示」筛掉、还没翻到；结束了也没有记录的）
/// 没有组可放，放在列表最顶上：一个都不丢，也不重复。
nonisolated struct AgentHistoryRunPlacement<Run> {
    /// 列表最顶上的那几个，按 `runs` 的先后。
    let top: [Run]
    /// 记录路径 → 在跑的那个会话：列表里那一行画成跑着的样子（状态、操作）。
    let inList: [String: Run]

    /// `listed`：列表里显示着的记录（各组里的，含「置顶」）。
    init(runs: [Run], path: (Run) -> String?, listed: Set<String>) {
        var top: [Run] = []
        var inList: [String: Run] = [:]
        for run in runs {
            // 同一份记录有两个会话（不该有）：第二个放到顶上，不丢。
            if let path = path(run), listed.contains(path), inList[path] == nil {
                inList[path] = run
            } else {
                top.append(run)
            }
        }
        self.top = top
        self.inList = inList
    }

    /// 按画出来的那几组（`AgentHistoryListing.groups`，含「置顶」）。
    init(runs: [Run], path: (Run) -> String?, groups: [AgentHistoryGroup]) {
        self.init(runs: runs, path: path, listed: Set(groups.flatMap { $0.files.map(\.path) }))
    }

    /// 在这一组里（那几行上）跑着的会话，按组里的先后：收起的组标题上那个点照它们画（`CodeRunGroupMark`）。
    func runs(in group: AgentHistoryGroup) -> [Run] {
        group.files.compactMap { inList[$0.path] }
    }
}

nonisolated extension AgentHistoryListing {
    /// 这份记录在哪一组（置顶了是「置顶」）。不在任何一组里为 nil。
    static func groupID(ofRecord path: String, in groups: [AgentHistoryGroup]) -> String? {
        groups.first { group in group.files.contains { $0.path == path } }?.id
    }
}
