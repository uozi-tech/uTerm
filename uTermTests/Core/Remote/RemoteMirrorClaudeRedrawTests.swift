import XCTest
import SwiftUI
@testable import uTerm

/// 真机回归（2.0.0 / build 1090，iPhone Duo）：手机远控 Mac 上跑着的 Claude Code（经典界面：输入框 + 状态行，用相对光标
/// 移动和擦行重画），转屏 / Duo 开合之后，手机上打的字跑到屏幕左上角、设置里改数值留下 `400k5` 这种残字、状态行出现两遍。
///
/// 链路全是生产代码：Mac 端是一个有真 Ghostty surface 的会话（窗口里，钉尺寸走视图 → 引擎 IO 线程 → 影子），镜像走
/// `TerminalMirrorTap` 的订阅者（快照段过一遍线上的编码），手机端是共享的输出泵（`followsSnapshotGrid`，同真机远控标签）
/// 接一个「画面」。画面用一台影子终端代替 GhosttyKit surface（同一棵打过补丁的源码树编的 vt，M4：逐格一致），
/// 它的网格由测试改（转屏），改了之后照真机的顺序：先报给泵（`surfaceGridDidChange`），再把尺寸发给 Mac。
/// 程序是一个照 Claude Code 2.1.322 实录字节写的渲染器（`ClaudeClassicRenderer`），只在 Mac 的 PTY 改了尺寸之后才按新尺寸画。
/// 第三方是一台参考终端：吃同一串 PTY 字节，在 PTY 改尺寸的那一刻改网格（理想的终端）。
@MainActor
final class RemoteMirrorClaudeRedrawTests: XCTestCase {

    // MARK: 程序：照 Claude Code 2.1.322 的经典界面写的渲染器

    /// 实录（`claude` 跑在 PTY 里，见迁移日志）：一帧画完光标停在输入框里（`ESC[nC ESC[nA`）；之后每次更新先从停的位置回到
    /// 画面下面那一行（`ESC[nD ESC[nB`），对变了的行 `\r ESC[nC ESC[kA` 写后半段 + `ESC[K`，再用换行走回来，最后停回输入框；
    /// 全在 DEC 2026 里、藏着光标。收到 SIGWINCH 时从左上角起按新的行数逐行擦掉、整帧重画。
    final class ClaudeClassicRenderer {
        private(set) var cols: Int
        private(set) var rows: Int
        private var drawn: [String] = []
        private var seconds = 0
        private var input = ""
        private var context = "400k"
        private let transcript: [String]

        init(cols: Int, rows: Int, transcriptLines: Int) {
            self.cols = cols
            self.rows = rows
            transcript = (0..<transcriptLines).map { "  line \($0): the output pump feeds the shadow first, then the surface" }
        }

        private var rule: String { String(repeating: "─", count: cols) }

        private func clip(_ line: String) -> String {
            line.count <= cols ? line : String(line.prefix(max(0, cols - 1))) + "…"
        }

        private var lines: [String] {
            let body = ["Claude Code v2.1.322", "Fable 5.2 with high effort - Claude Ultra", ""] + transcript
                + ["* Thinking... (\(seconds)s - \(seconds * 37) tokens)", ""]
            return (body + [rule, "❯ " + input, rule,
                            "  >> auto mode on (shift+tab to cycle) - esc to interrupt",
                            "  context compression: \(context)"]).map(clip)
        }

        /// 停光标的位置：输入框那一行（离画面下面那一行几行）、第几列。
        private var park: (up: Int, col: Int) {
            let all = lines
            return (all.count - all.firstIndex { $0.hasPrefix("❯ ") }!, min(cols - 1, 2 + input.count))
        }

        private func moves(_ count: Int, _ letter: String) -> String { count > 0 ? "\u{1B}[\(count)\(letter)" : "" }

