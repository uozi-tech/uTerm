import Foundation
import SwiftData
@testable import uTermMobile

/// 假终端传输 —— 按节拍回放脚本输出、回显输入、可模拟断线与重连、可配时延。
///
/// ## 挂载的原理（与假 SFTP 的「写字段绕过 start()」不同）
///
/// `MobileTerminalController` 本轮已经把后端抽成了 `TerminalBackend` +
/// `MobileTerminalTransportFactory`（见 `uTermMobile/Screens/Terminal/MobileTerminalTransport.swift`）。
/// 所以这里走的是**正门**：注入一个返回 `MobileFakeTerminalTransport` 的工厂，
/// 控制器整条真实路径（`connect()` → 状态翻 `.connected` → 输出泵 → 有界缓冲 →
/// 按帧 `feed(byteArray:)` 进 SwiftTerm）原样跑起来，只是底下没有 socket。
///
/// 因此这些都是**真的**被量到的：
/// - `TerminalOutputBuffer` 的入队 / 合并 / drain 节流；
/// - `MobileTerminalController.startOutputFlushLoop` 每 16ms 一次的 `feed`；
/// - SwiftTerm 自己的解析与重绘（vendored，不动）；
/// - `TerminalScreen` 的 `ZStack + ForEach(tabs)` 全常驻挂载。
///
/// 已知局限：`SSHConnection` 的握手 / 认证 / 跳板机那一段不在这条路径上——
/// 假传输的 `connect()` 只是睡 `connectLatency` 然后开始吐字节。

// MARK: - 脚本

/// 一份输出脚本：吐多快、吐多久、吐什么形状的字节。
struct MobileFakeTerminalScript: Sendable {

    /// 语料风格 —— 决定每行里有多少 ANSI 控制序列要 SwiftTerm 去解析。
    enum Corpus: String, Sendable, CaseIterable {
        /// 纯 ASCII 行，无转义序列（`yes` / `cat 纯文本` 的下界）。
        case plain
        /// 带 SGR 颜色 / 加粗 / 复位（`ls --color` / 编译日志 / journalctl 的常态）。
        case ansiColor
        /// 颜色之外还带光标定位与行内擦除（`top` / 进度条那种原地重绘）。
        case cursorHeavy
    }

    /// 每秒多少行。
    var linesPerSecond: Double
    /// 一共吐多久（秒）。`0` = 不自动停（由 `close()` / `stopPump()` 收尾）。
    var seconds: Double
    var corpus: Corpus
    /// 每行的目标可见字符数（不含转义序列）。80 列终端的一整行。
    var columns: Int
    /// `connect()` 里睡多久才算连上（模拟握手 / 认证时延）。
    var connectLatency: Duration
    /// 每次 `write` 前睡多久（模拟上行 RTT）。默认 0 —— 非 0 时键入端到端会被拉长。
    var writeLatency: Duration
    /// 是否把 `write` 的字节原样回吐到输出流（真 shell 的本地回显等价物）。
    var echoesInput: Bool
    /// 脚本吐完之后是否产出 `exitStream` 元素（= 远端 shell 退出 → 控制器翻 `.closed`）。
    var exitsWhenScriptEnds: Bool
    /// `connect()` 直接抛这个错（模拟建连失败，走控制器的 `.failed` 分支）。
    var connectFailure: String?

    init(linesPerSecond: Double,
         seconds: Double,
         corpus: Corpus = .ansiColor,
         columns: Int = 80,
         connectLatency: Duration = .zero,
         writeLatency: Duration = .zero,
         echoesInput: Bool = true,
         exitsWhenScriptEnds: Bool = false,
         connectFailure: String? = nil) {
        self.linesPerSecond = linesPerSecond
        self.seconds = seconds
        self.corpus = corpus
        self.columns = columns
        self.connectLatency = connectLatency
        self.writeLatency = writeLatency
        self.echoesInput = echoesInput
        self.exitsWhenScriptEnds = exitsWhenScriptEnds
        self.connectFailure = connectFailure
    }

