import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// M10 的回归用例（模拟器可跑，不挂 `UTERM_MEASURE`）：App 在后台时带标题的输出不能把 Ghostty 的解析卡住，
/// 排队要有上界，回前台要在限定时间里补出最新画面，且画面与影子终端一致。
///
/// 单元测试宿主不能真的退后台，和 `GhosttyMeasureProbeTests.testM10Background` 一样模拟：发
/// `UIApplication.didEnterBackgroundNotification`（GhosttyKit 的生命周期监听据此停 tick）+ `setSurfaceVisible(false)`；
/// 回前台发 `willEnterForeground` + `didBecomeActive` + `setSurfaceVisible(true)`。进程不会被挂起、主线程照常转，
/// 与真后台里靠 `BGContinuedProcessingTask` 续命时是同一情形。
@MainActor
final class GhosttyBackgroundTests: XCTestCase {
    /// surface 没解析完的字节的上界：闸门高水位 1 MiB + 一片 64 KiB，再留一点余量。
    private static let pendingBound = (1 << 20) + (64 << 10) + 4096

    /// 一个带 OSC 0 标题的 Claude 帧。语料里的帧画完停在自己的最后一行、下一帧再上移 6 行，每帧会往上爬一行；
    /// 这里补一个换行让它原地重画（不然后面的帧会把上面的标记行盖掉）。
    private func claude(_ n: Int, cols: Int) -> Data {
        Data(("\u{1B}]0;\(["✢", "✳", "✶", "✻", "✽"][n % 5]) Claude Code · 第 \(n) 帧\u{07}"
            + TerminalSpikeCorpus.claudeFrame(n, cols: cols) + "\r\n").utf8)
    }

    /// 测试进程里第一次用到这个类的时刻。
    private static let firstUse = CACurrentMediaTime()

    /// 真机上宿主 App 刚启动的头两秒里，系统还会发一次真的 `willEnterForeground`（启动时场景从后台转前台）。
    /// 它要是落在用例的「假后台」阶段里，bridge 会照规矩回放、切回实时，用例的前提就不成立了
    ///（Duo 上实测：假后台通知后 0.8 s 被翻回前台）。所以第一次进假后台前先等启动那一阵过去。模拟器上没见过，等一下也无妨。
    private func waitForLaunchToSettle() async throws {
        while CACurrentMediaTime() - Self.firstUse < 3 || UIApplication.shared.applicationState != .active {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func enterBackground(_ bridge: GhosttyTerminalBridge) {
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        bridge.view.setSurfaceVisible(false)
    }

    private func enterForeground(_ bridge: GhosttyTerminalBridge) {
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        bridge.view.setSurfaceVisible(true)
    }

    /// 同步卡住主线程（异步上下文里不能直接 `Thread.sleep`）。
    private func blockMainThread(seconds: Double) {
        usleep(useconds_t(seconds * 1_000_000))
    }

    /// surface 的视口与影子终端逐行相同（行尾空白与 `readViewportText` 的 spacer head 读法缺陷不算，见 `GhosttyViewportDiff`）。
    private func assertSurfaceMatchesShadow(_ host: GhosttyProbeHost, _ message: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        if let difference = GhosttyViewportDiff.firstDifference(surface: host.viewportText, shadow: host.bridge.shadow.viewportText()) {
            XCTFail("\(message)：surface 与影子终端不一致，\(difference)", file: file, line: line)
        }
    }

    /// 后台持续灌带标题的 Claude 帧 + 2 MB 洪流：解析不停、排队有上界；回前台限时补出最新画面，且与影子一致。
    func testBackgroundOutputKeepsParsingAndCatchesUpOnForeground() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 393, height: 760))
        defer { host.close() }
        try await host.waitUntilReady()
        let bridge = host.bridge
        let titles = TitleSink()
        bridge.view.delegate = titles
        let backend = ScriptedBackend()
        try await backend.connect()
        bridge.bind(backend)
        defer { bridge.unbind() }
        let cols = host.grid.cols, rows = host.grid.rows
        XCTAssertEqual(bridge.shadow.size.cols, cols, "影子终端的网格要跟着 surface 的终端")
        XCTAssertEqual(bridge.shadow.size.rows, rows)

