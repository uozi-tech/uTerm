import AppKit
import Carbon.HIToolbox
import XCTest
@testable import uTerm

/// 本机 shell 里跑着 Agent 时按 ⌘V 贴只有图片的剪贴板：要替用户按一下 Ctrl+V（pty 收到 0x16），Agent 自己去读剪贴板。
///
/// 全链路都是真的：内嵌 XPC 服务起的登录 shell（在 `uterm-holder` 里）、挂在窗口里的 Ghostty surface、真 NSEvent 走
/// `performKeyEquivalent`。「Agent」是一段 perl：像 Claude Code 2.1 一样启动时探测 OSC 7501，收到应答才报状态，
/// 之后把收到的每个字节打成 `GOTxx` 一行。全程不碰系统剪贴板（剪贴板与贴图写入都换成测试自己的）。
@MainActor
final class LocalShellAgentImagePasteTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var total: Int { lock.withLock { count } }
    }

    private struct Pane {
        let session: TerminalSession
        let backend: LocalShellBackend
        let window: NSWindow
    }

    private static let namespace = "agent-image-paste-test"
    private let png = Data([0x89, 0x50, 0x4E, 0x47])
    private let sessionID = UUID()
    private var client: LocalShellAgentClient!
    private var pasteboard: NSPasteboard!
    private var panes: [Pane] = []
    private let written = Recorder()

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("uterm-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        client = LocalShellAgentClient()
    }

    override func tearDown() async throws {
        for pane in panes {
            pane.session.dispose()
            await pane.backend.detach()
            pane.window.orderOut(nil)
        }
        panes = []
        // 用例中途失败也别把 shell 留在机器上。
        await HolderProbe.terminate(sessionID, client: client, namespace: Self.namespace)
        client?.invalidate()
        pasteboard?.releaseGlobally()
    }

    /// 起（或接回）那个 shell，终端挂进一个在屏上的透明窗口、是第一响应者。
    private func open() async -> Pane {
        let backend = LocalShellBackend(client: client, namespace: Self.namespace, sessionID: sessionID,
                                        columns: 100, rows: 30, writeImageToPasteboard: { [written] _ in written.add() })
        let session = TerminalSession()
        session.attentionSink = { _ in }
        let view = session.ghostty.view
        view.pasteboard = pasteboard
        // 真的主菜单会把 ⌘ 组合执行掉（⌘V 会走到菜单的「粘贴」）。
        view.performMenuKeyEquivalent = { _ in false }

        let rect = NSRect(x: 0, y: 0, width: 900, height: 560)
        let container = GhosttyContainerView(surface: view)
        container.isActive = true
        let window = ProbeWindow.make(contentRect: rect, contentView: container, placement: .transparentOnScreen)
        container.frame = window.contentView?.bounds ?? rect
        container.layoutSubtreeIfNeeded()
        let live = await waitUntil(10) { session.ghostty.isLive && session.ghostty.grid != nil }
        XCTAssertTrue(live, "Ghostty surface 没就绪")
        await session.connect(using: backend)
        window.makeFirstResponder(view)
        let pane = Pane(session: session, backend: backend, window: window)
        panes.append(pane)
        return pane
    }

    /// 模拟 App 重启：存检查点、断开。shell 和它前台的程序留在 holder 里。
    private func detachForRestart(_ pane: Pane) async throws {
        pane.session.saveHeldCheckpointNow()
        try await Task.sleep(for: .milliseconds(200))
        pane.session.dispose()
        await pane.backend.detach()
        pane.window.orderOut(nil)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func screen(_ pane: Pane) -> String { pane.session.shadow.viewportText() }

    /// 等 shell 起好、能执行命令。
    private func waitForShell(_ pane: Pane) async {
        pane.session.sendHostBytes(Data("echo SHELL_$((40+2))\n".utf8))
        let ready = await waitUntil(20) { self.screen(pane).contains("SHELL_42") }
        XCTAssertTrue(ready, "shell 没起来：\(screen(pane).suffix(400))")
    }

    /// 把收到的每个字节打成一行。标记字符串拆开写，免得 shell 回显的命令行本身就含着它们。
    private static let echoInput = #"while (sysread(STDIN,$c,1)) { printf("G"."OT%02X\r\n", ord($c)); last if ord($c)==3 } system("stty sane")"#

    /// 和 Claude Code 2.1 的启动探测一样：XTVERSION、kitty 键盘、OSC 7501 查询一起发，最后跟一个 DA1 当截止——
    /// DA1 的应答先到而 7501 的还没到，它就认定终端不支持、整个会话都不报状态。收到了才报 `working`。
    private func startFakeAgent(in pane: Pane) {
        let script = #"perl -e '$|=1; system("stty raw -echo"); print "\e[>0q\e[?u\e]7501;?\e\\\e[c"; $r=""; "#
            + #"while (sysread(STDIN,$c,1)) { $r.=$c; last if $r =~ /\e\[\?[0-9;]*c$/ } "#
            + #"if ($r =~ /7501;\?/) { print "QUERY_"."ANSWERED\r\n\e]7501;state=working:app=claude-code\e\\" } "#
            + #"else { print "QUERY_"."LATE\r\n" } "#
            + Self.echoInput + "'"
        pane.session.sendHostBytes(Data((script + "\n").utf8))
    }

    /// 一个不报状态的程序：代表重启前就在跑、状态早就报过、不会为接回再报一次的 Agent。
    private func startSilentAgent(in pane: Pane) {
        let script = #"perl -e '$|=1; system("stty raw -echo"); print "SILENT_"."READY\r\n"; "#
            + Self.echoInput + "'"
        pane.session.sendHostBytes(Data((script + "\n").utf8))
    }

    private func commandV(_ pane: Pane) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: pane.window.windowNumber, context: nil,
                                       characters: "v", charactersIgnoringModifiers: "v",
                                       isARepeat: false, keyCode: UInt16(kVK_ANSI_V)))
    }

    // MARK: -

    func testCommandVWithImageReachesAgentAsControlV() async throws {
        let pane = await open()
        await waitForShell(pane)
        startFakeAgent(in: pane)

        let answered = await waitUntil(10) { self.screen(pane).contains("QUERY_ANSWERED") }
        XCTAssertTrue(answered, "Agent 没在 DA1 之前收到 OSC 7501 查询的应答：\(screen(pane).suffix(600))")
        let reported = await waitUntil(5) { pane.session.programStatus?.state == .working }
        XCTAssertTrue(reported, "标签上没有 Agent 的状态：\(String(describing: pane.session.programStatus))")

        XCTAssertTrue(pane.session.ghostty.view.performKeyEquivalent(with: try commandV(pane)), "⌘V 没被接管")

        let gotControlV = await waitUntil(10) { self.screen(pane).contains("GOT16") }
        XCTAssertTrue(gotControlV, "Agent 没收到 Ctrl+V：\(screen(pane).suffix(600))")
        XCTAssertEqual(written.total, 1, "图片该写进剪贴板一次")
    }

    /// App 重启（升级）后接回：Agent 一直在跑，但检查点里没有它的状态（旧版本存的、引擎版本变了用不了、或者上一次
    /// 接回时就已经丢了），它也不会为接回再报一次。⌘V 照样要交给它。
    func testCommandVAfterReattachReachesAgentWhoseStatusWasLost() async throws {
        let first = await open()
        await waitForShell(first)
        startSilentAgent(in: first)
        let ready = await waitUntil(10) { self.screen(first).contains("SILENT_READY") }
        XCTAssertTrue(ready, String(screen(first).suffix(400)))
        try await detachForRestart(first)

        let second = await open()
        XCTAssertEqual(second.session.connectionState, .connected)
        XCTAssertTrue(screen(second).contains("SILENT_READY"), "没接回同一个 shell：\(screen(second).suffix(400))")
        XCTAssertNil(second.session.programStatus)

        XCTAssertTrue(second.session.ghostty.view.performKeyEquivalent(with: try commandV(second)), "⌘V 没被接管")
        let gotControlV = await waitUntil(10) { self.screen(second).contains("GOT16") }
        XCTAssertTrue(gotControlV, "接回后 Agent 没收到 Ctrl+V：\(screen(second).suffix(600))")
        XCTAssertEqual(written.total, 1)
    }

    /// 接回后前台就是 shell：不替用户按 Ctrl+V（在 zsh 里那是转义输入），问过一次之后也不再猜。
    func testCommandVAfterReattachAtShellPromptSendsNothing() async throws {
        let first = await open()
        await waitForShell(first)
        try await detachForRestart(first)

        let second = await open()
        XCTAssertTrue(second.session.programStatusUnknown)
        XCTAssertTrue(second.session.ghostty.view.performKeyEquivalent(with: try commandV(second)))
        let settled = await waitUntil(5) { !second.session.programStatusUnknown }
        XCTAssertTrue(settled, "前台是 shell，问过一次就该不再猜")
        XCTAssertEqual(written.total, 0, "shell 在前台时不该贴图")
        XCTAssertFalse(second.session.pasteImage(uTerm.TerminalImage(format: .png, data: png)))
    }

    /// 真 Claude Code（默认跳过）：它自己的启动探测拿到 7501 的应答、报了状态，⌘V 就替它按 Ctrl+V。
    /// 开关 `TEST_RUNNER_UTERM_E2E_LOCAL_CLAUDE=1`，`TEST_RUNNER_UTERM_E2E_LOCAL_CLAUDE_DIR` 给一个它已信任的目录
    /// （否则停在信任对话框，不报状态）；要求登录 shell 里找得到 `claude`。只启动到首屏、不发提示词。
    /// 调试日志写在 `/tmp/uterm-local-claude-e2e.log`（shell 不在沙盒里，测试宿主读不到，失败时自己去看）。
    func testRealClaudeCodeTakesCommandV() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["UTERM_E2E_LOCAL_CLAUDE"] == "1" else { throw XCTSkip("没设 UTERM_E2E_LOCAL_CLAUDE") }
        let pane = await open()
        await waitForShell(pane)
        let workdir = env["UTERM_E2E_LOCAL_CLAUDE_DIR"] ?? "/tmp"
        pane.session.sendHostBytes(Data("cd '\(workdir)' && claude --debug-file /tmp/uterm-local-claude-e2e.log\n".utf8))

        let reported = await waitUntil(30) { pane.session.programStatusTracker.hasRecords }
        XCTAssertTrue(reported, "Claude Code 没报状态：\(screen(pane).suffix(800))")

        XCTAssertTrue(pane.session.ghostty.view.performKeyEquivalent(with: try commandV(pane)), "⌘V 没被接管")
        let delivered = await waitUntil(5) { self.written.total == 1 }
        XCTAssertTrue(delivered, "图片没交给 Claude Code")
        pane.session.sendHostBytes(Data([0x03]))
        try? await Task.sleep(for: .milliseconds(300))
        pane.session.sendHostBytes(Data([0x03]))
        try? await Task.sleep(for: .milliseconds(500))
    }
}

