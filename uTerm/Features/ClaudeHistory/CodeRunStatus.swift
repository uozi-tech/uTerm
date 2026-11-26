import Foundation

/// Code 标签页侧栏里一个跑着的会话此刻的状态，两端共用一条规则（行上怎么标见 `AgentHistoryRunIndicator`）：
///
/// - 程序退出了：已结束（优先）。
/// - 程序经 OSC 7501 报过状态：照报的（运行中、等待确认、已完成、出错、空闲）。
/// - 没报过（刚起来、还没说第一句话的 Claude Code；接回时检查点里没有状态的；不报状态的工具）：不当成「运行中」，
///   没报过的会话多半正停在输入框等人。
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

/// 侧栏一行上跑着的会话怎么标（同 Claude Code Desktop）：只有等人处理（等确认、等回答、要登录）时右端一个黄点；
/// 运行中是名字一明一暗（`AgentHistoryRowTitle`），不画点；出错是一个警示图标；空闲、已完成、已结束、没报过状态的
/// 什么都不画——侧栏只在要人动手时提醒，其余时候安静。两端共用这一条规则，界面只画。
nonisolated enum AgentHistoryRunIndicator: Equatable, Sendable {
    case none
    case working
    case needsInput(ProgramStatusRecord)
    case error(ProgramStatusRecord)

    init(_ status: CodeRunStatus) {
        guard case .program(let record) = status else {
            self = .none
            return
        }
        switch record.state {
        case .working: self = .working
        case .blocked: self = .needsInput(record)
        case .error: self = .error(record)
        case .idle, .done: self = .none
        }
    }

    /// 读屏念的那几个字；不标的为 nil。
    nonisolated var label: String? {
        switch self {
        case .none: nil
        case .working: String(localized: "运行中")
        case .needsInput(let record), .error(let record): record.statusLabel
        }
    }
}

extension CodeRunGroupMark {
    /// 收起的组标题上那个黄点照哪个会话（同一行上的规则：只有等人处理的才画）；没人等为 nil（不画点）。
    nonisolated var waitingRecord: ProgramStatusRecord? {
        if case .program(let record) = status, record.state == .blocked { return record }
        return nil
    }
}