        /// 整帧（启动与 SIGWINCH）：从左上角逐行擦掉一屏，再从左上角写整帧。
        func fullRedraw(rows newRows: Int? = nil, cols newCols: Int? = nil, first: Bool = false) -> Data {
            let before = park
            if let newRows { rows = newRows }
            if let newCols { cols = newCols }
            var out = "\u{1B}[?2026h\u{1B}[?25l"
            if first { out += "\u{1B}[2J" } else { out += moves(before.col, "D") + moves(before.up, "B") }
            out += "\u{1B}[H" + String(repeating: "\u{1B}[2K\u{1B}[1B", count: rows) + "\u{1B}[H"
            let all = lines
            out += all.joined(separator: "\r\n") + "\r\n"
            drawn = all
            let after = park
            out += moves(after.col, "C") + moves(after.up, "A") + "\u{1B}[?25h\u{1B}[?2026l"
            return Data(out.utf8)
        }

        /// 一次增量更新：思考计时走一秒，可能还打了一个字、改了一次数值。
        func update(typing: Character? = nil, context newContext: String? = nil) -> Data {
            let before = park
            seconds += 1
            if let typing { input.append(typing) }
            if let newContext { context = newContext }
            let all = lines
            precondition(all.count == drawn.count, "渲染器只改行内容，不改行数")
            var out = "\u{1B}[?2026h\u{1B}[?25l" + moves(before.col, "D") + moves(before.up, "B")
            for (index, line) in all.enumerated() where line != drawn[index] {
                let old = Array(drawn[index]), new = Array(line)
                let common = zip(old, new).prefix { $0 == $1 }.count
                let up = all.count - index
                out += "\r" + moves(common, "C") + moves(up, "A") + String(new[common...]) + "\u{1B}[K"
                out += String(repeating: "\r\n", count: up)
            }
            drawn = all
            let after = park
            out += moves(after.col, "C") + moves(after.up, "A") + "\u{1B}[?25h\u{1B}[?2026l"
            return Data(out.utf8)
        }
    }

    // MARK: 手机的画面：一台影子终端代替 GhosttyKit surface

    nonisolated final class StandInSurface: TerminalSurfaceSink, @unchecked Sendable {
        let terminal: ShadowTerminal
        private let lock = NSLock()
        private var grid: (cols: Int, rows: Int)

        init(cols: Int, rows: Int) {
            grid = (cols, rows)
            terminal = ShadowTerminal(cols: UInt16(cols), rows: UInt16(rows),
                                      options: TerminalScrollbackLimits(lines: TerminalSettings.read().scrollback).shadowOptions)
        }

        /// 转屏：终端改网格（文字按新宽度重新折行），再像 IO 线程那样报出新网格。
        func resize(cols: Int, rows: Int) {
            terminal.resize(cols: UInt16(cols), rows: UInt16(rows))
            lock.withLock { grid = (cols, rows) }
        }

        var surfaceGridSize: (cols: Int, rows: Int)? { lock.withLock { grid } }
        func receive(_ data: Data) { terminal.feed(data) }
        func receiveReplay(_ data: Data) { terminal.feed(data) }
        func discardPendingOutput() -> Int { 0 }
        func setOutputBacklogHandler(highWater: Int, lowWater: Int, _ handler: (@Sendable (Bool) -> Void)?) {}
    }

    // MARK: 搭台