        // 前台：一屏内容 + 几帧，确认通路是好的。
        backend.yield(Data(("\u{1B}[2J\u{1B}[H" + TerminalSpikeCorpus.screen(rows: rows - 8, salt: 1) + "\r\n\r\n\r\n\r\n\r\n\r\n\r\n").utf8))
        for n in 0..<3 { backend.yield(claude(n, cols: cols)) }
        let foregroundOK = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.session.pendingOutputByteCount == 0 && host.viewportText.contains("Thinking")
        }
        XCTAssertTrue(foregroundOK, "前台输出没上屏")
        assertSurfaceMatchesShadow(host, "前台")
        // 标题是主线程 tick 时才送到的，比「解析完」晚一点：等这 3 帧的标题到齐再数。
        let titlesArrived = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) { titles.last.contains("第 2 帧") }
        XCTAssertTrue(titlesArrived, "前台的标题应当到 surface：\(titles.last)")
        let titlesInForeground = titles.count

        try await waitForLaunchToSettle()
        enterBackground(bridge)
        // 进后台再恢复现场，别把宿主留在「后台」状态影响后面的用例。
        var restored = false
        defer { if !restored { enterForeground(bridge) } }
        XCTAssertTrue(bridge.isAppInBackground)
        XCTAssertFalse(bridge.router.isFeedingSurface, "进后台后 surface 不该再吃字节")

        // 后台：400 帧带标题（远超 app mailbox 的 64 格），再来 2 MB 洪流，最后清屏画一屏确定的内容 + 标记 + 几帧。
        var maxPending = 0
        var sent = 0
        func send(_ data: Data) { sent += data.count; backend.yield(data) }
        for n in 0..<400 {
            send(claude(n + 10, cols: cols))
            if n % 20 == 0 {
                try await Task.sleep(for: .milliseconds(10))
                maxPending = max(maxPending, bridge.session.pendingOutputByteCount)
            }
        }
        let flood = TerminalSpikeCorpus.flood(bytes: 2 * 1024 * 1024)
        for start in stride(from: 0, to: flood.count, by: 16 * 1024) {
            send(flood.subdata(in: start..<min(flood.count, start + 16 * 1024)))
        }
        let marker = "BACK-MARKER-\(Int.random(in: 1000...9999))"
        send(Data(("\u{1B}[2J\u{1B}[H" + TerminalSpikeCorpus.screen(rows: rows - 9, salt: 3)
            + "\r\n\(marker)\r\n\r\n\r\n\r\n\r\n\r\n\r\n").utf8))
        for n in 0..<3 { send(claude(n + 500, cols: cols)) }
        // 给入站 2 秒把这些吃完，期间盯着排队。
        let settleUntil = CACurrentMediaTime() + 2
        while CACurrentMediaTime() < settleUntil {
            maxPending = max(maxPending, bridge.session.pendingOutputByteCount)
            try await Task.sleep(for: .milliseconds(20))
        }
        let pendingInBackground = bridge.session.pendingOutputByteCount
        let background = bridge.router.currentStats
        XCTAssertTrue(bridge.isAppInBackground, "假后台阶段里 bridge 被翻回了前台（系统发了真的 willEnterForeground？）")
        XCTAssertEqual(background.replays, 0, "后台阶段不该有回放")
        print("GHBG background: sent=\(sent) max-pending=\(maxPending) pending-after-settle=\(pendingInBackground) "
            + "shadow-only=\(background.shadowOnlyBytes) dropped=\(background.droppedSurfaceBytes) shadow-rows=\(bridge.shadow.totalRows) "
            + "shadow-resident=\(bridge.shadow.residentBytes) titles-in-bg=\(titles.count - titlesInForeground)")
        XCTAssertLessThanOrEqual(maxPending, Self.pendingBound, "后台时 surface 的未解析字节没有上界（解析卡住、字节在排队）")
        XCTAssertLessThanOrEqual(pendingInBackground, Self.pendingBound, "后台停稳后仍有大量字节没解析")
        // 解析没停：后台发的每个字节都进了影子终端，最新的标记在影子的屏上。
        XCTAssertEqual(background.shadowOnlyBytes, sent, "后台的输出应当全部（且只）进影子终端")
        XCTAssertTrue(bridge.shadow.viewportText().contains(marker), "后台时影子终端没解析到最新输出")
        XCTAssertEqual(titles.count, titlesInForeground, "后台时不该有标题进 app mailbox")

        // 回前台：限时补出最新画面。
        let back = CACurrentMediaTime()
        enterForeground(bridge)
        restored = true
        var caughtUpAt: Double?
        while CACurrentMediaTime() - back < 5, caughtUpAt == nil {
            if bridge.session.pendingOutputByteCount == 0, host.viewportText.contains(marker) { caughtUpAt = CACurrentMediaTime() }
            else { try await Task.sleep(for: .milliseconds(2)) }
        }
        let catchUpMS = caughtUpAt.map { ($0 - back) * 1000 }
        let foreground = bridge.router.currentStats
        print("GHBG foreground catch-up: \(catchUpMS.map { String(format: "%.0f ms", $0) } ?? "never") "
            + "replays=\(foreground.replays) snapshot=\(foreground.lastSnapshotBytes)B replay=\(foreground.lastReplayBytes)B "
            + String(format: "build=%.1fms", foreground.lastReplayBuildSeconds * 1000)
            + " (\(foreground.lastReplayPhases)) unwrapped=\(foreground.lastReplayUnwrapped) grid=\(cols)x\(rows)")
        let took = try XCTUnwrap(catchUpMS, "回前台 5 秒内没补出最新画面")
        XCTAssertLessThan(took, 500, "回前台补出最新画面太慢")
        XCTAssertEqual(foreground.replays, 1, "回前台应当回放一次影子的快照")
        XCTAssertNil(foreground.lastReplayError)
        XCTAssertTrue(foreground.lastReplayVerified, "回放流发出去之前的自查没过")
        XCTAssertTrue(bridge.router.isFeedingSurface)
        assertSurfaceMatchesShadow(host, "回前台后")
        // 回放带回了标题（一条），没有把后台那 400 多条逐条补发。
        let titleOK = await MobileFakeTerminal.waitUntil(timeout: .seconds(2)) { titles.last.contains("第 502 帧") }
        XCTAssertTrue(titleOK, "回前台后标题应当是最新的：\(titles.last)")
        XCTAssertLessThanOrEqual(titles.count - titlesInForeground, 3, "回放不该把后台的标题逐条补发")
        // 回滚也带回来了（两边都按 1 万行封顶，按页裁，行数不要求逐行相等）。滚动条回报是渲染时才出的，等它一下。
        await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) { (titles.scrollbar?.total ?? 0) > UInt64(rows * 10) }
        print("GHBG scrollback: surface-rows=\(titles.scrollbar?.total ?? 0) shadow-rows=\(bridge.shadow.totalRows)")
        XCTAssertGreaterThan(titles.scrollbar?.total ?? 0, UInt64(rows * 10), "回放应当把回滚也带回 surface")

        // 之后接着吃实时字节。
        let live = "LIVE-MARKER-\(Int.random(in: 1000...9999))"
        backend.yield(Data("\r\n\(live)".utf8))
        backend.yield(claude(600, cols: cols))
        let liveOK = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            host.viewportText.contains(live) && titles.last.contains("第 600 帧")
        }
        XCTAssertTrue(liveOK, "回前台后的实时输出没上屏")
        XCTAssertEqual(bridge.session.pendingOutputByteCount, 0)
        assertSurfaceMatchesShadow(host, "回前台后续播")
    }

    /// 宽屏（Duo 内屏那么宽）+ 行尾落宽字符的内容留在屏上：回前台后 surface 与影子仍然一致。
    /// 这种屏上 `readViewportText` 的 spacer head 读法缺陷会出现（两边直接比文字会不等），比较时要按 `GhosttyViewportDiff` 容忍它。
    func testWideGridWithWideCharactersAtLineEndCatchesUpConsistently() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 669, height: 760))
        defer { host.close() }
        try await host.waitUntilReady()
        let bridge = host.bridge
        let backend = ScriptedBackend()
        try await backend.connect()
        bridge.bind(backend)
        defer { bridge.unbind() }
        let cols = host.grid.cols
        backend.yield(Data("$ tail -f app.log\r\n".utf8))
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.session.pendingOutputByteCount == 0 && host.viewportText.contains("tail -f")
        }
        XCTAssertTrue(ready, "前台输出没上屏")

        try await waitForLaunchToSettle()
        enterBackground(bridge)
        var restored = false
        defer { if !restored { enterForeground(bridge) } }
        // 1 MB 洪流（每行以「说明 ok」结尾，折行位置随宽度变），再来一批把宽字符顶到每一个列位置上的行，最后一屏就是它们。
        let flood = TerminalSpikeCorpus.flood(bytes: 1024 * 1024)
        for start in stride(from: 0, to: flood.count, by: 16 * 1024) {
            backend.yield(flood.subdata(in: start..<min(flood.count, start + 16 * 1024)))
        }
        var lines = ""
        for pad in 0..<(cols + 4) { lines += String(repeating: "x", count: pad) + "宽字符落在行尾 \(pad)\r\n" }
        let marker = "WIDE-MARKER-\(Int.random(in: 1000...9999))"
        backend.yield(Data((lines + marker).utf8))
        let fed = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { bridge.shadow.viewportText().contains(marker) }
        XCTAssertTrue(fed, "后台时影子终端没解析到最新输出")
        XCTAssertEqual(bridge.session.pendingOutputByteCount, 0)

        enterForeground(bridge)
        restored = true
        let caughtUp = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            bridge.session.pendingOutputByteCount == 0 && host.viewportText.contains(marker)
        }
        XCTAssertTrue(caughtUp, "回前台没补出最新画面")
        let stats = bridge.router.currentStats
        let naive = GhosttyViewportDiff.trimmedLines(host.viewportText) == GhosttyViewportDiff.trimmedLines(bridge.shadow.viewportText())
        print("GHBG wide: grid=\(cols)x\(host.grid.rows) naive-equal=\(naive) replays=\(stats.replays) unwrapped=\(stats.lastReplayUnwrapped) "
            + "verified=\(stats.lastReplayVerified) snapshot=\(stats.lastSnapshotBytes)B "
            + String(format: "build=%.1fms", stats.lastReplayBuildSeconds * 1000) + " (\(stats.lastReplayPhases))")
        XCTAssertEqual(stats.replays, 1)
        XCTAssertTrue(stats.lastReplayVerified, "回放流发出去之前的自查没过")
        assertSurfaceMatchesShadow(host, "宽屏回前台后")
    }

    /// 后台没来过输出就不回放：surface 原样接着用（回滚位置、Kitty 图片都不动）。
    func testForegroundWithoutBackgroundOutputDoesNotReplay() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 393, height: 600))
        defer { host.close() }
        try await host.waitUntilReady()
        let bridge = host.bridge
        host.feedAndWait("$ echo hi\r\nhi\r\n$ ")
        try await waitForLaunchToSettle()
        enterBackground(bridge)
        try await Task.sleep(for: .milliseconds(100))
        enterForeground(bridge)
        bridge.router.waitForCatchUp()
        XCTAssertEqual(bridge.router.currentStats.replays, 0)
        XCTAssertTrue(bridge.router.isFeedingSurface)
        host.feedAndWait("echo again\r\n")
        XCTAssertTrue(host.viewportText.contains("echo again"))
        assertSurfaceMatchesShadow(host, "没回放")
    }

    /// 查询的应答：前台由 surface 答，后台由影子终端答，各答一次，内容相同。
    func testQueriesAreAnsweredOnceInForegroundAndBackground() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 393, height: 600))
        defer { host.close() }
        try await host.waitUntilReady()
        let bridge = host.bridge
        let backend = RecordingBackend()
        bridge.bind(backend)
        defer { bridge.unbind() }
        // DA1、DA2、光标位置、背景色查询、XTVERSION。
        let queries = "\u{1B}[c\u{1B}[>c\u{1B}[6n\u{1B}]11;?\u{07}\u{1B}[>q"
        func replies(after send: () -> Void) async -> String {
            let before = await backend.written.count
            send()
            // 等应答到齐并停稳（surface 的应答在 termio 线程上异步产生）。
            var last = -1, stableSince = CACurrentMediaTime()
            let deadline = CACurrentMediaTime() + 3
            while CACurrentMediaTime() < deadline {
                let now = await backend.written.count
                if now != last { last = now; stableSince = CACurrentMediaTime() }
                if now > before, CACurrentMediaTime() - stableSince > 0.3 { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let all = await backend.written
            return String(decoding: all.suffix(from: before), as: UTF8.self)
                .replacingOccurrences(of: "\u{1B}", with: "\\e").replacingOccurrences(of: "\u{07}", with: "\\a")
        }
        backend.yield(Data("\u{1B}[2J\u{1B}[3;5H".utf8))
        let foreground = await replies { backend.yield(Data(queries.utf8)) }

        try await waitForLaunchToSettle()
        enterBackground(bridge)
        var restored = false
        defer { if !restored { enterForeground(bridge) } }
        let background = await replies { backend.yield(Data(queries.utf8)) }
        enterForeground(bridge)
        restored = true
        bridge.router.waitForCatchUp()
        bridge.session.waitForPendingOutput()
        // 回放本身不该引出应答。
        try await Task.sleep(for: .milliseconds(400))
        let afterReplay = await replies { backend.yield(Data("\u{1B}[6n".utf8)) }
        print("GHBG replies foreground=\(foreground)\nGHBG replies background=\(background)\nGHBG replies after-replay=\(afterReplay)")
        XCTAssertTrue(foreground.contains("\\e[?62;"), "前台应当由 surface 答 DA1：\(foreground)")
        XCTAssertTrue(foreground.contains("\\e[3;5R"), "前台应当答光标位置：\(foreground)")
        XCTAssertEqual(background, foreground, "后台由影子终端答的应当和 surface 答的一样")
        XCTAssertEqual(afterReplay, "\\e[3;5R", "回前台后一个查询只该有一份应答，回放不该引出应答")
    }

    /// 前台的闸门：主线程卡住（没人 tick，带标题的输出会让 surface 解析停住）时，surface 的未解析字节到高水位
    /// 入站就停下不再取，主线程恢复后一个字节不丢。
    func testForegroundBacklogIsBoundedWhileMainThreadIsBlocked() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 393, height: 760))
        defer { host.close() }
        try await host.waitUntilReady()
        let bridge = host.bridge
        let backend = ScriptedBackend()
        try await backend.connect()
        bridge.bind(backend)
        defer { bridge.unbind() }
        let cols = host.grid.cols, rows = host.grid.rows

        // 约 3 MB 带标题的帧（每帧一条标题），分块给。
        var payload = Data()
        var n = 0
        while payload.count < 3 * 1024 * 1024 { payload.append(claude(n, cols: cols)); n += 1 }
        let marker = "GATE-MARKER-\(Int.random(in: 1000...9999))"
        let tail = Data(("\u{1B}[2J\u{1B}[H" + TerminalSpikeCorpus.screen(rows: rows - 9, salt: 5) + "\r\n\(marker)\r\n").utf8)

        let sampler = PendingSampler(session: bridge.session)
        sampler.start()
        for start in stride(from: 0, to: payload.count, by: 32 * 1024) {
            backend.yield(payload.subdata(in: start..<min(payload.count, start + 32 * 1024)))
        }
        backend.yield(tail)
        // 主线程卡 400 ms：这期间没人 tick，app mailbox 64 格填满后 surface 的解析停住。
        blockMainThread(seconds: 0.4)
        let maxWhileBlocked = sampler.max
        let done = await MobileFakeTerminal.waitUntil(timeout: .seconds(20)) {
            bridge.session.pendingOutputByteCount == 0 && host.viewportText.contains(marker)
        }
        sampler.stop()
        let stats = bridge.router.currentStats
        print("GHBG gate: payload=\(payload.count) max-pending-while-blocked=\(maxWhileBlocked) max-pending=\(sampler.max) waits=\(stats.backpressureWaits)")
        XCTAssertTrue(done, "主线程恢复后输出没解析完")
        XCTAssertGreaterThan(stats.backpressureWaits, 0, "surface 积压时入站应当停下等过")
        XCTAssertLessThanOrEqual(sampler.max, Self.pendingBound, "前台 surface 的未解析字节超过了闸门的上界")
        XCTAssertEqual(stats.replays, 0, "前台积压靠闸门等，不回放")
        assertSurfaceMatchesShadow(host, "闸门放行后")
    }
}

