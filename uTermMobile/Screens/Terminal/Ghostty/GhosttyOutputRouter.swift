import Foundation
import GhosttyTerminal

// M10（iOS 后台）的修法：后端输出永远先进影子终端；画面（surface）只在 App 看得见时才吃字节。
//
// 为什么：GhosttyKit 在 App 进后台后不再 tick，而 surface 解析时碰到标题 / bell / pwd / 进度条这类要进 ghostty
// app mailbox（64 格、只有 tick 才清）的消息，mailbox 一满解析线程就卡在 `ghostty_surface_write_buffer` 里，
// 后面来的字节在会话里无上限排队（Claude 式输出约 6 秒卡住，5 分钟攒了 6 MB，回前台 1.1 秒才补出画面）。
// 影子终端同步解析、不经 mailbox，不会卡。回前台时拍一张影子的二进制快照，变成一段回放流灌进 surface
//（`receiveReplay`：不产生应答），surface 就到了影子此刻的状态，之后接着吃实时字节。
//
// **第 2 步要并进共享的 `TerminalOutputPump`**（计划 §4：入站 → 有界缓冲 → tap → 影子（同步）→ surface（异步））。
// 这里先放在 iOS 试用目录下，只给「Ghostty 试用」那条路用。

/// 一条终端的输出分流。线程安全；`ingest` 在入站任务上调，切换在主线程上调，回放在自己的串行队列上做。
nonisolated final class GhosttyOutputRouter: @unchecked Sendable {
    /// surface 没解析完的字节到这么多，入站任务就停下不再取后端的输出，落回 `lowWater` 再继续。
    /// 前台正常时 surface 每秒能解析几百 MB，到不了这里；到了说明主线程卡住没在 tick。
    static let highWater = 1 << 20
    static let lowWater = 256 << 10
    /// 大块输出切成这么大再喂：每片之间看一次闸门，surface 的积压最多超出 `highWater` 一片。
    static let sliceBytes = 64 << 10

    /// 读数与测试用。
    nonisolated struct Stats: Sendable {
        /// 只进了影子、没进 surface 的字节（累计）。
        var shadowOnlyBytes = 0
        /// 进后台那一刻 surface 队列里还没解析、被丢掉的字节（累计；它们已经在影子里，回前台由回放补上）。
        var droppedSurfaceBytes = 0
        /// 回放次数。
        var replays = 0
        /// 最近一次回放：流的字节数、快照的字节数、拍快照 + 生成回放流 + 自查一共用了多久，以及其中三步各多久。
        var lastReplayBytes = 0
        var lastSnapshotBytes = 0
        var lastReplayBuildSeconds = 0.0
        var lastReplayPhases = ""
        /// 最近一次回放用的是不是首选的那一版（软折行并回一行）；false = 自查没过，用了逐行的后备版。
        var lastReplayUnwrapped = true
        /// 最近一次回放发出去的那一版自查过了没有（没过也照发，画面可能和影子差一点）。
        var lastReplayVerified = true
        /// 最近一次回放失败的原因（失败时 surface 不回放、直接接实时字节，画面可能是旧的）。
        var lastReplayError: String?
        /// 入站任务因为 surface 积压停下过几次。
        var backpressureWaits = 0
    }

    let shadow: ShadowTerminal
    private let session: InMemoryTerminalSession

    /// 保护分流状态。喂影子、往 surface 入队、切换、回放都在这把锁里做：两边吃到的字节顺序一致，切换对字节流是原子的。
    private let stateLock = NSLock()
    private var feedsSurface = true
    /// 想不想让 surface 吃字节（主线程定）；回放排在串行队列上，轮到时再看一眼它还作不作数。
    private var wantsSurface = true
    /// surface 落后于影子：后台来过字节，或者进后台时丢过它队列里的积压。
    private var surfaceIsStale = false
    private var stats = Stats()

    /// 保护闸门。surface 的 backlog 回调可能就在 `session.receive` 里同步回来（那时 `stateLock` 在手上），
    /// 所以闸门另用一把锁，并且拿着它时不调会话、不拿 `stateLock`（顺序只能是 stateLock → gateLock）。
    private let gateLock = NSLock()
    private var isBacklogged = false
    private var gateFollowsBacklog = true
    private var isClosed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 回前台时人就在等这一帧，按交互优先级跑（Duo 上实测这段工作刚醒来时比热着跑慢得多，别再让它排到省电核上）。
    private let catchUpQueue = DispatchQueue(label: "com.uozi.uTerm.ghostty-catch-up", qos: .userInteractive)

    init(session: InMemoryTerminalSession, shadow: ShadowTerminal) {
        self.session = session
        self.shadow = shadow
        session.setOutputBacklogHandler(highWater: Self.highWater, lowWater: Self.lowWater) { [weak self] backlogged in
            self?.backlogChanged(backlogged)
        }
    }

    var currentStats: Stats {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stats
    }

    /// surface 此刻吃不吃实时字节。
    var isFeedingSurface: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return feedsSurface
    }

    // MARK: 入站

    /// 一块后端输出。surface 积压时在这里挂起（不取下一块 = 往后端施背压）；只喂影子时不等。
    func ingest(_ chunk: Data) async {
        var start = chunk.startIndex
        while start < chunk.endIndex {
            await waitForAdmission()
            let end = min(chunk.endIndex, start + Self.sliceBytes)
            route(chunk[start..<end])
            start = end
        }
    }

    /// 不经闸门直接分流（测试与探针直接喂字节用）。
    func route(_ slice: Data) {
        guard !slice.isEmpty else { return }
        stateLock.lock()
        defer { stateLock.unlock() }
        shadow.feed(slice)
        if feedsSurface {
            session.receive(slice)
        } else {
            surfaceIsStale = true
            stats.shadowOnlyBytes += slice.count
        }
    }

    private func waitForAdmission() async {
        guard !admitsNow() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            park(continuation)
        }
    }

    /// 闸门开着就放行；关着就记一次等待。（锁的进出放在同步方法里：异步上下文里不能直接 lock / unlock。）
    private func admitsNow() -> Bool {
        gateLock.lock()
        let open = isClosed || !(gateFollowsBacklog && isBacklogged)
        gateLock.unlock()
        if !open {
            stateLock.lock()
            stats.backpressureWaits += 1
            stateLock.unlock()
        }
        return open
    }

    /// 挂到闸门上；这一瞬间闸门已经开了就直接放行。
    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        gateLock.lock()
        if isClosed || !(gateFollowsBacklog && isBacklogged) {
            gateLock.unlock()
            continuation.resume()
        } else {
            waiters.append(continuation)
            gateLock.unlock()
        }
    }

    private func backlogChanged(_ backlogged: Bool) {
        gateLock.lock()
        isBacklogged = backlogged
        let released = takeWaitersIfOpen()
        gateLock.unlock()
        released.forEach { $0.resume() }
    }

    /// 调用方持 `gateLock`。
    private func takeWaitersIfOpen() -> [CheckedContinuation<Void, Never>] {
        guard isClosed || !(gateFollowsBacklog && isBacklogged) else { return [] }
        let released = waiters
        waiters.removeAll()
        return released
    }

    private func setGateFollowsBacklog(_ follows: Bool) {
        gateLock.lock()
        gateFollowsBacklog = follows
        let released = takeWaitersIfOpen()
        gateLock.unlock()
        released.forEach { $0.resume() }
    }

    /// 入站任务要停了：放掉挂在闸门上的等待。
    func close() {
        gateLock.lock()
        isClosed = true
        let released = takeWaitersIfOpen()
        gateLock.unlock()
        released.forEach { $0.resume() }
    }

    /// 换了后端重新开始泵。
    func reopen() {
        gateLock.lock()
        isClosed = false
        gateLock.unlock()
    }

    // MARK: 进出后台

    /// `false`：从现在起只喂影子（App 进后台）。surface 队列里还没解析的字节丢掉——它们已经在影子里，留着只会在回前台时
    /// 先被解析一遍（连同它们带的标题一条条 tick）再被回放盖掉。影子开始替 surface 应答查询。
    /// `true`：回放影子的状态进 surface，然后接实时字节（App 回前台）。回放在后台队列上做，不占主线程。
    func setSurfaceFeeding(_ feeding: Bool) {
        stateLock.lock()
        wantsSurface = feeding
        if !feeding, feedsSurface {
            feedsSurface = false
            let dropped = session.discardPendingOutput()
            if dropped > 0 {
                surfaceIsStale = true
                stats.droppedSurfaceBytes += dropped
            }
            shadow.setRepliesEnabled(true)
        }
        // 只喂影子时不看 surface 的积压：它在后台不会消，等它就等于把入站卡死（M10 原来的病）。
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
        guard wantsSurface, !feedsSurface else {
            stateLock.unlock()
            return
        }
        shadow.setRepliesEnabled(false)
        if surfaceIsStale {
            let started = DispatchTime.now().uptimeNanoseconds
            do {
                let replay = try shadow.makeReplay()
                // 一次交给 surface：它拿着终端锁把整段解析完，渲染线程看不到「复位了、还没写回来」的中间状态。
                session.receiveReplay(replay.stream)
                stats.replays += 1
                stats.lastReplayBytes = replay.stream.count
                stats.lastSnapshotBytes = replay.snapshotBytes
                stats.lastReplayPhases = String(format: "encode=%.1fms stream=%.1fms verify=%.1fms",
                                                replay.encodeSeconds * 1000, replay.buildSeconds * 1000, replay.verifySeconds * 1000)
                stats.lastReplayUnwrapped = replay.unwrapped
                stats.lastReplayVerified = replay.verified
                stats.lastReplayError = nil
            } catch {
                stats.lastReplayError = "\(error)"
            }
            stats.lastReplayBuildSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
            surfaceIsStale = false
        }
        feedsSurface = true
        setGateFollowsBacklog(true)
        stateLock.unlock()
    }
}