    private struct Rig {
        let session: TerminalSession
        let backend: MockBackend
        let host: NSHostingView<RemoteControlledTerminal>?
        let window: NSWindow?
        var subscriber: TerminalMirrorTap.Subscriber
        let surface: StandInSurface
        let phoneShadow: ShadowTerminal
        let phonePump: TerminalOutputPump
        let reference: ShadowTerminal
        let claude: ClaudeClassicRenderer
        var assembly = SnapshotAssembly()
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// `hosted`：Mac 端的会话挂在窗口里、有真的 Ghostty surface（钉尺寸走视图 → 引擎 IO 线程 → 影子）；false 时会话没有
    /// 画面（标签从没露出过），钉尺寸当场改影子和 PTY，字节也由测试直接喂进 Mac 的泵（每一步都确定）。
    private func makeRig(cols: Int, rows: Int, transcriptLines: Int, hosted: Bool = true) async throws -> Rig {
        let session = TerminalSession()
        session.attentionSink = { _ in }
        var host: NSHostingView<RemoteControlledTerminal>?
        var window: NSWindow?
        if hosted {
            let rect = NSRect(x: 0, y: 0, width: 900, height: 700)
            let view = NSHostingView(rootView: RemoteControlledTerminal(session: session))
            view.frame = rect
            window = ProbeWindow.make(contentRect: rect, contentView: view, placement: .transparentOnScreen)
            view.layoutSubtreeIfNeeded()
            host = view
            let bridge = session.ghostty
            let live = await waitUntil(10) { bridge.isLive && bridge.grid != nil }
            XCTAssertTrue(live, "Ghostty surface 没就绪")
        }
        let backend = MockBackend()
        await session.connect(using: backend)
        // 手机接入：钉尺寸，等 Mac 的网格、PTY 都到位（同 `RemoteHostConnection.attach`）。
        session.pinRemoteGrid(cols: cols, rows: rows, controller: "测试 iPhone")
        host?.layoutSubtreeIfNeeded()
        let pinned = await waitUntil(5) {
            let last = await backend.resizes.last
            return session.shadow.size == (cols, rows) && last.map { Int($0.cols) == cols && Int($0.rows) == rows } ?? false
        }
        XCTAssertTrue(pinned, "Mac 没钉到 \(cols)×\(rows)：影子 \(session.shadow.size)")
        let shadow = session.shadow
        let subscriber = session.mirrorTap.subscribe(id: UUID(), firstSnapshotWhen: { shadow.size == (cols, rows) },
                                                     timeout: RemoteConstants.attachGridSettleTimeout) {}
        let surface = StandInSurface(cols: cols, rows: rows)
        let options = TerminalScrollbackLimits(lines: TerminalSettings.read().scrollback).shadowOptions
        let phoneShadow = ShadowTerminal(cols: UInt16(cols), rows: UInt16(rows), options: options)
        let phonePump = TerminalOutputPump(shadow: phoneShadow, surface: surface)
        phonePump.followsSnapshotGrid = true
        phonePump.setSurfaceFeeding(true)
        phonePump.waitForCatchUp()
        let reference = ShadowTerminal(cols: UInt16(cols), rows: UInt16(rows), options: options)
        let claude = ClaudeClassicRenderer(cols: cols, rows: rows, transcriptLines: transcriptLines)
        return Rig(session: session, backend: backend, host: host, window: window, subscriber: subscriber,
                   surface: surface, phoneShadow: phoneShadow, phonePump: phonePump, reference: reference, claude: claude)
    }

    /// 取走订阅者攒着的全部数据交给手机端的泵：快照段过一遍线上的编码再拼回，字节原样。
    private func drain(_ rig: Rig) {
        while let chunk = rig.subscriber.take(maxBytes: RemoteConstants.maxOutputChunkBytes) {
            switch chunk {
            case .snapshot(let piece, let isFirst, let isLast):
                let wire = RemoteTerminalSnapshotPiece.encode(piece, isFirst: isFirst, isLast: isLast)
                guard let decoded = RemoteTerminalSnapshotPiece.decode(wire) else { return XCTFail("快照段解不开") }
                if let snapshot = rig.assembly.append(decoded.data, isFirst: decoded.isFirst, isLast: decoded.isLast) {
                    rig.phonePump.applySnapshot(snapshot)
                }
            case .output(let bytes):
                rig.phonePump.route(bytes)
            }
        }
    }

    /// 程序写一段：进 Mac 的 PTY（假后端）、也进参考终端。
    private func program(_ rig: Rig, _ bytes: Data, emitted: inout Int) async {
        rig.reference.feed(bytes)
        emitted += bytes.count
        await rig.backend.emitOutput(bytes)
    }