    /// 真实档：交互式 shell 的正常输出速率。60 行/秒 ≈ 一屏刷新一次每 0.4 秒，
    /// 相当于 `tail -f` 跟着一条中等流量的服务日志。
    static func interactive(seconds: Double = 10) -> MobileFakeTerminalScript {
        MobileFakeTerminalScript(linesPerSecond: 60, seconds: seconds, corpus: .ansiColor)
    }

    /// 极端档：`yes` / `cat 大文件` 级别的洪水。2000 行/秒 × 80 列 ≈ 160KB/s，
    /// 与真实 SSH 在内网跑 `yes` 时被 PTY 流控压住的量级同阶。
    static func flood(seconds: Double = 10) -> MobileFakeTerminalScript {
        MobileFakeTerminalScript(linesPerSecond: 2000, seconds: seconds, corpus: .ansiColor)
    }

    /// 一台已经连上、但不再吐任何东西的会话（量「常驻挂载」本身的代价用）。
    static let idle = MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0, corpus: .plain)

    /// 每 tick 一批：20ms 一批（50 批/秒），与真实 SSH「chunk 到达即合并」同形，
    /// 也避免 2000 行/秒时每行一次 `Task.sleep` 把节拍本身变成瓶颈。
    static let tickMilliseconds: Int = 20
}

// MARK: - 语料

/// 按 `Corpus` 生成一行字节。确定性（同 `index` 同输出），前→后对照才有意义。
enum MobileFakeTerminalCorpus {

    private static let words = [
        "systemd", "kernel", "nginx", "sshd", "dockerd", "kubelet", "postgres",
        "redis", "containerd", "cron", "dbus", "avahi", "chronyd", "rsyslog",
    ]
    private static let levels = ["INFO", "WARN", "ERROR", "DEBUG", "TRACE"]
    /// SGR 前景色：31 红 / 32 绿 / 33 黄 / 34 蓝 / 36 青。
    private static let sgr = [31, 32, 33, 34, 36]

    static func line(_ index: Int, corpus: MobileFakeTerminalScript.Corpus, columns: Int) -> String {
        let word = words[index % words.count]
        let level = levels[index % levels.count]
        let body = "\(word)[\(1000 + index % 9000)]: \(level) 处理批次 #\(index) 用时 \(index % 97).\(index % 10)ms"
        let padded = pad(body, to: columns)
        switch corpus {
        case .plain:
            return padded + "\r\n"
        case .ansiColor:
            let color = sgr[index % sgr.count]
            // 加粗时间戳 + 彩色级别 + 复位，三段 SGR —— 与 journalctl / 编译日志同形。
            return "\u{1B}[1m\(stamp(index))\u{1B}[0m \u{1B}[\(color)m\(padded)\u{1B}[0m\r\n"
        case .cursorHeavy:
            let color = sgr[index % sgr.count]
            // 行首归位 + 行内擦除 + 彩色重绘 + 光标存取 —— `top` / 进度条那种原地刷新。
            return "\u{1B}[G\u{1B}[K\u{1B}7\u{1B}[\(color)m\(padded)\u{1B}[0m\u{1B}8\u{1B}[B\r"
        }
    }

    private static func stamp(_ index: Int) -> String {
        String(format: "%02d:%02d:%02d.%03d",
               (index / 3600) % 24, (index / 60) % 60, index % 60, (index * 37) % 1000)
    }

    private static func pad(_ s: String, to columns: Int) -> String {
        let n = s.count
        if n >= columns { return String(s.prefix(columns)) }
        return s + String(repeating: " ", count: columns - n)
    }
}

// MARK: - 假传输

