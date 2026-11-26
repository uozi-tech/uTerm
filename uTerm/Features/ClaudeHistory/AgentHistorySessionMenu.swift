import Foundation

/// 历史会话列表里一行的菜单（Mac 右键、iOS 长按）有哪几项、按什么顺序。两端同一份。
///
/// 顺序同 Claude Code Desktop：继续、置顶、重命名、拷贝会话名、拷贝会话 ID，隔一条线是删除。
/// 在 Code 标签页里跑着的那一行没有「继续」「拷贝会话 ID」「删除」，最后是「结束会话」（Mac 上另有「查看记录」
/// 「移到新标签页」，见 `AgentHistoryRunRowActions`）：跑着的会话不能删，它的记录还在往下写。
nonisolated enum AgentHistorySessionMenuItem: Hashable, Sendable {
    case resume
    case pin(isPinned: Bool)
    /// 改会话的名字（写回记录，见 `AgentHistorySource.rename`）。
    case rename
    /// 拷贝列表上显示的名字。
    case copyTitle
    case copySessionID
    /// 删掉主机上的记录（先确认）。
    case delete
    case endSession

    /// 后面要隔一条线的（删除、结束会话这种收不回来的放在最后，和上面隔开）。
    var isDestructive: Bool { self == .delete || self == .endSession }

    /// `hasRecord`：这一行有记录（列表最顶上还没对上记录的新会话没有）。
    static func items(hasRecord: Bool, canResume: Bool, canPin: Bool, isPinned: Bool, isRunning: Bool,
                      canDelete: Bool, canRename: Bool = false) -> [Self] {
        var items: [Self] = []
        if hasRecord, canResume, !isRunning { items.append(.resume) }
        if hasRecord, canPin { items.append(.pin(isPinned: isPinned)) }
        if hasRecord, canRename { items.append(.rename) }
        if hasRecord { items.append(.copyTitle) }
        if hasRecord, !isRunning { items.append(.copySessionID) }
        if isRunning {
            items.append(.endSession)
        } else if hasRecord, canDelete {
            items.append(.delete)
        }
        return items
    }
}
