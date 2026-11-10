import Foundation

/// 回到主线程做一件事（两端共用）：已经在主线程上就当场做——主线程上喂的字节（测试直接喂、`clearOutput`）要当场看到
/// 结果；否则排进主队列。主队列是 FIFO：同一条线程先后排进去的事（击键、终端应答、影子的事件）到主线程上也是这个先后，
/// 所以别换成 `Task { @MainActor in }`（不保证先后）。
nonisolated enum TerminalMainHop {
    static func run(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }
}

/// 影子终端的事件怎么处理，两端共用这一份：程序状态（OSC 7501 / OSC 133 A）进 `ProgramStatusTracker` 与记账副本、
/// 查询的应答、历史字节、远控镜像。平台那边只接出口：要不要提醒人（Mac 发系统通知、iOS 不发）、标题、通知、响铃、
/// 未知 OSC。
///
/// 规则：
/// - **记账副本**（`journal`，存进 holder 检查点）在喂字节的那条线程上、解析到那个序列时当场更新，历史字节也记：
///   它要和字节位置严格对应。界面那份 `tracker` 在主线程上，晚一点。
/// - **历史字节**（`ShadowTerminal.feed(_:asHistory:)`，重启后接回时 holder 留着的那段）：只把状态记进 `tracker`
///   （检查点之后、重启之前的变化就在这段里，一直 working 的程序接回后不会再报一次），不应答、不提醒、不交给平台。
/// - **远控镜像**（主控端，`isMirror`）：被控的那台 Mac 自己解析状态、回答查询、发通知，经远控协议推过来。这里再处理
///   一遍，应答就成了那边程序收到的多余输入、通知会在两台机器上各弹一次。所以状态、查询、提示符、通知一律不处理；
///   标题、响铃、未知 OSC 照常交给平台。
/// - 查询的应答用 uTerm 自己那条最短的（`ProgramStatusTracker.queryReply`，缺省即全部支持），不用引擎拟的那条。
@MainActor
final class TerminalEventRouter {
    private(set) var tracker = ProgramStatusTracker()
    /// 程序状态的记账副本，见类型注释。
    let journal = ProgramStatusJournal()

    /// 此刻是不是远控镜像的主控端（后端 `mirrorsRemoteGrid`）。
    var isMirror: () -> Bool = { false }
    /// 用户此刻正看着这条会话：结果不用再提醒。
    var isLooking: () -> Bool = { false }
    /// 发给程序的字节（7501 查询的应答），和键盘输入走同一条通道。
    var sendToProgram: (Data) -> Void = { _ in }
    /// 值得打断用户：程序卡住等人，或做完 / 出错了而用户没在看。
    var onAttention: (ProgramStatusRecord) -> Void = { _ in }
    /// 收到一条状态上报（处理之前）。
    var onReport: () -> Void = {}
    /// `tracker` 变了：平台把它发布到界面上。
    var onStatusChanged: () -> Void = {}
    /// 不归这里管的实时事件：标题、通知（镜像时不给）、响铃、未知 OSC。
    var onEvent: (ShadowTerminal.Event) -> Void = { _ in }

    /// 接到影子终端上（替换它原来的事件出口）。
    nonisolated func install(on shadow: ShadowTerminal) {
        shadow.setEventHandler { [weak self, journal] event, isHistory in
            journal.receive(event)
            TerminalMainHop.run { self?.route(event, isHistory: isHistory) }
        }
    }

    func route(_ event: ShadowTerminal.Event, isHistory: Bool) {
        if isHistory {
            switch event {
            case .programStatus(let message): _ = tracker.receive(message, isLooking: false)
            case .promptStarted: tracker.promptStarted()
            default: break
            }
            return
        }
        switch event {
        case .programStatus(let message):
            guard !isMirror() else { return }
            apply(message)
        case .programStatusQuery:
            guard !isMirror() else { return }
            apply(.query)
        case .promptStarted:
            guard !isMirror() else { return }
            tracker.promptStarted()
            onStatusChanged()
        case .notification:
            guard !isMirror() else { return }
            onEvent(event)
        case .titleChanged, .bell, .unknownOSC:
            onEvent(event)
        }
    }

    /// 一条状态消息（`isLooking` 不给就问 `isLooking()`）。
    func apply(_ message: ProgramStatusMessage, isLooking looking: Bool? = nil) {
        if case .report = message { onReport() }
        let looking = looking ?? isLooking()
        switch tracker.receive(message, isLooking: looking) {
        case .none: break
        case .reply: sendToProgram(Data(ProgramStatusTracker.queryReply))
        case .attention(let record): onAttention(record)
        }
        // 用户正看着：结果当场算看过了，记账副本同步。
        if looking, case .report = message { journal.acknowledgeResults() }
        onStatusChanged()
    }

    /// 用户看到结果了：`done` / `error` 不再上标签。
    func acknowledgeResults() {
        tracker.acknowledgeResults()
        journal.acknowledgeResults()
        onStatusChanged()
    }

    /// 连接没了，上面跑的程序也不再有状态可言。
    func reset() {
        tracker.reset()
        journal.current = ProgramStatusTracker()
        onStatusChanged()
    }

    /// 接回时从检查点还原（不发布：接回完由调用方统一发布）。
    func restore(_ status: ProgramStatusTracker) {
        tracker = status
        journal.current = status
    }

    /// 接回时问到前台在跑 `name`，而检查点里没有状态（见 `ProgramStatusTracker.presumedProgram`）。
    func presumeRunningProgram(_ name: String) {
        tracker.presumeRunningProgram(name)
        journal.presumeRunningProgram(name)
    }
}