/// 接回后「状态不知道」的那几条规则，不起真 shell。
@MainActor
final class TerminalReattachImagePasteTests: XCTestCase {

    private actor HeldImageBackend: HeldTerminalBackend, TerminalImageReceiving {
        nonisolated let outputStream: AsyncStream<Data>
        nonisolated let exitStream: AsyncStream<Void>
        nonisolated let holderLink = HolderLink()
        nonisolated let programsCanReadMacClipboard: Bool
        private let replay: HolderReplay
        private let activity: TerminalActivity
        private(set) var delivered = 0

        init(replay: HolderReplay, activity: TerminalActivity, canReadClipboard: Bool) {
            programsCanReadMacClipboard = canReadClipboard
            self.replay = replay
            self.activity = activity
            outputStream = AsyncStream { _ in }
            exitStream = AsyncStream { _ in }
        }

        func connect() async throws {}
        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async {}
        func takeReplay() -> HolderReplay? { replay }
        func detach() async {}
        func foregroundActivity() async -> TerminalActivity { activity }
        func deliverImage(_ image: uTerm.TerminalImage) async throws -> TerminalImageDelivery {
            delivered += 1
            return .clipboard
        }
    }

    private let image = uTerm.TerminalImage(format: .png, data: Data([0x89, 0x50, 0x4E, 0x47]))