/// `TerminalBackend` 的假实现。`actor` —— 协议要求（`protocol TerminalBackend: Actor`）。
actor MobileFakeTerminalTransport: TerminalBackend {

    enum FakeError: Error, LocalizedError {
        case connectFailed(String)
        var errorDescription: String? {
            switch self { case .connectFailed(let m): return m }
        }
    }

    // MARK: TerminalBackend

    nonisolated let outputStream: AsyncStream<Data>
    nonisolated let exitStream: AsyncStream<Void>

    private let outputContinuation: AsyncStream<Data>.Continuation
    private let exitContinuation: AsyncStream<Void>.Continuation

    // MARK: 配置与账本

    let script: MobileFakeTerminalScript
    /// 这条传输是第几次被工厂发出来的（0 起）。重连对照用。
    let generation: Int

    private var pumpTask: Task<Void, Never>?
    private var closed = false
    private var connected = false

    /// 已吐出的行数 / 字节数（跨 actor 读：探针 `await` 拿）。
    private(set) var linesEmitted = 0
    private(set) var bytesEmitted = 0
    /// 上行账本。
    private(set) var writtenBytes = 0
    private(set) var writes: [Data] = []
    private(set) var resizeCount = 0
    private(set) var lastResize: (cols: UInt16, rows: UInt16)?
    private(set) var connectCount = 0
    private(set) var closeCount = 0
    /// 脚本自然跑完的时刻（`nil` = 还没跑完）。
    private(set) var scriptFinished = false

    init(script: MobileFakeTerminalScript, generation: Int = 0) {
        self.script = script
        self.generation = generation
        var out: AsyncStream<Data>.Continuation!
        self.outputStream = AsyncStream { out = $0 }
        self.outputContinuation = out
        var exit: AsyncStream<Void>.Continuation!
        self.exitStream = AsyncStream { exit = $0 }
        self.exitContinuation = exit
    }

    func connect() async throws {
        connectCount += 1
        if let message = script.connectFailure { throw FakeError.connectFailed(message) }
        if script.connectLatency != .zero { try? await Task.sleep(for: script.connectLatency) }
        guard !closed else { return }
        connected = true
        startPump()
    }

    func write(_ data: Data) async {
        if script.writeLatency != .zero { try? await Task.sleep(for: script.writeLatency) }
        guard !closed else { return }
        writtenBytes += data.count
        writes.append(data)
        // 回显：真 shell 的字符回显走远端，这里直接把上行原样回吐。
        if script.echoesInput {
            outputContinuation.yield(data)
            bytesEmitted += data.count
        }
    }

    func resize(cols: UInt16, rows: UInt16) async {
        resizeCount += 1
        lastResize = (cols, rows)
    }

    func close() async {
        guard !closed else { closeCount += 1; return }
        closed = true
        closeCount += 1
        pumpTask?.cancel()
        pumpTask = nil
        outputContinuation.finish()
        exitContinuation.finish()
    }

    // MARK: 测试驱动

    /// 模拟断线：停掉输出泵，往 `exitStream` 送一个元素。
    /// 控制器据此把 `state` 翻成 `.closed`（与远端 shell 退出走同一条收尾级联）。
    func simulateDrop() {
        pumpTask?.cancel()
        pumpTask = nil
        exitContinuation.yield()
    }

    /// 立刻同步吐若干行（不走节拍）。用来量「一批字节从 buffer 到 SwiftTerm 要多久」。
    @discardableResult
    func emitBurst(lines: Int) -> Int {
        var blob = Data()
        for _ in 0..<lines {
            blob.append(contentsOf: Array(MobileFakeTerminalCorpus.line(
                linesEmitted, corpus: script.corpus, columns: script.columns).utf8))
            linesEmitted += 1
        }
        bytesEmitted += blob.count
        outputContinuation.yield(blob)
        return blob.count
    }

    /// 探针读账本的统一入口（一次 `await` 拿全，别在热路径里连着 `await` 五次）。
    struct Ledger: Sendable {
        let generation: Int
        let linesEmitted: Int
        let bytesEmitted: Int
        let writtenBytes: Int
        let writeCount: Int
        let resizeCount: Int
        let lastCols: UInt16?
        let lastRows: UInt16?
        let connectCount: Int
        let closeCount: Int
        let scriptFinished: Bool
    }

    var ledger: Ledger {
        Ledger(generation: generation, linesEmitted: linesEmitted, bytesEmitted: bytesEmitted,
               writtenBytes: writtenBytes, writeCount: writes.count, resizeCount: resizeCount,
               lastCols: lastResize?.cols, lastRows: lastResize?.rows,
               connectCount: connectCount, closeCount: closeCount, scriptFinished: scriptFinished)
    }

    /// 上行收到的全部字节拼起来（键入回路的断言用）。
    var writtenText: String { String(decoding: writes.reduce(Data(), +), as: UTF8.self) }

    // MARK: 输出泵

    private func startPump() {
        guard script.linesPerSecond > 0 else { scriptFinished = true; return }
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in await self?.pump() }
    }

    /// 按 20ms 一批吐字节。批大小用**累加器**算，所以 60 行/秒（1.2 行/批）与
    /// 2000 行/秒（40 行/批）都不会因为取整而系统性偏低。
    private func pump() async {
        let tickMS = MobileFakeTerminalScript.tickMilliseconds
        let perTick = script.linesPerSecond * Double(tickMS) / 1000.0
        let totalTicks = script.seconds > 0
            ? Int((script.seconds * 1000.0 / Double(tickMS)).rounded())
            : Int.max
        var carry = 0.0
        var tick = 0
        while tick < totalTicks, !Task.isCancelled, !closed {
            carry += perTick
            let batch = Int(carry)
            carry -= Double(batch)
            if batch > 0 {
                var blob = Data()
                blob.reserveCapacity(batch * (script.columns + 24))
                for _ in 0..<batch {
                    blob.append(contentsOf: Array(MobileFakeTerminalCorpus.line(
                        linesEmitted, corpus: script.corpus, columns: script.columns).utf8))
                    linesEmitted += 1
                }
                bytesEmitted += blob.count
                outputContinuation.yield(blob)
            }
            try? await Task.sleep(for: .milliseconds(tickMS))
            tick += 1
        }
        guard !Task.isCancelled, !closed else { return }
        scriptFinished = true
        if script.exitsWhenScriptEnds { exitContinuation.yield() }
    }
}

