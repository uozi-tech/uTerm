import Foundation

/// 一条终端会话的程序状态：收 OSC 7501（状态报告）与 OSC 133 A（新提示符）后怎么改状态、要不要回答、
/// 要不要提醒人。消息来自影子终端的事件（`ShadowTerminal.Event.programStatus` / `.promptStarted`）。两端共用：Mac 的 `TerminalSession` 与 iOS 的 `MobileTerminalController` 各持一份，
/// 只有「此刻有没有人在看」「怎么提醒」由各自平台决定。
nonisolated struct ProgramStatusTracker: Equatable, Sendable, Codable {
    private(set) var board = ProgramStatusBoard()

    /// 收到一条消息后调用方要做的事。
    enum Effect: Equatable, Sendable {
        case none
        /// 回答查询：把 `ProgramStatusTracker.queryReply` 写回 pty。
        case reply
        /// 值得打断用户：程序卡住等人，或做完 / 出错了而用户没在看。
        case attention(ProgramStatusRecord)
    }

    /// 查询的应答。不写 states / kinds：规格规定缺省即全部支持。
    static let queryReply = Array("\u{1b}]7501;?\u{1b}\\".utf8)

    init() {}

    /// 标签上显示的状态：最需要人处理的那条。`idle` 不显示：没有需要告诉用户的事。
    var display: ProgramStatusRecord? {
        let summary = board.summary
        return summary?.state == .idle ? nil : summary
    }

    /// 还有记录（含 `idle`）：有程序在用这套协议，说明前台不是 shell。
    var hasRecords: Bool { board.summary != nil }

    /// `isLooking`：用户此刻正看着这条会话，结果不用再提示。
    mutating func receive(_ message: ProgramStatusMessage, isLooking: Bool) -> Effect {
        switch message {
        case .query:
            return .reply
        case .clear(let id):
            board.clear(id: id)
            return .none
        case .report(let id, let record):
            let needsAttention = board.apply(id: id, record: record)
            if isLooking {
                board.acknowledgeResults()
                return .none
            }
            return needsAttention ? .attention(record) : .none
        }
    }

    /// 新 shell 提示符出现：上一个程序已经结束。
    mutating func promptStarted() {
        board.programEnded()
    }

    /// 用户看到结果了。
    mutating func acknowledgeResults() {
        board.acknowledgeResults()
    }

    /// 连接没了，上面跑的程序也不再有状态可言。
    mutating func reset() {
        board.clear(id: nil)
    }
}

// MARK: - 文案与外观（两端共用，颜色由各端按 `tone` 取）

/// 标签圆点的语义。两端各自按它取颜色（Mac 取 `UD`，iOS 取 `M`），含义保持一致。
nonisolated enum ProgramStatusTone: Equatable, Sendable {
    /// 卡住等人：确认、回答、登录。
    case needsAttention
    case working
    case done
    case failed
    case idle
}

extension ProgramStatusRecord {
    /// 程序名。规格里 `app` 是稳定标识符，这两个常见的换成用户认识的名字。
    nonisolated var appName: String {
        switch app {
        case "claude-code": "Claude Code"
        case "codex": "Codex"
        case let app?: app
        case nil: title ?? String(localized: "终端程序")
        }
    }

    nonisolated var statusLabel: String {
        switch state {
        case .blocked:
            switch kind {
            case .permission: String(localized: "等待确认")
            case .question: String(localized: "等待回答")
            case .auth: String(localized: "需要登录")
            case nil: String(localized: "等待处理")
            }
        case .working: String(localized: "运行中")
        case .done: String(localized: "已完成")
        case .error: String(localized: "出错")
        case .idle: String(localized: "空闲")
        }
    }

    /// 「Claude Code · 等待确认」，有消息时另起一行。
    nonisolated var tabHelp: String {
        let headline = "\(appName) · \(statusLabel)"
        return message.map { "\(headline)\n\($0)" } ?? headline
    }

    nonisolated var tone: ProgramStatusTone {
        switch state {
        case .blocked: .needsAttention
        case .working: .working
        case .done: .done
        case .error: .failed
        case .idle: .idle
        }
    }
}

/// 程序状态的记账副本，给检查点用（两端共用）。在影子终端的事件回调里——喂字节的那条线程上、解析到那个序列时——
/// 同步更新，所以它和字节流的位置严格对应：拍检查点的那一刻（泵的锁在手上）读它，正好是「到这个字节为止」的状态。
/// 界面用的那份 `ProgramStatusTracker` 在主线程上，事件要排队才到，会晚一点。
///
/// 为什么要存：程序跨重启一直在 `working` 时不会再报一次，接回之后标签上的状态只能从检查点里来。
nonisolated final class ProgramStatusJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = ProgramStatusTracker()

    /// 影子终端的事件：只认状态上报与新提示符。
    func receive(_ event: ShadowTerminal.Event) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .programStatus(let message): _ = tracker.receive(message, isLooking: false)
        case .promptStarted: tracker.promptStarted()
        default: break
        }
    }

    /// 用户看过结果了。
    func acknowledgeResults() {
        lock.withLock { tracker.acknowledgeResults() }
    }

    var current: ProgramStatusTracker {
        get { lock.withLock { tracker } }
        set { lock.withLock { tracker = newValue } }
    }

    /// 存进检查点的样子。
    var encoded: Data? { try? JSONEncoder().encode(current) }

    static func decode(_ data: Data) -> ProgramStatusTracker? {
        try? JSONDecoder().decode(ProgramStatusTracker.self, from: data)
    }
}