    /// `blob` 为 nil：全新的会话（holder 里还没有检查点）。
    private func connect(blob: [UInt8]?, activity: TerminalActivity,
                         canReadClipboard: Bool = true) async -> (TerminalSession, HeldImageBackend) {
        let replay = HolderReplay(
            hello: HolderHelloReply(version: 1, shellPID: 1, createdAt: 0, cols: 80, rows: 24, exitStatus: nil, attributes: []),
            checkpoint: HolderCheckpoint(offset: 0, cols: 80, rows: 24, hasGap: false, blob: blob ?? []),
            output: [], endOffset: 0)
        let backend = HeldImageBackend(replay: replay, activity: activity, canReadClipboard: canReadClipboard)
        let session = TerminalSession()
        session.attentionSink = { _ in }
        session.userLookingOverride = { false }
        await session.connect(using: backend)
        XCTAssertEqual(session.connectionState, .connected)
        return (session, backend)
    }

    /// 上一个版本存的检查点：这个引擎用不了，里面的状态也就拿不到。
    private func foreignCheckpoint() throws -> [UInt8] {
        let shadow = ShadowTerminal(cols: 80, rows: 24, options: TerminalScrollbackLimits(lines: 100).shadowOptions)
        return TerminalCheckpointBlob.encode(snapshot: try shadow.snapshot(), engine: "an-older-engine")
    }