// MARK: - 工厂与挂载器

/// 一次「注入假传输」的把手：工厂 + 它发出去的每一条传输。
///
/// 断线重连要**两条**传输（第一条失败 → `restart()` → 第二条成功），所以工厂按
/// 脚本数组顺序发；发完之后继续复用最后一条脚本。
@MainActor
final class MobileFakeTerminalHandles {
    private let scripts: [MobileFakeTerminalScript]
    private(set) var issued: [MobileFakeTerminalTransport] = []

    init(scripts: [MobileFakeTerminalScript]) {
        precondition(!scripts.isEmpty, "至少给一条脚本")
        self.scripts = scripts
    }

    var factory: MobileTerminalTransportFactory {
        MobileTerminalTransportFactory { [self] _ in
            let index = issued.count
            let script = scripts[min(index, scripts.count - 1)]
            let transport = MobileFakeTerminalTransport(script: script, generation: index)
            issued.append(transport)
            return transport
        }
    }

    /// 最近一条发出去的传输。
    var latest: MobileFakeTerminalTransport? { issued.last }
    var issuedCount: Int { issued.count }
}

/// 把假传输挂进控制器 / 会话标签 / 整屏的入口。
@MainActor
enum MobileFakeTerminal {

    /// 一个已注入假传输、但**还没 start()** 的控制器。
    static func controller(_ scripts: MobileFakeTerminalScript...)
        -> (MobileTerminalController, MobileFakeTerminalHandles) {
        let handles = MobileFakeTerminalHandles(scripts: scripts)
        return (MobileTerminalController(transportFactory: handles.factory), handles)
    }

    /// 一个已注入假传输、但**还没 start()** 的会话标签。
    static func tab(host: ServerProfile, _ scripts: MobileFakeTerminalScript...)
        -> (TermTab, MobileFakeTerminalHandles) {
        let handles = MobileFakeTerminalHandles(scripts: scripts)
        return (TermTab(host: host, transportFactory: handles.factory), handles)
    }

