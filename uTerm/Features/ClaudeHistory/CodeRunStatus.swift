import Foundation

/// Code 标签页侧栏里一个跑着的会话此刻的状态（两端共用一条规则；Mac 画成 `AgentHistoryRunStatusTag`，iOS 画成
/// `CodeRunStatusMark`）：
///
/// - 程序退出了：「已结束」（优先）。
/// - 程序经 OSC 7501 报过状态：照报的写，圆点颜色与文字同终端标签（运行中、等待确认、已完成、出错）。
///   「空闲」也写：做完一轮、停在输入框等人的 Claude Code 报的就是它。终端标签上空闲不画圆点（没什么要告诉用户的），
///   侧栏这一行不一样——它就是用来看每个会话在干什么的。
/// - 没报过（刚起来、还没说第一句话的 Claude Code；接回时检查点里没有状态的；不报状态的工具）：不写状态，
///   只有那一行平常的副标题。不能写成「运行中」：那是程序报来的「正在干活」，没报过的会话多半正停在输入框等人。
nonisolated enum CodeRunStatus: Equatable, Sendable {
    case unreported
    case ended
    case program(ProgramStatusRecord)

    /// `report`：程序报的状态里最需要人处理的那条，含空闲（`TerminalSession.programReport`，不是只给标签用、
    /// 空闲时为 nil 的 `programStatus`）。
    static func of(isEnded: Bool, report: ProgramStatusRecord?) -> CodeRunStatus {
        if isEnded { return .ended }
        return report.map { .program($0) } ?? .unreported
    }
}

/// 收起的组标题上那个点：组里有在 Code 标签页里跑着的会话时（已结束的不算），收起来也看得出来。两端共用一条规则，
/// 界面只画（Mac `AgentHistoryGroupHeader`、iOS `ClaudeHistoryGroupHeader`）。
///
/// 圆点照最需要人处理的那个会话（同一条会话有多条记录时标签取哪条，`ProgramState.priority`）：等人 > 出错 > 运行中 >
/// 已完成 > 空闲；都没报过状态的是灰点。
nonisolated struct CodeRunGroupMark: Equatable, Sendable {
    /// 还在跑的会话有几个。
    let running: Int
    /// 圆点照哪个会话的状态：`.program`（报过的里最要紧的那个）或 `.unreported`（一个都没报过），不会是 `.ended`。
    let status: CodeRunStatus

    /// `statuses`：组里各个跑着的会话的状态。一个还在跑的都没有为 nil（不画点）。
    init?(_ statuses: [CodeRunStatus]) {
        var running = 0
        var urgent: ProgramStatusRecord?
        for status in statuses {
            switch status {
            case .ended:
                continue
            case .unreported:
                running += 1
            case .program(let record):
                running += 1
                if urgent.map({ record.state.priority > $0.state.priority }) ?? true { urgent = record }
            }
        }
        guard running > 0 else { return nil }
        self.running = running
        self.status = urgent.map { .program($0) } ?? .unreported
    }
}