    /// 程序这一拍：PTY 的尺寸变了（SIGWINCH）就按新尺寸整帧重画，否则增量更新。
    private func programTick(_ rig: Rig, tick: Int, emitted: inout Int) async {
        let pty = await rig.backend.resizes.last.map { (Int($0.cols), Int($0.rows)) }
        if let pty, pty != (rig.claude.cols, rig.claude.rows) {
            // 理想的终端：在 PTY 改尺寸的那一刻改网格，之后才是程序按新尺寸画的字节。
            rig.reference.resize(cols: UInt16(pty.0), rows: UInt16(pty.1))
            // 程序看到新尺寸时，Mac 的影子必须已经换上它：否则这一帧先进旧网格、随后被重新折行（本回归的根因）。
            let mac = rig.session.shadow.size
            XCTAssertTrue(mac == pty, "PTY 已经是 \(pty.0)×\(pty.1)，Mac 影子还是 \(mac.cols)×\(mac.rows)")
            await program(rig, rig.claude.fullRedraw(rows: pty.1, cols: pty.0), emitted: &emitted)
            return
        }
        let typed: Character? = tick % 3 == 0 ? Character(UnicodeScalar(UInt8(97 + tick % 26))) : nil
        let contexts = ["400k", "40k", "4k", "1000k", "90k"]
        let context: String? = tick % 7 == 0 ? contexts[(tick / 7) % contexts.count] : nil
        await program(rig, rig.claude.update(typing: typed, context: context), emitted: &emitted)
    }

    /// 等全部静下来：Mac 吃完程序写的字节、手机收完、泵不再停画等网格。
    private func settle(_ rig: Rig, base: Int, emitted: Int) async -> Bool {
        await waitUntil(5) {
            // 借一下 Mac 泵的锁：正喂到一半的那一片（影子吃了、还没交给订阅者）先走完。
            rig.session.outputPump.performWhileFeedingPaused {}
            self.drain(rig)
            rig.phonePump.waitForCatchUp()
            return rig.session.shadow.totalFedBytes >= base + emitted && rig.subscriber.pendingBytes == 0
                && !rig.phonePump.isHoldingForGrid
        }
    }

    /// 屏幕文字 + 光标（行、列）。
    private func screen(_ terminal: ShadowTerminal) -> String {
        let cursor = terminal.cursor
        return "\(terminal.size.cols)×\(terminal.size.rows) 光标 (\(cursor.y),\(cursor.x))\(cursor.pendingWrap ? " 待折行" : "")"
            + (terminal.isOnAlternateScreen ? " 备用屏" : "") + "\n" + terminal.viewportText()
    }

    private func compare(_ rig: Rig, _ label: String, into failures: inout [String]) {
        let reference = screen(rig.reference)
        let mac = screen(rig.session.shadow)
        let phone = screen(rig.surface.terminal)
        if mac != reference { failures.append("[\(label)] Mac 影子 ≠ 参考终端\n--- Mac\n\(mac)\n--- 参考\n\(reference)") }
        if phone != reference { failures.append("[\(label)] 手机画面 ≠ 参考终端\n--- 手机\n\(phone)\n--- 参考\n\(reference)") }
    }

    // MARK: 用例

    /// 转屏 / Duo 开合：Claude 一直在更新（思考计时、打字回显、改数值），手机网格（列和行一起）变，手机先改自己的画面、
    /// 再把尺寸发给 Mac；Mac 钉尺寸、PTY 跟着改，程序按新尺寸整帧重画。每次重画、之后再更新几拍，三方都要一致。
    func test_claude_redraw_survives_phone_grid_changes() async throws {
        let sizes: [(Int, Int)] = [(62, 30), (89, 22), (48, 40), (89, 32), (120, 18), (62, 30)]
        try await runRotation(sizes: sizes, transcriptLines: 6, label: "短对话")
    }

    /// 对话比屏幕高：整帧重画会把上面的行顶进回滚区（Claude 的帧不全在屏上）。
    func test_claude_redraw_survives_phone_grid_changes_with_tall_frame() async throws {
        let sizes: [(Int, Int)] = [(62, 14), (89, 12), (48, 20), (89, 16), (120, 10)]
        try await runRotation(sizes: sizes, transcriptLines: 30, label: "长对话")
    }