    /// 造 `count` 个已建连的会话标签，塞进一个 `TerminalSessions`（`TerminalScreen` 直接吃它）。
    ///
    /// `hosts` 少于 `count` 时循环取——探针只关心会话数，不关心主机是不是同一台。
    /// 返回的 handles 与 tabs 一一对应（同序）。
    static func sessions(count: Int,
                         hosts: [ServerProfile],
                         script: MobileFakeTerminalScript,
                         container: ModelContainer,
                         relay: HostKeyChallengeRelay)
        -> (TerminalSessions, [MobileFakeTerminalHandles]) {
        precondition(!hosts.isEmpty, "至少一台主机")
        let sessions = TerminalSessions()
        var handles: [MobileFakeTerminalHandles] = []
        for i in 0..<count {
            let host = hosts[i % hosts.count]
            let (tab, h) = tab(host: host, script)
            tab.controller.start(profile: host, container: container, relay: relay)
            sessions.tabs.append(tab)
            handles.append(h)
        }
        sessions.activeID = sessions.tabs.first?.id
        return (sessions, handles)
    }

    /// 等到控制器真的连上（或超时）。假传输的 `connect()` 是 `async` 的，
    /// `start()` 只是把它丢进 `Task`——不等一下 `state` 还停在 `.connecting`。
    @discardableResult
    static func waitUntilConnected(_ controller: MobileTerminalController,
                                   timeout: Duration = .seconds(3)) async -> Bool {
        await waitUntil(timeout: timeout) { controller.state == .connected }
    }

    /// 轮询等待一个条件成立（20ms 一次）。返回是否在超时前成立。
    @discardableResult
    static func waitUntil(timeout: Duration = .seconds(3),
                          _ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
}

// MARK: - 输出压力下的一把尺

/// 终端屏不是列表：没有可滚的内容就没有「200 步往返」，`MobileProbeRig.measureScroll()`
/// 在这里量不到东西（终端刚连上时 `contentSize == bounds`，直接判 `notScrollable`）。
///
/// 换成量**输出压力**：脚本按节拍吐字节的那段时间里，主线程还剩多少余量。
/// 一个窗口同时收三样，口径与 `MobileProbeRig.heartbeat` / `measureScroll` 对齐：
///
/// - **心跳**：`Task.sleep(8ms)` 拍数（主线程还愿不愿意回 runloop）+ `CADisplayLink`
///   拍数（渲染循环实际交付了几帧）。都写「拍数/理想」的比值。
/// - **单帧**：每一拍 `layoutIfNeeded()` + `CATransaction.flush()` 的墙钟，
///   与 `measureScroll` 的每步同义（那边多一个「设 offset」）。
/// - **CPU / footprint**：窗口内的**增量**（两个都是单调累加的进程级读数，
///   只有增量在同一档里有意义）。
///
/// **绝对毫秒只打印**，闸门只用结构判据与同轮相对比。
@MainActor
enum MobileTerminalLoad {

    struct Reading: Sendable {
        let seconds: Double
        let sleepBeats: Int
        let idealSleepBeats: Int
        let displayTicks: Int
        let idealDisplayTicks: Int
        let nominalIntervalMS: Double
        /// 每拍一次 `layout()` 的墙钟样本。
        let frames: [Double]
        let p50: Double
        let p95: Double
        let max: Double
        let budgetMS: Double
        let overBudgetPct: Double
        let overStrictPct: Double
        /// 窗口内主线程 CPU 增量（秒）。
        let cpuSeconds: Double
        /// 窗口内 `phys_footprint` 增量（MB）。
        let footprintDeltaMB: Double

        var sleepRatio: Double { idealSleepBeats == 0 ? 0 : Double(sleepBeats) / Double(idealSleepBeats) }
        var displayRatio: Double { idealDisplayTicks == 0 ? 0 : Double(displayTicks) / Double(idealDisplayTicks) }
    }

