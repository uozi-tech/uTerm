import Foundation

/// 一个终端标签页此刻的样子：构造实时活动内容的输入（由 `TerminalActivityCenter` 从工作区读出）。
nonisolated struct TerminalActivityEntry: Equatable, Sendable {
    let tabID: UUID
    let title: String
    let host: String
    /// 标签页上显示的程序状态（`TermTab.programStatus`，已去掉 `idle`）。
    let status: ProgramStatusRecord
}

/// 实时活动处在哪个阶段。
nonisolated enum TerminalActivityPhase: Equatable, Sendable {
    /// App 在跑，内容是实时的。
    case live
    /// 后台保持中（`BGContinuedProcessingTask`），到 `until` 结束。
    case keeping(until: Date)
    /// App 已经（或马上）被挂起，内容不再更新。
    case paused
}

/// 由各标签页的程序状态算出实时活动的内容。纯函数，测试直接调。
nonisolated enum TerminalActivityContent {
    typealias State = TerminalActivityAttributes.ContentState
    typealias Row = TerminalActivityAttributes.Row
    typealias Tone = TerminalActivityAttributes.Tone

    /// 展开的灵动岛放得下 3 行；锁屏也取 3 行，两处的「还有 N 个」才对得上。
    static let maxRows = 3

    /// 没有任何值得看的标签页时返回 nil（这时不该有实时活动）。
    /// `since`：各标签页进入当前状态的时刻（`TerminalActivitySinceBook`）。输入的顺序就是标签页顺序，同级时按它排。
    static func make(entries: [TerminalActivityEntry], since: [UUID: Date], phase: TerminalActivityPhase,
                     now: Date = Date()) -> State? {
        let ranked = entries.enumerated()
            .compactMap { index, entry -> (row: Row, rank: Int, index: Int)? in
                guard let tone = tone(of: entry.status) else { return nil }
                let row = Row(id: entry.tabID,
                              title: entry.title,
                              host: entry.host == entry.title ? nil : entry.host,
                              program: entry.status.appName,
                              status: entry.status.statusLabel,
                              shortStatus: shortStatus(of: entry.status),
                              tone: tone,
                              since: since[entry.tabID] ?? now)
                return (row, rank(of: tone), index)
            }
            .sorted { a, b in
                if a.rank != b.rank { return a.rank > b.rank }
                if a.row.since != b.row.since { return a.row.since > b.row.since }
                return a.index < b.index
            }
        guard !ranked.isEmpty else { return nil }
        let rows = ranked.prefix(maxRows).map(\.row)
        let overflow = ranked.count - rows.count
        let all = ranked.map(\.row)
        let hosts = entries.filter { tone(of: $0.status) != nil }
        return State(rows: Array(rows),
                     overflow: overflow,
                     overflowText: overflow > 0 ? String(localized: "还有 \(overflow) 个") : nil,
                     keepUntil: keepUntil(phase),
                     paused: phase == .paused,
                     footer: footer(phase),
                     pausedText: pausedText,
                     sharedProgram: shared(all.map(\.program)),
                     sharedStatus: shared(all.map(\.status)),
                     sharedHost: sharedHost(of: hosts))
    }

    /// 全都一样时取那个值。
    private static func shared(_ values: [String]) -> String? {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// 都在同一台主机上时取主机名；有一行的标题就是主机名时不提（标题行和那一行会写两遍同一个名字）。
    private static func sharedHost(of entries: [TerminalActivityEntry]) -> String? {
        guard let host = shared(entries.map(\.host)), !entries.contains(where: { $0.title == host }) else { return nil }
        return host
    }

    /// 把一份已经推出去的内容改成「已暂停」：App 要被挂起了，或者在后台时连接断了、算不出新内容。
    static func paused(_ state: State) -> State {
        var state = state
        state.paused = true
        state.keepUntil = nil
        state.footer = pausedText
        return state
    }

    /// 已暂停时的底行：主机上的程序多半还在跑（会话保持进程 / Mac），只是手机没在看。
    static var pausedText: String { String(localized: "已暂停，回到 uTerm 查看最新状态") }

    private static func footer(_ phase: TerminalActivityPhase) -> String? {
        switch phase {
        case .live: nil
        case .keeping: String(localized: "后台保持中，还剩")
        case .paused: pausedText
        }
    }

    private static func keepUntil(_ phase: TerminalActivityPhase) -> Date? {
        if case .keeping(let until) = phase { return until }
        return nil
    }

    static func tone(of status: ProgramStatusRecord) -> Tone? {
        switch status.tone {
        case .needsAttention: .attention
        case .working: .working
        case .done: .done
        case .failed: .failed
        case .idle: nil
        }
    }

    /// 排序：等人处理 > 出错 > 运行中 > 完成。
    private static func rank(of tone: Tone) -> Int {
        switch tone {
        case .attention: 3
        case .failed: 2
        case .working: 1
        case .done: 0
        }
    }

    /// 紧凑态右边那两三个字。
    static func shortStatus(of status: ProgramStatusRecord) -> String {
        switch status.state {
        case .blocked:
            switch status.kind {
            case .question: String(localized: "需回答")
            case .auth: String(localized: "需登录")
            case .permission, nil: String(localized: "需确认")
            }
        case .working: String(localized: "运行中")
        case .done: String(localized: "完成")
        case .error: String(localized: "出错")
        case .idle: String(localized: "空闲")
        }
    }
}

/// 各标签页进入当前状态的时刻（运行中的行据此计时）。状态（含卡住的原因）变了才重新起算。
nonisolated struct TerminalActivitySinceBook: Equatable, Sendable {
    private struct Mark: Equatable, Sendable {
        let state: ProgramState
        let kind: ProgramBlockKind?
        let since: Date
    }

    private var marks: [UUID: Mark] = [:]

    var since: [UUID: Date] { marks.mapValues(\.since) }

    /// 记下这一轮的状态；没有状态的标签页忘掉。
    mutating func update(_ entries: [TerminalActivityEntry], now: Date) {
        var next: [UUID: Mark] = [:]
        for entry in entries {
            if let mark = marks[entry.tabID], mark.state == entry.status.state, mark.kind == entry.status.kind {
                next[entry.tabID] = mark
            } else {
                next[entry.tabID] = Mark(state: entry.status.state, kind: entry.status.kind, since: now)
            }
        }
        marks = next
    }
}

/// 后台时哪些标签页刚变成值得提醒的状态（卡住等人、完成、出错）：只提醒「变成」的那一刻，同一状态不重复提醒。
nonisolated struct TerminalActivityTransitions: Equatable, Sendable {
    private var last: [UUID: ProgramState] = [:]
    private var lastPosted: [UUID: Date] = [:]

    /// 同一个标签页两次提醒至少隔这么久（程序来回切状态时不刷屏，同 Mac 的 `TerminalAttentionRateLimiter`）。
    static let minimumInterval: TimeInterval = 2

    /// 记下这一轮，返回该提醒的。`notify` 为 false（App 在前台）时只记不提醒：回到后台后不会把前台早就看过的状态补发一遍。
    mutating func update(_ entries: [TerminalActivityEntry], notify: Bool, now: Date) -> [TerminalActivityEntry] {
        var fresh: [TerminalActivityEntry] = []
        var next: [UUID: ProgramState] = [:]
        for entry in entries {
            let state = entry.status.state
            next[entry.tabID] = state
            guard notify, Self.isNoteworthy(state), last[entry.tabID] != state else { continue }
            if let posted = lastPosted[entry.tabID], now.timeIntervalSince(posted) < Self.minimumInterval { continue }
            lastPosted[entry.tabID] = now
            fresh.append(entry)
        }
        last = next
        lastPosted = lastPosted.filter { next[$0.key] != nil }
        return fresh
    }

    static func isNoteworthy(_ state: ProgramState) -> Bool {
        switch state {
        case .blocked, .done, .error: true
        case .working, .idle: false
        }
    }
}
