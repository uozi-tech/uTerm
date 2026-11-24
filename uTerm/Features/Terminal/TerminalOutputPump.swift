import Foundation
import GhosttyTerminal
import os

/// 后端输出里的一项：原样字节，或者一张整屏的二进制快照（远控镜像：被控的 Mac 在接入、改尺寸、积压过多时发；
/// 接回留在主机上的会话时还原检查点）。
nonisolated enum TerminalOutputItem: Sendable {
    case bytes(Data)
    /// `ShadowTerminal.snapshot()` 的产物，本机引擎解得开（远控收到的回放流已在 `RemoteTerminalReplay.restorable` 里重画成本机格式）。
    case snapshot(Data)
    /// 过去的输出（接回留在主机上的会话时，客户端不在期间的那段）。照常解析进影子和画面，但里面的查询当时已经
    /// 没人答或者答过了：不应答、不写剪贴板、不发通知（`ShadowTerminal.feed(_:asHistory:)`），否则回答会打进
    /// 现在正在跑的程序的输入。程序状态照收。
    case history(Data)
    /// 同步点：排在它前面的输出都进了影子之后调一次，拿着泵的锁（同 `performWhileFeedingPaused`）。
    /// 后端用它在字节流上一个自己知道的位置拍检查点；别在里面做重活，也别反过来调泵的 `start` / `reset`。
    case afterFed(@Sendable () -> Void)
}

/// 画面那一侧要的接口（`InMemoryTerminalSession`）。单独成协议是为了单测能换成假的。
nonisolated protocol TerminalSurfaceSink: AnyObject, Sendable {
    func receive(_ data: Data)
    func receiveReplay(_ data: Data)
    @discardableResult func discardPendingOutput() -> Int
    func setOutputBacklogHandler(highWater: Int, lowWater: Int, _ handler: (@Sendable (_ isBacklogged: Bool) -> Void)?)
    /// surface 的终端在用的网格（IO 线程上报过的那个，不是主线程刚设下、终端还没改过去的尺寸）；没有时 nil。
    /// 只在 `followsSnapshotGrid` 时读。
    var surfaceGridSize: (cols: Int, rows: Int)? { get }
    /// 丢掉排着、还没交给 surface 解析的输出（同 `discardPendingOutput`），全是实时字节时按先后交回来。
    /// 泵停喂 surface 时用它：恢复时把交回的字节连同停喂期间的输出补给 surface，不必整屏回放（见 `setSurfaceFeeding`）。
    func takePendingOutputForCatchUp() -> TerminalPendingWrites
    /// 在这之前交给 surface 的东西都解析完之后调 `body`（任意线程）。
    func afterPendingOutput(_ body: @escaping @Sendable () -> Void)
}

/// `TerminalSurfaceSink.takePendingOutputForCatchUp()` 的结果。
nonisolated struct TerminalPendingWrites: Sendable {
    /// 丢掉的实时字节，按先后拼好。
    var bytes: Data
    /// 丢掉的就是这些（没有夹着回放、队列里也没留着会排到它们前面的东西）：可以原样补给 surface。
    var complete: Bool
    /// 一共丢了多少字节（含交不回来的）。
    var droppedBytes: Int
}

extension TerminalSurfaceSink {
    nonisolated var surfaceGridSize: (cols: Int, rows: Int)? { nil }

    /// 默认：交不回来（只会整屏回放）。
    nonisolated func takePendingOutputForCatchUp() -> TerminalPendingWrites {
        let dropped = discardPendingOutput()
        return TerminalPendingWrites(bytes: Data(), complete: dropped == 0, droppedBytes: dropped)
    }

    nonisolated func afterPendingOutput(_ body: @escaping @Sendable () -> Void) { body() }
}

extension InMemoryTerminalSession: TerminalSurfaceSink {
    nonisolated var surfaceGridSize: (cols: Int, rows: Int)? {
        reportedGrid.map { (Int($0.columns), Int($0.rows)) }
    }

    nonisolated func takePendingOutputForCatchUp() -> TerminalPendingWrites {
        let taken = takePendingWrites()
        return TerminalPendingWrites(bytes: taken.data, complete: taken.complete, droppedBytes: taken.dropped)
    }
}