    /// 在 `seconds` 的窗口里，每 8ms 逼一次布局 + CA 提交并计时。
    static func measure(_ rig: MobileProbeRig, seconds: Double) async throws -> Reading {
        let maxFPS = MobileProbeWindow.maximumFramesPerSecond()
        let budget = MobileProbeWindow.frameBudgetMS()
        let counter = DisplayLinkCounter()
        counter.start()
        let cpu0 = ProbeMetrics.threadCPUSeconds()
        let foot0 = ProbeMetrics.footprintMB()

        var frames: [Double] = []
        var beats = 0
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            try await Task.sleep(for: .milliseconds(8))
            let t0 = CFAbsoluteTimeGetCurrent()
            rig.layout()
            frames.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            beats += 1
        }
        counter.stop()

        return Reading(seconds: seconds,
                       sleepBeats: beats,
                       idealSleepBeats: Int(seconds / 0.008),
                       displayTicks: counter.ticks,
                       idealDisplayTicks: Int(Double(maxFPS) * seconds),
                       nominalIntervalMS: counter.nominalIntervalMS,
                       frames: frames,
                       p50: ProbeMetrics.percentile(frames, 0.50),
                       p95: ProbeMetrics.percentile(frames, 0.95),
                       max: frames.max() ?? 0,
                       budgetMS: budget,
                       overBudgetPct: percentOver(frames, budget),
                       overStrictPct: percentOver(frames, ProbeBudget.strictMS),
                       cpuSeconds: ProbeMetrics.threadCPUSeconds() - cpu0,
                       footprintDeltaMB: ProbeMetrics.footprintMB() - foot0)
    }

    private static func percentOver(_ values: [Double], _ budget: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.filter { $0 > budget }.count) / Double(values.count) * 100
    }

    /// 一行读数进日志（与 `MobileProbeRig.report` 同形）。
    static func report(_ label: String, _ r: Reading) {
        print(String(format: "[%@] load=%.0fs sleep=%d/%d(%.2f) ticks=%d/%d(%.2f) "
                     + "p50=%.3fms p95=%.3fms max=%.3fms over-%.2f=%.1f%% over-8.33=%.1f%% "
                     + "cpu=%.3fs footprint+=%.1fMB",
                     label, r.seconds, r.sleepBeats, r.idealSleepBeats, r.sleepRatio,
                     r.displayTicks, r.idealDisplayTicks, r.displayRatio,
                     r.p50, r.p95, r.max, r.budgetMS, r.overBudgetPct, r.overStrictPct,
                     r.cpuSeconds, r.footprintDeltaMB))
    }
}

// MARK: - 终端「吃进了多少输出」的可观测计数

/// 一个会话的终端视图到底消费了多少输出 —— 判「非活动 tab 是不是还在全量渲染」的判据。
///
/// `MobileTerminalController.outputBuffer` 是 `private`，`@testable` 也够不到；
/// 但 SwiftTerm 的 `Terminal` 是公开的，两个计数随 `feed` 单调推进：
/// - `getTopVisibleRow()`：滚出屏幕（进 scrollback）的行号，喂得越多越大；
/// - `getCursorLocation().y`：scrollback 还没填满时靠它推进。
///
/// 两者相加当一个「已消费行数」的下界代理。**只比同轮的相对值**。
@MainActor
enum MobileTerminalConsumption {

    struct Count: Sendable, Equatable {
        let topRow: Int
        let cursorY: Int
        /// 单调推进的合成计数。
        var advanced: Int { topRow + cursorY }
    }

    static func read(_ controller: MobileTerminalController) -> Count {
        guard let view = controller.terminalView else { return Count(topRow: 0, cursorY: 0) }
        let terminal = view.getTerminal()
        return Count(topRow: terminal.getTopVisibleRow(), cursorY: terminal.getCursorLocation().y)
    }

    /// 读一屏会话的消费计数（同序）。
    static func read(_ tabs: [TermTab]) -> [Count] { tabs.map { read($0.controller) } }
}
