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