/// 后端输出 → 影子终端 + 画面的泵。mac `TerminalSession` 与 iOS `MobileTerminalController` 共用这一份
/// （迁移计划 docs/ghostty-migration-plan.md §2）：
///
///     入站任务（detached，不占主线程）
///        │  闸门：surface 没解析完的字节到 1 MiB 就停取，落回 256 KiB 再取（往后端施背压）
///        ├─► 影子终端 `ShadowTerminal.feed`（同步解析，事件随之发出）
///        ├─► tap `onFed`（远控镜像、holder 检查点拿原样字节；这时影子已经解析到这批字节为止）
///        └─► surface `receive`（异步解析、渲染线程出帧）——只在 surface 吃字节时
///
/// **surface 可以暂时不吃字节**（`setSurfaceFeeding(false)`）：surface 还没建（标签没露出过、会话刚从检查点还原）、
/// iOS 进了后台（GhosttyKit 不 tick，解析线程会卡在 app mailbox 上，M10）、Mac 的标签切走了。这期间输出只进影子；
/// 重新开始吃的时候先让 surface 追上影子（补尾巴，或者把影子的状态回放进去：`ShadowTerminal.makeReplay` → `receiveReplay`，
/// 都不产生应答），再接实时字节。影子没有被 surface 落下过内容时什么都不补。
///
/// **补尾巴优先于整屏回放。** 停喂时 surface 队列里没解析的实时字节拿回来，停喂期间的输出也接着攒（`tail`），恢复时原样
/// 补给 surface（`receiveReplay`，不产生应答——影子已经答过）：surface 只是晚一点解析同一串字节，往上翻着的视口、选区、
/// Kitty 图片都还在（标签切走再切回、iOS 回前台）。补不了才整屏回放：surface 换了一个（放掉后重建）、攒过了 `tailLimit`、
/// 期间网格变了（同一串字节按不同网格解析结果不同）、交回来的不全（夹着回放）、影子被整个换过（快照）。整屏回放的开头是复位，
/// 视口回到底部、选区清掉、Kitty 图片丢掉；视口由宿主按 `onSurfaceCaughtUp` 找回去（`TerminalViewportMark`）。
///
/// **擦屏与选区**：每片字节过一遍 `TerminalEraseScanner`，认出清屏 / 擦除的，等 surface 解析到那里之后（`afterPendingOutput`）
/// 交给 `onSurfaceErase`，宿主据此清掉 surface 上的选区（Ghostty 引擎清屏时不清选区）。
///
/// 代次（`generation`）：`reset()` 递增，上一条连接残留的入站任务随之作废。
///
/// 线程：类型线程安全。喂影子、tap、往 surface 入队、切换、回放都在同一把锁里做，所以两边吃到的字节顺序一致，
/// 切换对字节流是原子的；`performWhileFeedingPaused` 让别人（拍快照的）借这把锁拿到「某个字节位置上」的一致状态。
nonisolated final class TerminalOutputPump: @unchecked Sendable {
    /// surface 没解析完的字节到这么多，入站任务就停下不再取后端的输出，落回 `lowWater` 再继续。
    /// 前台正常时 surface 每秒能解析几百 MB，到不了这里；到了说明主线程卡住没在 tick。
    static let highWater = 1 << 20
    static let lowWater = 256 << 10
    /// 大块输出切成这么大再喂：每片之间看一次闸门，surface 的积压最多超出 `highWater` 一片；
    /// 读影子的一方（主线程）最多等一片的解析（约 0.1 ms）。
    static let sliceBytes = 64 << 10
    /// 主控端画面停着等「同网格的快照」最多等这么久（见 `followsSnapshotGrid`）；过了就照常回放，错位也比画面不动好。
    static let gridAlignmentTimeout: TimeInterval = 1.0

    /// 读数与测试用。
    nonisolated struct Stats: Sendable {
        /// 只进了影子、没进 surface 的字节（累计）。
        var shadowOnlyBytes = 0
        /// 停喂那一刻 surface 队列里还没解析、被丢掉的字节（累计；它们已经在影子里，由回放补上）。
        var droppedSurfaceBytes = 0
        /// 回放次数。
        var replays = 0
        /// 最近一次回放：流的字节数、快照的字节数、拍快照 + 生成回放流 + 自查一共用了多久，以及其中三步各多久（秒）。
        var lastReplayBytes = 0
        var lastSnapshotBytes = 0
        var lastReplayBuildSeconds = 0.0
        var lastReplayPhaseSeconds = (encode: 0.0, stream: 0.0, verify: 0.0)
        /// 探针打印用（读的时候才拼，不在泵的锁里）。
        var lastReplayPhases: String {
            String(format: "encode=%.1fms stream=%.1fms verify=%.1fms", lastReplayPhaseSeconds.encode * 1000,
                   lastReplayPhaseSeconds.stream * 1000, lastReplayPhaseSeconds.verify * 1000)
        }
        /// 最近一次回放用的是不是首选的那一版（软折行并回一行）；false = 自查没过，用了逐行的后备版。
        var lastReplayUnwrapped = true
        /// 最近一次回放发出去的那一版自查过了没有（没过也照发，画面可能和影子差一点）。
        var lastReplayVerified = true
        /// 最近一次回放失败的原因（失败时 surface 不回放、直接接实时字节，画面可能是旧的）。
        var lastReplayError: String?
        /// 入站任务因为 surface 积压停下过几次。
        var backpressureWaits = 0
        /// 收到的整屏快照（远控镜像）里解不开的张数。
        var rejectedSnapshots = 0
        /// 主控端因为影子与 surface 网格不一致而停画的次数、等不到对齐超时放行的次数。
        var gridHolds = 0
        var gridHoldTimeouts = 0
        /// 恢复喂 surface 时补尾巴（而不是整屏回放）的次数。
        var tailCatchUps = 0
    }

    /// surface 追上影子的方式（`onSurfaceCaughtUp`）。
    nonisolated enum CatchUp: Sendable {
        /// 补了尾巴：视口、选区都还在原处。
        case tail
        /// 整屏回放：视口回到了底部、选区没了。
        case replay
    }

    /// 停喂期间最多攒这么多字节等着补给 surface；再多就整屏回放（回放的代价和输出量无关）。
    static let tailLimit = 2 << 20

    let shadow: ShadowTerminal
    private let surface: any TerminalSurfaceSink

    /// 保护分流状态（见类型注释）。
    private let stateLock = NSRecursiveLock()
    private var feedsSurface = false
    /// 想不想让 surface 吃字节；回放排在串行队列上，轮到时再看一眼它还作不作数。
    private var wantsSurface = false
    /// surface 落后于影子：它不吃字节的时候来过输出，或者停喂时丢过它队列里的积压，或者影子被整个换过。
    private var surfaceIsStale = false
    private var stats = Stats()
    private var currentGeneration = 0
    private var ingressTask: Task<Void, Never>?
    private var fedHandler: (@Sendable (Data) -> Void)?
    private var replayedHandler: (@Sendable () -> Void)?
    /// 见 `followsSnapshotGrid`。单独一把锁：surface 的 IO 线程要读它，不能等 `stateLock`（回放拿着它往 IO 队列里塞东西）。
    private let followsSnapshotGridFlag = OSAllocatedUnfairLock(initialState: false)
    /// 画面停着等网格对齐（影子是被控端的网格、surface 是本地的网格）。
    private var heldForGrid = false
    private var heldSince: UInt64 = 0
    private var holdToken = 0
    /// 超时放行过的那一对网格（影子、surface）：同样的错位不再停第二次，等网格变了再说。
    private var waivedMismatch: (shadowCols: Int, shadowRows: Int, surfaceCols: Int, surfaceRows: Int)?
    /// surface 落后于影子的正好是这串字节（停喂时它队列里没解析的 + 停喂期间来的），网格是 `tailGrid`。nil = 补不了。
    private var tail: Data?
    private var tailGrid: (cols: Int, rows: Int)?
    private var scanner = TerminalEraseScanner()
    /// surface 还没解析到的擦屏（停喂期间来的）：追上之后交出去。
    private var pendingErase: TerminalErase?
    private var eraseHandler: (@Sendable (TerminalErase) -> Void)?
    private var caughtUpHandler: (@Sendable (CatchUp) -> Void)?
    /// 见 `whenFed`。`watchCarry` 是上一片末尾不到一整串的那几个字节（串可能被切在两片之间）。
    private var watch: (pattern: Data, body: @Sendable () -> Void)?
    private var watchCarry = Data()

    /// 保护闸门。surface 的 backlog 回调可能就在 `surface.receive` 里同步回来（那时 `stateLock` 在手上），
    /// 所以闸门另用一把锁，并且拿着它时不调 surface、不拿 `stateLock`（顺序只能是 stateLock → gateLock）。
    private let gateLock = NSLock()
    private var isBacklogged = false
    private var gateFollowsBacklog = false
    private var isClosed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 回放时人就在等这一帧，按交互优先级跑。
    private let catchUpQueue = DispatchQueue(label: "com.uozi.uTerm.terminal-catch-up", qos: .userInteractive)

    init(shadow: ShadowTerminal, surface: any TerminalSurfaceSink) {
        self.shadow = shadow
        self.surface = surface
        // 一开始 surface 不吃字节（还没建）：查询由影子答。
        shadow.setRepliesEnabled(true)
        surface.setOutputBacklogHandler(highWater: Self.highWater, lowWater: Self.lowWater) { [weak self] backlogged in
            self?.backlogChanged(backlogged)
        }
    }

    deinit {
        ingressTask?.cancel()
        surface.setOutputBacklogHandler(highWater: Self.highWater, lowWater: Self.lowWater, nil)
    }

    var currentStats: Stats { stateLock.withLock { stats } }

    /// surface 此刻吃不吃实时字节。
    var isFeedingSurface: Bool { stateLock.withLock { feedsSurface } }

    /// 当前绑定的代次：`reset()` 递增。
    var generation: Int { stateLock.withLock { currentGeneration } }

    /// 入站任务在跑（`start` 之后、`reset` 之前）。
    var isRunning: Bool { stateLock.withLock { ingressTask != nil } }

    /// tap：每片字节喂进影子之后、交给 surface 之前调，参数就是这一片。在喂字节的那条线程上、拿着泵的锁调：
    /// 这时读影子（拍快照）正好对应「到这一片为止」；别在里面做重活，也别反过来调泵的 `start` / `reset`。
    var onFed: (@Sendable (Data) -> Void)? {
        get { stateLock.withLock { fedHandler } }
        set { stateLock.withLock { fedHandler = newValue } }
    }

    /// 影子的状态整个回放进了 surface（重新开始吃字节、收到整屏快照）之后调，在回放的那条线程上。
    var onReplayed: (@Sendable () -> Void)? {
        get { stateLock.withLock { replayedHandler } }
        set { stateLock.withLock { replayedHandler = newValue } }
    }

    /// 字节里有擦屏的序列（`TerminalEraseScanner`），而且 surface 已经解析到了那里。在会话的输出队列上调（不是主线程）。
    /// surface 停喂期间来的，等它追上之后再调。一片字节最多调一次，取最重的那一档。
    var onSurfaceErase: (@Sendable (TerminalErase) -> Void)? {
        get { stateLock.withLock { eraseHandler } }
        set { stateLock.withLock { eraseHandler = newValue } }
    }

    /// surface 追上了影子（恢复喂它时补了尾巴，或者整屏回放了），而且已经解析完。在会话的输出队列上调。
    var onSurfaceCaughtUp: (@Sendable (CatchUp) -> Void)? {
        get { stateLock.withLock { caughtUpHandler } }
        set { stateLock.withLock { caughtUpHandler = newValue } }
    }

    /// surface 落后于影子、等着追（下次开始喂它时补尾巴或回放）。
    var surfaceNeedsCatchUp: Bool { stateLock.withLock { surfaceIsStale } }

    /// 主控端（远控镜像：Mac 的远控窗口、iOS 的远控标签）打开。影子的网格跟着被控端走（快照带来），不跟本地 surface；
    /// 两边网格不一样时——刚接入、本地刚改了尺寸，被控端还没按本地尺寸钉好再发快照——按被控端网格排好的内容灌进本地
    /// 网格的 surface 只会错位，所以画面先停在上一帧（字节照样进影子），等来同网格的快照再回放，最多等
    /// `gridAlignmentTimeout`。默认关：本机会话的影子本来就跟着 surface 走。
    ///
    /// 由 `start(_ backend:)` 按后端的能力（`mirrorsRemoteGrid`）设；surface 的 IO 线程据此决定影子跟不跟本地网格（任意线程可读）。
    var followsSnapshotGrid: Bool {
        get { followsSnapshotGridFlag.withLock { $0 } }
        set {
            stateLock.withLock {
                followsSnapshotGridFlag.withLock { $0 = newValue }
                if !newValue, heldForGrid {
                    heldForGrid = false
                    if feedsSurface, surfaceIsStale { replayLocked() }
                }
            }
        }
    }

    /// 画面此刻停着等网格对齐（测试用）。
    var isHoldingForGrid: Bool { stateLock.withLock { heldForGrid } }

    // MARK: 入站

    /// 代次 +1，停掉入站任务，放掉挂在闸门上的等待。影子和 surface 里已有的内容不动。
    func reset() {
        stateLock.lock()
        currentGeneration &+= 1
        watchCarry = Data()
        let task = ingressTask
        ingressTask = nil
        stateLock.unlock()
        task?.cancel()
        setClosed(true)
    }

    /// 按当前代次开始泵这条后端的输出，网格跟谁走按它的能力定（`followsSnapshotGrid`）。调用方先 `reset()`。
    func start(_ backend: any TerminalBackend) {
        followsSnapshotGrid = backend.mirrorsRemoteGrid
        start(backend.outputItems)
    }

    /// 按当前代次开始泵 `output`。调用方先 `reset()`。
    func start(_ output: AsyncStream<TerminalOutputItem>) {
        setClosed(false)
        stateLock.lock()
        let generation = currentGeneration
        ingressTask?.cancel()
        // detached：不被主线程上的工作（SwiftUI 渲染、别的窗格）卡住。
        ingressTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await item in output {
                guard let self, !Task.isCancelled else { break }
                await self.ingest(item, generation: generation)
            }
        }
        stateLock.unlock()
    }

    /// 一项后端输出。surface 积压时在这里挂起（不取下一块 = 往后端施背压）；只喂影子时不等。
    private func ingest(_ item: TerminalOutputItem, generation: Int) async {
        switch item {
        case .bytes(let chunk):
            var start = chunk.startIndex
            while start < chunk.endIndex {
                await waitForAdmission()
                let end = min(chunk.endIndex, start + Self.sliceBytes)
                route(chunk[start..<end], generation: generation)
                start = end
            }
        case .history(let chunk):
            // 不等闸门：历史补得越快越好，surface 排队多了自己会整屏回放。
            var start = chunk.startIndex
            while start < chunk.endIndex {
                let end = min(chunk.endIndex, start + Self.sliceBytes)
                route(chunk[start..<end], generation: generation, asHistory: true)
                start = end
            }
        case .snapshot(let snapshot):
            applySnapshot(snapshot, generation: generation)
        case .afterFed(let body):
            runSyncPoint(body, generation: generation)
        }
    }

    private func runSyncPoint(_ body: @Sendable () -> Void, generation: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if generation == currentGeneration { body() }
    }

    /// 不经闸门直接分流一片字节（测试直接喂字节、`clearOutput` 这类不走后端的字节用）。
    func route(_ slice: Data) {
        route(slice, generation: nil)
    }

    private func route(_ slice: Data, generation: Int?, asHistory: Bool = false) {
        guard !slice.isEmpty else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        // 换了连接之后，上一条连接的入站任务手上还攥着的那一片不要了。
        if let generation, generation != currentGeneration { return }
        if !asHistory, let watch, let cut = watchCut(in: slice, pattern: watch.pattern) {
            // 在串的末尾切开：前半片进去、调 `body`（它 route 的字节排在这里）、再进后半片。
            self.watch = nil
            watchCarry = Data()
            feedLocked(slice[..<cut], asHistory: false)
            watch.body()
            feedLocked(slice[cut...], asHistory: false)
            return
        }
        feedLocked(slice, asHistory: asHistory)
    }

    /// 等字节流里来一串 `pattern`：它整串进了影子之后、同一片里排在它后面的字节之前，调一次 `body`
    /// （在喂字节的那条线程上、拿着泵的锁）。`body` 里可以读影子、可以 `route(_:)` 本端的字节——它们正好插在这串后面，
    /// 影子、tap、surface 看到的顺序一样。只等一次；再调会换掉上一个。历史字节不看。
    func whenFed(_ pattern: Data, _ body: @escaping @Sendable () -> Void) {
        guard !pattern.isEmpty else { return }
        stateLock.withLock {
            watch = (pattern, body)
            watchCarry = Data()
        }
    }

    /// 撤掉 `whenFed` 等着的那一串。
    func cancelWhenFed() {
        stateLock.withLock {
            watch = nil
            watchCarry = Data()
        }
    }

    /// 调用方持 `stateLock`。`pattern` 在（上一片的尾巴 + 这一片）里结束的位置（这一片的下标）；没有就记下这一片的尾巴。
    private func watchCut(in slice: Data, pattern: Data) -> Data.Index? {
        let keep = pattern.count - 1
        if !watchCarry.isEmpty {
            // 跨片：尾巴比串短，命中的话一定结束在这一片里。
            let head = watchCarry + slice.prefix(keep)
            if let range = head.range(of: pattern) {
                return slice.index(slice.startIndex, offsetBy: range.upperBound - watchCarry.count)
            }
        }
        if let range = slice.range(of: pattern) { return range.upperBound }
        watchCarry = slice.count >= keep ? Data(slice.suffix(keep)) : Data((watchCarry + slice).suffix(keep))
        return nil
    }

    /// 调用方持 `stateLock`。一片字节：影子 → tap → surface。
    private func feedLocked(_ slice: Data, asHistory: Bool) {
        guard !slice.isEmpty else { return }
        let erase = scanner.scan(slice)
        shadow.feed(slice, asHistory: asHistory)
        fedHandler?(slice)
        if feedsSurface, !holdIfGridMismatchedLocked() {
            // 刚放行时回放已经带上了这一片。
            if surfaceIsStale {
                noteErase(erase)
                replayLocked()
            } else {
                // 历史字节 surface 也不答（`receiveReplay`）。
                if asHistory { surface.receiveReplay(slice) } else { surface.receive(slice) }
                if let erase { deliverEraseAfterSurface(erase) }
            }
        } else {
            surfaceIsStale = true
            stats.shadowOnlyBytes += slice.count
            noteErase(erase)
            appendToTail(slice)
        }
    }

    // MARK: 补尾巴、擦屏

    /// 调用方持 `stateLock`。surface 没在吃字节时来的一片：接到尾巴上；网格变了或攒太多就不补了（到时整屏回放）。
    private func appendToTail(_ slice: Data) {
        guard tail != nil else { return }
        let grid = shadow.size
        guard let tailGrid, tailGrid == grid, tail!.count + slice.count <= Self.tailLimit else {
            tail = nil
            return
        }
        tail!.append(slice)
    }

    /// 调用方持 `stateLock`。surface 恢复吃字节：能补尾巴就补（返回 true），补不了返回 false（由调用方整屏回放）。
    private func catchUpWithTailLocked() -> Bool {
        guard let pending = tail, let tailGrid else { return false }
        tail = nil
        let grid = shadow.size
        guard grid == tailGrid, surface.surfaceGridSize.map({ $0 == tailGrid }) ?? true else { return false }
        if !pending.isEmpty { surface.receiveReplay(pending) }
        stats.tailCatchUps += 1
        surfaceIsStale = false
        notifyCaughtUpLocked(.tail)
        return true
    }

    /// 调用方持 `stateLock`。surface 还没解析到的擦屏先记着。
    private func noteErase(_ erase: TerminalErase?) {
        guard let erase else { return }
        pendingErase = max(pendingErase ?? erase, erase)
    }

    /// 调用方持 `stateLock`。等 surface 解析完已经交给它的字节，再交出擦屏。
    private func deliverEraseAfterSurface(_ erase: TerminalErase) {
        guard let handler = eraseHandler else { return }
        surface.afterPendingOutput { handler(erase) }
    }

    /// 调用方持 `stateLock`。surface 追上了：等它解析完，先交出期间攒下的擦屏，再报追上了。
    private func notifyCaughtUpLocked(_ kind: CatchUp) {
        let erase = pendingErase
        pendingErase = nil
        let eraseHandler = eraseHandler, caughtUpHandler = caughtUpHandler
        guard erase != nil && eraseHandler != nil || caughtUpHandler != nil else { return }
        surface.afterPendingOutput {
            if let erase { eraseHandler?(erase) }
            caughtUpHandler?(kind)
        }
    }

    // MARK: 主控端等网格对齐

    /// 调用方持 `stateLock`，且 surface 在吃字节。该停画就停（返回 true，surface 队列里排着的丢掉、记为落后）；
    /// 网格对齐了或者等超时了就放行（返回 false，由调用方回放）。
    private func holdIfGridMismatchedLocked() -> Bool {
        guard followsSnapshotGrid, let grid = surface.surfaceGridSize else {
            heldForGrid = false
            return false
        }
        let current = shadow.size
        if current.cols == grid.cols, current.rows == grid.rows {
            waivedMismatch = nil
            heldForGrid = false
            return false
        }
        let pair = (shadowCols: current.cols, shadowRows: current.rows, surfaceCols: grid.cols, surfaceRows: grid.rows)
        if let waivedMismatch, waivedMismatch == pair { return false }
        if heldForGrid {
            let waited = Double(DispatchTime.now().uptimeNanoseconds - heldSince) / 1e9
            guard waited >= Self.gridAlignmentTimeout else { return true }
            heldForGrid = false
            waivedMismatch = pair
            stats.gridHoldTimeouts += 1
            surfaceIsStale = true
            tail = nil
            return false
        }
        heldForGrid = true
        heldSince = DispatchTime.now().uptimeNanoseconds
        holdToken &+= 1
        stats.gridHolds += 1
        stats.droppedSurfaceBytes += surface.discardPendingOutput()
        surfaceIsStale = true
        tail = nil
        // 没有新字节、也没有新快照时由它来放行。
        let token = holdToken
        catchUpQueue.asyncAfter(deadline: .now() + Self.gridAlignmentTimeout + 0.01) { [weak self] in
            self?.gridHoldTimerFired(token)
        }
        return true
    }

    /// surface 的终端报来了新网格（IO 线程在改网格之前报的；之后排进去的回放按新网格解析）。停着等对齐的画面
    /// 这时可能对上了：在后台队列上再看一次。任何线程可调。
    func surfaceGridDidChange() {
        catchUpQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            guard self.heldForGrid, self.feedsSurface else { return }
            if !self.holdIfGridMismatchedLocked(), self.surfaceIsStale { self.replayLocked() }
        }
    }

    private func gridHoldTimerFired(_ token: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard heldForGrid, holdToken == token, feedsSurface else { return }
        if !holdIfGridMismatchedLocked(), surfaceIsStale { replayLocked() }
    }

    /// 整屏快照（远控镜像）：影子就地换成快照里的终端，再把它回放进 surface。两端共用的入口——
    /// 主控端（Mac 的远控窗口、iOS）收到 `.snapshot` 一项时走到这里，自己不用再做别的。
    func applySnapshot(_ snapshot: Data) {
        applySnapshot(snapshot, generation: nil)
    }

    private func applySnapshot(_ snapshot: Data, generation: Int?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let generation, generation != currentGeneration { return }
        let localGrid = shadow.wasSized && !followsSnapshotGrid ? shadow.size : nil
        do {
            try shadow.restore(snapshot: snapshot)
        } catch {
            stats.rejectedSnapshots += 1
            return
        }
        // 本机会话（影子跟本地网格走）还原检查点：快照是按存它时的尺寸拍的，回到本地的网格。
        if let localGrid {
            shadow.resize(cols: UInt16(clamping: localGrid.cols), rows: UInt16(clamping: localGrid.rows))
        }
        surfaceIsStale = true
        tail = nil
        // 整屏换了内容：选区一律清掉（surface 追上之后）。
        noteErase(.screen)
        if feedsSurface, !holdIfGridMismatchedLocked() { replayLocked() }
    }

    /// DECSCUSR 0：光标形状、闪烁回到配置的默认值。
    static let resetCursorShape = Data("\u{1B}[0 q".utf8)

    /// 换连接时关掉上一条连接上的程序打开、却没来得及关的输入模式。这些模式决定终端往 PTY 发什么：
    /// 鼠标上报（X10 / 1000 / 1002 / 1003 与 1005 / 1006 / 1015 / 1016 编码）留着，新 shell 就收到
    /// `\e[<35;65;9M` 这种上报、readline 吞掉前缀后把其余的当字打进命令行（合盖断线、重连后满屏 `35;65;9M`）；
    /// 焦点上报（1004）同理是 `\e[I` / `\e[O`；括号粘贴（2004）、应用光标键（DECCKM）、应用小键盘（DECKPAM）、
    /// kitty 键盘协议、modifyOtherKeys 会让按键和粘贴变成 shell 不认的序列。另外把光标显示回来（Claude 这类程序会藏光标）、
    /// 收掉没结束的同步输出（2026，否则画面停到超时）、SGR 复位（免得登录横幅带着上个程序的颜色）。
    /// 不复位滚动区域与原点模式：这两条会把光标送回左上角，盖掉屏上的旧内容。
    static let resetInputModes: Data = {
        let privateModes: [String] = ["9", "1000", "1001", "1002", "1003", "1004", "1005", "1006", "1015", "1016",
                                      "2004", "1", "2026"]
        var text = privateModes.map { "\u{1B}[?\($0)l" }.joined()
        text += "\u{1B}>"          // DECKPNM：小键盘回到普通模式
        text += "\u{1B}[=0;1u"     // kitty 键盘协议：当前标志清零
        text += "\u{1B}[>4m"       // modifyOtherKeys 复位
        text += "\u{1B}[?25h"      // 光标可见
        text += "\u{1B}[0m"        // SGR 复位
        return Data(text.utf8)
    }()

    /// 退出备用屏（1049：回主屏并还原进备用屏前存的光标）。只在影子确实停在备用屏时送：不在备用屏时 1049 复位照样
    /// 还原「存过的光标」，会把光标挪到不知哪次存的位置。
    static let leaveAlternateScreen = Data("\u{1B}[?1049l".utf8)

    /// 换连接时送进泵的整段复位：先离开备用屏（kitty 键盘标志按屏分开存，回主屏后再清），再复位输入模式与光标形状。
    static func resetForNewConnection(onAlternateScreen: Bool) -> Data {
        (onAlternateScreen ? leaveAlternateScreen : Data()) + resetInputModes + resetCursorShape
    }

    /// 换了一条新连接（重连，两端共用）：新连接上的程序不知道上一条连接上的程序把终端改成了什么样——光标形状（DECSCUSR，
    /// vim 插入模式的竖线、Claude 的块……）、鼠标 / 焦点上报、键盘编码、备用屏（`resetForNewConnection`）。先复位，
    /// 影子、画面、镜像、检查点经这条泵看到它。
    /// 接回 holder（程序还在跑）、远控镜像时影子随后整个换成快照，这一下被盖掉，程序设的模式保留。
    /// 全新的终端（影子没内容）不送：模式本来就是默认的，也免得空终端被当成有内容、surface 挂上时白回放一次。
    func resetModesForNewConnection() {
        guard shadow.hasContent else { return }
        route(Self.resetForNewConnection(onAlternateScreen: shadow.isOnAlternateScreen))
    }

    /// 影子被不经过泵的方式改过（从检查点还原、直接喂了历史）：surface 要重新对齐。正在吃字节就当场回放，
    /// 否则等下次开始吃的时候。
    func markSurfaceStale() {
        stateLock.lock()
        defer { stateLock.unlock() }
        surfaceIsStale = true
        tail = nil
        if feedsSurface, !holdIfGridMismatchedLocked() { replayLocked() }
    }

    /// 在「没有字节正在喂」的状态下跑 `body`：里面读影子（拍快照、读光标）对应的是字节流上一个确定的位置，
    /// 和 tap 看到的先后一致。可重入（tap 里再调也行）。
    func performWhileFeedingPaused<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    // MARK: 闸门

    private func waitForAdmission() async {
        guard !admitsNow() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            park(continuation)
        }
    }

    /// 调用方持 `gateLock`。
    private var isGateOpen: Bool { isClosed || !(gateFollowsBacklog && isBacklogged) }

    /// 闸门开着就放行；关着就记一次等待。（锁的进出放在同步方法里：异步上下文里不能直接 lock / unlock。）
    private func admitsNow() -> Bool {
        let open = gateLock.withLock { isGateOpen }
        if !open { stateLock.withLock { stats.backpressureWaits += 1 } }
        return open
    }

    /// 挂到闸门上；这一瞬间闸门已经开了就直接放行。
    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        gateLock.lock()
        if isGateOpen {
            gateLock.unlock()
            continuation.resume()
        } else {
            waiters.append(continuation)
            gateLock.unlock()
        }
    }

    private func updateGate(_ change: () -> Void) {
        gateLock.lock()
        change()
        var released: [CheckedContinuation<Void, Never>] = []
        if isGateOpen {
            released = waiters
            waiters.removeAll()
        }
        gateLock.unlock()
        released.forEach { $0.resume() }
    }

    private func backlogChanged(_ backlogged: Bool) {
        updateGate { isBacklogged = backlogged }
    }

    private func setGateFollowsBacklog(_ follows: Bool) {
        updateGate { gateFollowsBacklog = follows }
    }

    private func setClosed(_ closed: Bool) {
        updateGate { isClosed = closed }
    }

    // MARK: surface 吃不吃字节

    /// `false`：从现在起只喂影子。surface 队列里还没解析的字节拿出来（iOS 后台时 GhosttyKit 不 tick，留在队列里会把解析卡死），
    /// 记作尾巴的开头，之后来的输出接在后面。这期间由影子替 surface 应答查询（surface 不解析就不会答）。
    /// `true`：把尾巴补给 surface（补不了就把影子的状态整屏回放进去），然后接实时字节。在后台队列上做，不占主线程。
    /// 泵刚建好时是 `false`：surface 还没建，谁建好了谁来调 `true`。
    func setSurfaceFeeding(_ feeding: Bool) {
        stateLock.lock()
        wantsSurface = feeding
        if !feeding, feedsSurface {
            feedsSurface = false
            heldForGrid = false
            // 停喂之前就已经落后了（主控端停着等网格对齐）：差的不止队列里这些，补不了。
            let wasBehind = surfaceIsStale
            let taken = surface.takePendingOutputForCatchUp()
            if taken.droppedBytes > 0 {
                surfaceIsStale = true
                stats.droppedSurfaceBytes += taken.droppedBytes
            }
            if taken.complete, !wasBehind {
                tail = taken.bytes
                tailGrid = shadow.size
                // 拿回来的字节里的擦屏：surface 还没解析到，等补完再交。
                noteErase(TerminalEraseScanner.scanFresh(taken.bytes))
            } else {
                tail = nil
            }
            shadow.setRepliesEnabled(true)
        }
        // 只喂影子时不看 surface 的积压：它这时不会消，等它就等于把入站卡死（M10 原来的病）。
        if !feeding { setGateFollowsBacklog(false) }
        stateLock.unlock()
        if feeding {
            catchUpQueue.async { [weak self] in self?.catchUp() }
        }
    }

    /// 等排着的回放做完（测试用）。
    func waitForCatchUp() {
        catchUpQueue.sync {}
    }

    private func catchUp() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard wantsSurface, !feedsSurface else { return }
        shadow.setRepliesEnabled(false)
        feedsSurface = true
        if !holdIfGridMismatchedLocked(), surfaceIsStale, !catchUpWithTailLocked() { replayLocked() }
        if !surfaceIsStale { tail = nil }
        setGateFollowsBacklog(true)
    }

    /// 调用方持 `stateLock`。把影子此刻的状态回放进 surface；它队列里排着的实时字节已经在影子里，先丢掉。
    private func replayLocked() {
        let started = DispatchTime.now().uptimeNanoseconds
        stats.droppedSurfaceBytes += surface.discardPendingOutput()
        do {
            let replay = try shadow.makeReplay()
            // 一次交给 surface：它拿着终端锁把整段解析完，渲染线程看不到「复位了、还没写回来」的中间状态。
            surface.receiveReplay(replay.stream)
            stats.replays += 1
            stats.lastReplayBytes = replay.stream.count
            stats.lastSnapshotBytes = replay.snapshotBytes
            stats.lastReplayPhaseSeconds = (replay.encodeSeconds, replay.buildSeconds, replay.verifySeconds)
            stats.lastReplayUnwrapped = replay.unwrapped
            stats.lastReplayVerified = replay.verified
            stats.lastReplayError = nil
        } catch {
            stats.lastReplayError = "\(error)"
        }
        stats.lastReplayBuildSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        surfaceIsStale = false
        tail = nil
        replayedHandler?()
        notifyCaughtUpLocked(.replay)
    }
}