    private func waitUntil(_ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func testRunningProgramAfterReattachGetsTheImage() async throws {
        let (session, backend) = await connect(blob: try foreignCheckpoint(), activity: .running("claude"))
        XCTAssertTrue(session.programStatusUnknown)
        XCTAssertTrue(session.pasteImage(image))
        let delivered = await waitUntil { await backend.delivered == 1 }
        XCTAssertTrue(delivered)
        session.dispose()
    }

    /// 引擎升级了：旧检查点的快照用不了，但里面的程序状态照用——标签圆点在，⌘V 也不用猜。
    func testStatusFromCheckpointOfAnotherEngineIsKept() async throws {
        let journal = ProgramStatusJournal()
        journal.receive(.programStatus(.report(id: "", record: ProgramStatusRecord(state: .working, app: "claude-code"))))
        let shadow = ShadowTerminal(cols: 80, rows: 24, options: TerminalScrollbackLimits(lines: 100).shadowOptions)
        let blob = TerminalCheckpointBlob.encode(snapshot: try shadow.snapshot(), programStatus: journal.encoded,
                                                 engine: "an-older-engine")
        XCTAssertNil(TerminalCheckpointBlob.decode(blob), "别的引擎版本的快照不能用")

        let (session, backend) = await connect(blob: blob, activity: .unknown)
        XCTAssertTrue(session.programStatusTracker.hasRecords)
        XCTAssertEqual(session.programStatus?.state, .working)
        XCTAssertEqual(session.programStatus?.app, "claude-code")
        XCTAssertFalse(session.programStatusUnknown)
        XCTAssertTrue(session.pasteImage(image))
        let delivered = await waitUntil { await backend.delivered == 1 }
        XCTAssertTrue(delivered)
        session.dispose()
    }

    /// 状态段坏了（解不开的 JSON、长度超出整份数据）：当没有状态，接回照常。
    func testCorruptStatusSegmentFallsBackToNoStatus() async throws {
        let shadow = ShadowTerminal(cols: 80, rows: 24, options: TerminalScrollbackLimits(lines: 100).shadowOptions)
        let snapshot = try shadow.snapshot()
        let garbled = TerminalCheckpointBlob.encode(snapshot: snapshot, programStatus: Data("{\"board\":[".utf8),
                                                    engine: "an-older-engine")
        XCTAssertNotNil(TerminalCheckpointBlob.decodeProgramStatus(garbled))
        XCTAssertNil(TerminalCheckpointBlob.decodeProgramStatus(garbled).flatMap(ProgramStatusJournal.decode))
        var truncated = TerminalCheckpointBlob.encode(snapshot: snapshot, programStatus: Data(repeating: 0x7B, count: 64))
        truncated.removeLast(snapshot.count + 32)
        XCTAssertNil(TerminalCheckpointBlob.decodeProgramStatus(truncated))

        for blob in [garbled, truncated] {
            let (session, _) = await connect(blob: blob, activity: .unknown)
            XCTAssertFalse(session.programStatusTracker.hasRecords)
            XCTAssertNil(session.programStatus)
            XCTAssertTrue(session.programStatusUnknown, "接回了却不知道状态，该交给前台判断")
            session.dispose()
        }
    }

    /// 前台判断不了：不贴，下次再问。
    func testUnknownForegroundSendsNothing() async throws {
        let (session, backend) = await connect(blob: try foreignCheckpoint(), activity: .unknown)
        XCTAssertTrue(session.pasteImage(image))
        try await Task.sleep(for: .milliseconds(200))
        let delivered = await backend.delivered
        XCTAssertEqual(delivered, 0)
        XCTAssertTrue(session.programStatusUnknown)
        session.dispose()
    }

    /// 检查点里带着状态：照常按状态判断，不用去猜。
    func testCheckpointWithStatusNeedsNoGuess() async throws {
        let original = TerminalSession()
        original.attentionSink = { _ in }
        original.userLookingOverride = { false }
        original.feedOutput(text: "\u{1b}]7501;state=idle:app=claude-code\u{1b}\\")
        let (session, backend) = await connect(blob: try original.makeHeldCheckpointBlob(), activity: .idle)
        XCTAssertFalse(session.programStatusUnknown)
        XCTAssertTrue(session.pasteImage(image))
        let delivered = await waitUntil { await backend.delivered == 1 }
        XCTAssertTrue(delivered)
        original.dispose()
        session.dispose()
    }

    /// 全新的会话不是接回，没有什么可猜的。
    func testFreshSessionDoesNotGuess() async {
        let (session, _) = await connect(blob: nil, activity: .running("vim"))
        XCTAssertFalse(session.programStatusUnknown)
        XCTAssertFalse(session.pasteImage(image))
        session.dispose()
    }

    /// 接回之后程序开口了、或者回到了 shell 提示符：不再猜。
    func testProgramSpeakingOrPromptEndsTheGuess() async throws {
        let (spoken, _) = await connect(blob: try foreignCheckpoint(), activity: .running("claude"))
        spoken.feedOutput(text: "\u{1b}]7501;state=clear\u{1b}\\")
        XCTAssertFalse(spoken.programStatusUnknown)
        XCTAssertFalse(spoken.pasteImage(image))
        spoken.dispose()

        let (prompted, _) = await connect(blob: try foreignCheckpoint(), activity: .running("claude"))
        prompted.feedOutput(text: "\u{1b}]133;A\u{07}$ ")
        XCTAssertFalse(prompted.programStatusUnknown)
        XCTAssertFalse(prompted.pasteImage(image))
        prompted.dispose()
    }

    /// SSH（程序读不到 Mac 的剪贴板）：⌘V 走真 NSEvent 照样把图交给后端，和有没有状态无关。
    func testCommandVOverSSHIsAlwaysTaken() async throws {
        let (session, backend) = await connect(blob: nil, activity: .unknown, canReadClipboard: false)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("uterm-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(image.data, forType: .png)
        let view = session.ghostty.view
        view.pasteboard = pasteboard
        view.performMenuKeyEquivalent = { _ in false }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: "v", charactersIgnoringModifiers: "v",
                                                   isARepeat: false, keyCode: UInt16(kVK_ANSI_V)))
        XCTAssertTrue(view.performKeyEquivalent(with: event))
        let delivered = await waitUntil { await backend.delivered == 1 }
        XCTAssertTrue(delivered)
        session.dispose()
    }
}