    private func runRotation(sizes: [(Int, Int)], transcriptLines: Int, label: String) async throws {
        let rig = try await makeRig(cols: 89, rows: 32, transcriptLines: transcriptLines)
        defer { rig.session.dispose(); rig.window?.orderOut(nil); rig.phonePump.reset() }
        let base = rig.session.shadow.totalFedBytes
        var emitted = 0
        var failures: [String] = []
        await program(rig, rig.claude.fullRedraw(first: true), emitted: &emitted)
        for tick in 0..<6 { await programTick(rig, tick: tick, emitted: &emitted) }
        let started = await settle(rig, base: base, emitted: emitted)
        XCTAssertTrue(started, "起步没静下来")
        compare(rig, "\(label) 起步", into: &failures)

        var tick = 6
        for (cols, rows) in sizes {
            // 手机转屏：画面先改网格，报给泵；程序照常在出字。
            rig.surface.resize(cols: cols, rows: rows)
            rig.phonePump.surfaceGridDidChange()
            await programTick(rig, tick: tick, emitted: &emitted); tick += 1
            drain(rig)
            // 尺寸到 Mac：钉住、视图布局，引擎在 IO 线程上改网格，影子跟上、镜像重发快照、PTY 收到新尺寸。
            rig.session.pinRemoteGrid(cols: cols, rows: rows, controller: "测试 iPhone")
            rig.host?.layoutSubtreeIfNeeded()
            for _ in 0..<3 {
                await programTick(rig, tick: tick, emitted: &emitted); tick += 1
                drain(rig)
                try await Task.sleep(for: .milliseconds(8))
            }
            let ptyFollowed = await waitUntil(5) {
                let last = await rig.backend.resizes.last
                return last.map { Int($0.cols) == cols && Int($0.rows) == rows } ?? false
            }
            XCTAssertTrue(ptyFollowed, "PTY 没跟到 \(cols)×\(rows)")
            // 程序收到 SIGWINCH，整帧重画；再更新几拍。
            for _ in 0..<4 {
                await programTick(rig, tick: tick, emitted: &emitted); tick += 1
                drain(rig)
            }
            let settled = await settle(rig, base: base, emitted: emitted)
            XCTAssertTrue(settled, "\(cols)×\(rows) 没静下来")
            compare(rig, "\(label) 转到 \(cols)×\(rows)", into: &failures)
            if failures.count > 4 { break }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n\n"))
    }

    // MARK: 不建窗口：快照截在帧中间（重连）、手机标签藏起来再露出、Mac 迟迟没跟上

    /// 程序写一段（不建窗口的台子）：直接进 Mac 的泵（同步，影子和镜像都已经吃到），也进参考终端。
    private func write(_ rig: Rig, _ bytes: Data) {
        rig.reference.feed(bytes)
        rig.session.outputPump.route(bytes)
    }

    private func syncDrain(_ rig: Rig) {
        drain(rig)
        rig.phonePump.waitForCatchUp()
    }

    /// 尺寸到了 Mac（不建窗口：钉尺寸当场改影子、发快照、改 PTY），程序收到 SIGWINCH 整帧重画。
    private func macFollows(_ rig: Rig, cols: Int, rows: Int) {
        rig.session.pinRemoteGrid(cols: cols, rows: rows, controller: "测试 iPhone")
        rig.reference.resize(cols: UInt16(cols), rows: UInt16(rows))
        write(rig, rig.claude.fullRedraw(rows: rows, cols: cols))
    }

    private static let contexts = ["400k", "40k", "4k", "1000k", "90k"]

    private func update(_ rig: Rig, _ step: Int) -> Data {
        rig.claude.update(typing: step % 2 == 0 ? Character(UnicodeScalar(UInt8(97 + step % 26))) : nil,
                          context: step % 5 == 0 ? Self.contexts[(step / 5) % Self.contexts.count] : nil)
    }

    /// 重连 / 接入时快照可以截在任何字节上：DEC 2026 一帧的中间、转义序列的中间、UTF-8 字符（`❯`、`─`）的中间。
    /// 每一帧换一个截断位置，换一个订阅者（新连接从快照开始，之前没发出去的字节丢了），手机端的泵和画面照旧；
    /// 之后接着出两帧，手机画面要和 Mac、参考终端一模一样（含光标、待折行）。
    func test_snapshot_cut_anywhere_in_a_claude_frame_keeps_the_phone_in_step() async throws {
        var rig = try await makeRig(cols: 62, rows: 20, transcriptLines: 4, hosted: false)
        defer { rig.session.dispose(); rig.phonePump.reset() }
        write(rig, rig.claude.fullRedraw(first: true))
        syncDrain(rig)
        var failures: [String] = []
        for step in 0..<300 {
            let frame = update(rig, step)
            let cut = step % frame.count
            write(rig, frame.prefix(cut))
            rig.session.mirrorTap.unsubscribe(id: rig.subscriber.id)
            rig.subscriber = rig.session.mirrorTap.subscribe(id: UUID()) {}
            rig.assembly = SnapshotAssembly()
            write(rig, frame.dropFirst(cut))
            write(rig, update(rig, step + 1000))
            syncDrain(rig)
            compare(rig, "第 \(step) 帧截在第 \(cut) / \(frame.count) 字节", into: &failures)
            if failures.count > 3 { break }
        }
        XCTAssertGreaterThanOrEqual(rig.phonePump.currentStats.replays, 300, "每次重连都该整屏回放一次")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n\n"))
    }

    /// 手机上这个标签藏起来（画面不吃字节，只进影子）期间程序照常出字；露出来时补尾巴或整屏回放。
    /// 三种：藏着时什么都没变；藏着时转了屏（Mac 跟着改尺寸、程序整帧重画）；藏着时画面转过去又转回来（Mac 两次都跟了）。
    func test_phone_tab_hidden_then_shown_around_rotation_keeps_claude_in_step() async throws {
        for variant in ["不转屏", "转屏", "转过去又转回来"] {
            let rig = try await makeRig(cols: 62, rows: 24, transcriptLines: 5, hosted: false)
            defer { rig.session.dispose(); rig.phonePump.reset() }
            var failures: [String] = []
            write(rig, rig.claude.fullRedraw(first: true))
            for step in 0..<4 { write(rig, update(rig, step)) }
            syncDrain(rig)
            compare(rig, "\(variant) 藏之前", into: &failures)
            rig.phonePump.setSurfaceFeeding(false)
            for step in 4..<9 { write(rig, update(rig, step)); syncDrain(rig) }
            switch variant {
            case "转屏":
                rig.surface.resize(cols: 89, rows: 18)
                rig.phonePump.surfaceGridDidChange()
                macFollows(rig, cols: 89, rows: 18)
            case "转过去又转回来":
                rig.surface.resize(cols: 89, rows: 18)
                rig.phonePump.surfaceGridDidChange()
                macFollows(rig, cols: 89, rows: 18)
                syncDrain(rig)
                rig.surface.resize(cols: 62, rows: 24)
                rig.phonePump.surfaceGridDidChange()
                macFollows(rig, cols: 62, rows: 24)
            default:
                break
            }
            for step in 9..<12 { write(rig, update(rig, step)); syncDrain(rig) }
            rig.phonePump.setSurfaceFeeding(true)
            syncDrain(rig)
            for step in 12..<15 { write(rig, update(rig, step)) }
            syncDrain(rig)
            compare(rig, "\(variant) 露出来之后", into: &failures)
            XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n\n"))
        }
    }

    /// 转屏后 Mac 迟迟没跟上（中继慢、Mac 在忙）：手机画面先停着等网格对齐，等过了 `gridAlignmentTimeout` 就按错位的网格
    /// 先画着；Mac 跟上、程序整帧重画之后，三方必须重新一致。
    func test_phone_waits_out_a_slow_mac_after_rotation_then_converges() async throws {
        let rig = try await makeRig(cols: 62, rows: 24, transcriptLines: 5, hosted: false)
        defer { rig.session.dispose(); rig.phonePump.reset() }
        var failures: [String] = []
        write(rig, rig.claude.fullRedraw(first: true))
        syncDrain(rig)
        rig.surface.resize(cols: 89, rows: 18)
        rig.phonePump.surfaceGridDidChange()
        let started = Date()
        var step = 0
        while Date().timeIntervalSince(started) < TerminalOutputPump.gridAlignmentTimeout + 0.3 {
            write(rig, update(rig, step)); step += 1
            syncDrain(rig)
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertGreaterThan(rig.phonePump.currentStats.gridHoldTimeouts, 0, "该等过对齐超时")
        macFollows(rig, cols: 89, rows: 18)
        for _ in 0..<3 { write(rig, update(rig, step)); step += 1 }
        syncDrain(rig)
        compare(rig, "Mac 跟上之后", into: &failures)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n\n"))
    }
}