/// surface 收到的标题与滚动条回报。
@MainActor
private final class TitleSink: TerminalSurfaceTitleDelegate, TerminalSurfaceScrollbarDelegate {
    var count = 0
    var last = ""
    var scrollbar: TerminalScrollbar?
    func terminalDidChangeTitle(_ title: String) { count += 1; last = title }
    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) { self.scrollbar = scrollbar }
}

/// 后台线程上每 2 ms 读一次会话的未解析字节，记最大值（主线程被卡住时也能量）。
private nonisolated final class PendingSampler: @unchecked Sendable {
    private let session: InMemoryTerminalSession
    private let lock = NSLock()
    private var peak = 0
    private var running = false

    init(session: InMemoryTerminalSession) { self.session = session }

    var max: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        Thread.detachNewThread { [self] in
            while true {
                let pending = session.pendingOutputByteCount
                lock.lock()
                peak = Swift.max(peak, pending)
                let keepGoing = running
                lock.unlock()
                if !keepGoing { return }
                usleep(2000)
            }
        }
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }
}

/// 输出可控、记下所有写入的后端。
private actor RecordingBackend: TerminalBackend {
    nonisolated let outputStream: AsyncStream<Data>
    nonisolated let exitStream: AsyncStream<Void>
    private nonisolated let output: AsyncStream<Data>.Continuation
    private let exit: AsyncStream<Void>.Continuation
    private(set) var written = Data()

    init() {
        var out: AsyncStream<Data>.Continuation!
        outputStream = AsyncStream(bufferingPolicy: .unbounded) { out = $0 }
        output = out
        var ex: AsyncStream<Void>.Continuation!
        exitStream = AsyncStream { ex = $0 }
        exit = ex
    }

    nonisolated func yield(_ data: Data) { output.yield(data) }
    func connect() async throws {}
    func write(_ data: Data) async { written.append(data) }
    func resize(cols: UInt16, rows: UInt16) async {}
    func close() async { output.finish(); exit.finish() }
}
