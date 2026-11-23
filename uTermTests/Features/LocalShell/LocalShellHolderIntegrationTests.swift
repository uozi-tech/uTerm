import AppKit
import XCTest
@testable import uTerm

/// 真的起 `uterm-holder` 和你的登录 shell：测试宿主的包里就带着它们。验证「App 没了 shell 还在」这条核心链路。
/// App 没了用断开连接代替（对 holder 来说没有区别）。
@MainActor
final class LocalShellHolderIntegrationTests: XCTestCase {
    /// 测试的会话单独一个命名空间，不和开发时跑的 Debug 版混。
    private static let namespace = "integration-test"
    private let client = LocalShellAgentClient()
    private var sessionIDs: [UUID] = []

    override func tearDown() async throws {
        // 用例中途失败也别把 shell 留在机器上。
        for id in sessionIDs { await HolderProbe.terminate(id, client: client, namespace: Self.namespace) }
        client.invalidate()
        try await super.tearDown()
    }

    private func makeSession() -> UUID {
        let id = UUID()
        sessionIDs.append(id)
        return id
    }

    private func backend(_ id: UUID) -> LocalShellBackend {
        LocalShellBackend(client: client, namespace: Self.namespace, sessionID: id, columns: 80, rows: 24)
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat != SZOMB
    }

    private func screen(_ session: TerminalSession) -> String {
        session.snapshotScreen(lines: 200).lines.joined(separator: "\n")
    }

    private func wait(timeout: TimeInterval = 15, for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return true
    }

    private func connected(_ id: UUID) async throws -> (TerminalSession, LocalShellBackend) {
        let session = TerminalSession()
        let held = backend(id)
        await session.connect(using: held)
        XCTAssertEqual(session.connectionState, .connected)
        return (session, held)
    }

    /// 探活信号的默认处置是杀进程。本机 shell 收到探活帧不能有事。
    func test_foreground_activity_reports_idle_and_running() async throws {
        let id = makeSession()
        let (session, held) = try await connected(id)
        try await Task.sleep(for: .seconds(1))
        let atPrompt = await held.foregroundActivity()
        XCTAssertEqual(atPrompt, .idle)
        try await session.injectInput("sleep 30", appendEnter: true)
        try await Task.sleep(for: .seconds(1))
        let running = await held.foregroundActivity()
        XCTAssertEqual(running, .running("sleep"))
        await session.close()
    }

    /// 本地网络权限跟着责任进程走。SSH 的 holder 必须自己当责任进程，否则 App 一死局域网连接就断流。
    func test_ssh_holder_is_its_own_responsible_process() async throws {
        let id = makeSession()
        let opened = try await client.openSSHSession(namespace: Self.namespace, id: id, columns: 80, rows: 24)
        let holder = try Self.peerPID(of: opened.holder)
        XCTAssertEqual(Self.responsiblePID(for: holder), holder)
    }

    /// 用户选了保住局域网连接：本机 shell 的 holder 也自己当责任进程。
    func test_shell_holder_owns_responsibility_when_user_chose_to_keep_lan_connections() async throws {
        let id = makeSession()
        let handle = try await client.openSession(namespace: Self.namespace, id: id, columns: 80, rows: 24,
                                                  ownsResponsibility: true)
        let holder = try Self.peerPID(of: handle)
        XCTAssertEqual(Self.responsiblePID(for: holder), holder)
    }

    /// 默认：本机 shell 的 holder 责任进程还是 App，shell 访问 ~/Documents 这类授权记在 uTerm 名下。
    func test_shell_holder_stays_under_the_app_for_responsibility() async throws {
        let id = makeSession()
        let handle = try await client.openSession(namespace: Self.namespace, id: id, columns: 80, rows: 24)
        let holder = try Self.peerPID(of: handle)
        XCTAssertEqual(Self.responsiblePID(for: holder), getpid())
    }

    /// holder 刚起来还没顾上 accept 时，发完就关的连接会被它当成身份不明拒掉，结束请求就丢了。
    func test_terminate_right_after_open_is_not_lost() async throws {
        let id = makeSession()
        let handle = try await client.openSession(namespace: Self.namespace, id: id, columns: 80, rows: 24)
        let holder = try Self.peerPID(of: handle)
        await HolderProbe.terminate(id, client: client, namespace: Self.namespace)
        let ended = await wait(timeout: 5) { !Self.isAlive(holder) }
        XCTAssertTrue(ended)
    }

    private static func peerPID(of handle: FileHandle) throws -> pid_t {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(handle.fileDescriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return pid
    }

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        typealias Lookup = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Lookup.self)(pid)
    }

    /// 少量输出不按时间存检查点（Claude Code 思考时存会让滚动掉帧）；被杀掉之后靠 holder 里的字节恢复。
    func test_small_output_stays_in_holder_and_restores_after_kill() async throws {
        let id = makeSession()
        let (first, firstBackend) = try await connected(id)
        // 等连接时改尺寸触发的那次检查点过去。
        try await Task.sleep(for: .seconds(1))
        await firstBackend.write(Data("echo SMALL_$((40+2))\n".utf8))
        let printed = await wait { self.screen(first).contains("SMALL_42") }
        XCTAssertTrue(printed, screen(first))
        try await Task.sleep(for: .milliseconds(5500))
        first.dispose()
        await firstBackend.detach()

        let probe = backend(id)
        try await probe.connect()
        let taken = await probe.takeReplay()
        let replay = try XCTUnwrap(taken)
        XCTAssertTrue(String(decoding: replay.output, as: UTF8.self).contains("SMALL_42"), "这段输出不该已经被存进检查点")
        await probe.detach()

        let (second, secondBackend) = try await connected(id)
        defer { second.dispose() }
        XCTAssertTrue(screen(second).contains("SMALL_42"), screen(second))
        await secondBackend.close()
    }

    func test_probe_frame_is_ignored_for_local_shell() async throws {
        let id = makeSession()
        let (session, held) = try await connected(id)
        let heldPID = await held.pid
        let pid = try XCTUnwrap(heldPID)
        held.holderLink.send(HolderFrame(.probe))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(Self.isAlive(pid))
        XCTAssertEqual(session.connectionState, .connected)
        await session.close()
    }

    /// 关掉之后同一个 id 马上再开，要得到新的 shell，不能接上正在退出的那个，也不能被它退出时删掉 socket。
    func test_reopen_right_after_close_gets_a_new_shell_with_working_socket() async throws {
        let id = makeSession()
        let (first, firstBackend) = try await connected(id)
        let firstPID = await firstBackend.pid
        XCTAssertNotNil(firstPID)
        await first.close()
        let (second, secondBackend) = try await connected(id)
        let secondPID = await secondBackend.pid
        XCTAssertNotNil(secondPID)
        XCTAssertNotEqual(firstPID, secondPID)
        // 旧 holder 退出（SIGHUP 后最多几秒）之后，新会话还要能被连上。
        try await Task.sleep(for: .seconds(4))
        let listed = try await client.listSessions(namespace: Self.namespace)
        XCTAssertTrue(listed.contains(id))
        await second.close()
    }

    /// 断开之后 shell 继续跑，新连接拿到同一个 shell，之前的画面和断开期间的输出都在。
    func test_reattach_keeps_shell_and_restores_screen_including_output_while_away() async throws {
        let id = makeSession()
        let (first, firstBackend) = try await connected(id)
        let firstPID = await firstBackend.pid
        await firstBackend.write(Data("echo BEFORE_$((40+2))\n".utf8))
        let printed = await wait { self.screen(first).contains("BEFORE_42") }
        XCTAssertTrue(printed, screen(first))
        // 断开期间才会打印的内容。
        await firstBackend.write(Data("(sleep 1; echo LATER_$((40+3))) &\n".utf8))
        try await Task.sleep(for: .milliseconds(200))
        first.saveHeldCheckpointNow()
        first.dispose()
        await firstBackend.detach()

        try await Task.sleep(for: .milliseconds(1500))
        if let firstPID { XCTAssertTrue(Self.isAlive(firstPID), "断开后 shell 不该结束") }

        let (second, secondBackend) = try await connected(id)
        defer { second.dispose() }
        let secondPID = await secondBackend.pid
        XCTAssertEqual(secondPID, firstPID, "应该接回同一个 shell")
        XCTAssertTrue(screen(second).contains("BEFORE_42"), screen(second))
        XCTAssertTrue(screen(second).contains("LATER_43"), screen(second))

        // 接回之后还能接着用。
        await secondBackend.write(Data("echo AFTER_$((40+4))\n".utf8))
        let after = await wait { self.screen(second).contains("AFTER_44") }
        XCTAssertTrue(after, screen(second))
        await secondBackend.close()
    }

    /// 退出时存的最后一张检查点带着回放流（下次启动的可能是换了引擎的新版本），而且没有新输出也存。
    /// 回放流灌进一个新终端就是那一屏。
    func test_quit_checkpoint_carries_a_replay_stream() async throws {
        let id = makeSession()
        let (first, firstBackend) = try await connected(id)
        await firstBackend.write(Data("echo QUIT_$((40+6))\n".utf8))
        let printed = await wait { self.screen(first).contains("QUIT_46") }
        XCTAssertTrue(printed, screen(first))
        // 平时那种检查点先存一张（不带回放流），之后没有新输出：退出时那张也不能因此跳过。
        first.heldCheckpoints?.captureNow()
        first.saveHeldCheckpointNow()
        first.dispose()
        await firstBackend.detach()
        try await Task.sleep(for: .milliseconds(300))

        let raw = backend(id)
        try await raw.connect()
        let taken = await raw.takeReplay()
        let replay = try XCTUnwrap(taken)
        await raw.detach()
        let stream = try XCTUnwrap(TerminalCheckpointBlob.decodeReplay(replay.checkpoint.blob), "退出时的检查点要带回放流")
        XCTAssertNotNil(TerminalCheckpointBlob.decode(replay.checkpoint.blob), "二进制快照照存")
        let fresh = ShadowTerminal(cols: replay.checkpoint.cols, rows: replay.checkpoint.rows,
                                   options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
        fresh.feed(stream, asHistory: true)
        XCTAssertTrue(fresh.recentLines(50).lines.contains("QUIT_46"), fresh.recentLines(50).lines.joined(separator: "\n"))
    }

    /// 历史里的终端查询不能被再回答一遍，否则回答会打进正在跑的程序。
    func test_replay_does_not_answer_terminal_queries_from_history() async throws {
        let id = makeSession()
        let (first, firstBackend) = try await connected(id)
        // 断开期间发出查询，然后 `cat -v` 把收到的输入显示出来。
        await firstBackend.write(Data("(sleep 1; printf '\\033[c'; cat -v)\n".utf8))
        try await Task.sleep(for: .milliseconds(200))
        first.dispose()
        await firstBackend.detach()
        try await Task.sleep(for: .milliseconds(1500))

        let (second, secondBackend) = try await connected(id)
        defer { second.dispose() }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(screen(second).contains("^[["), "回放不该回答历史查询：\(screen(second))")
        // 实时的查询照常回答（`cat -v` 把回答显示出来），证明屏蔽在回放结束后解除了。
        await secondBackend.write(Data("\u{03}".utf8))
        try await Task.sleep(for: .milliseconds(200))
        await secondBackend.write(Data("printf '\\033[c'; cat -v\n".utf8))
        let answered = await wait { self.screen(second).contains("^[[") }
        XCTAssertTrue(answered, screen(second))
        await secondBackend.close()
    }

    func test_close_ends_shell_and_session_disappears() async throws {
        let id = makeSession()
        let (session, held) = try await connected(id)
        let heldPID = await held.pid
        let pid = try XCTUnwrap(heldPID)
        session.dispose()
        await held.close()
        let gone = await wait(timeout: 8) { !Self.isAlive(pid) }
        XCTAssertTrue(gone, "结束后 shell 还在")
        let removed = try await waitForSessionRemoved(id)
        XCTAssertTrue(removed, "结束后会话还在列表里")
    }

    /// 退出前最后一刻改了布局（还在 0.3 秒攒批里）：退出流程里要趁连接还在把它写进 holder，接回时按新布局放。
    func test_layout_changed_right_before_quit_reaches_the_holder() async throws {
        let windowID = UUID()
        let model = LocalShellWindowModel(startShell: { _ in })
        model.attach(TerminalSessionRegistrar(registry: TerminalSessionRegistry(), windowID: windowID,
                                              windowKind: TerminalWindowKind.terminal))
        let a = model.addTab(id: makeSession()), b = model.addTab(id: makeSession())
        for pane in model.panes { await pane.session.connect(using: backend(pane.id)) }
        XCTAssertTrue(model.panes.allSatisfy { $0.session.connectionState == .connected })
        func stored(_ id: UUID) async throws -> LocalShellSessionAttributes? {
            let hello = await HolderProbe.hello(id, client: client, namespace: Self.namespace)
            let reply = try XCTUnwrap(hello)
            return try? JSONDecoder().decode(LocalShellSessionAttributes.self, from: Data(reply.attributes))
        }
        // 先等攒批写一次，holder 里是 [a, b]。
        let first = await wait(timeout: 5) { model.panes.allSatisfy { $0.attributes?.layout?.tree.groups.first?.tabs == [a, b] } }
        XCTAssertTrue(first)
        try await Task.sleep(for: .milliseconds(200))
        let before = try await stored(a)
        XCTAssertEqual(before?.layout?.tree.groups.first?.tabs, [a, b])

        model.groups.reorderTab(b, before: a)
        let quit = TerminalQuitPolicy.shared
        defer { quit.quitCancelled() }
        quit.applicationWillTerminate()   // 不等攒批：这之后 App 就没了。
        // 退出流程断开连接、shell 留着；下次启动从 holder 读到的是新布局。
        for id in [a, b] {
            let after = try await stored(id)
            XCTAssertEqual(after?.layout?.tree.groups.first?.tabs, [b, a], "\(id == a ? "a" : "b") 的 holder 里还是旧布局")
        }
        let restored = LocalShellWindowModel(startShell: { _ in })
        var sessions: [(id: UUID, attributes: LocalShellSessionAttributes)] = []
        for id in [a, b] {
            let attributes = try await stored(id)
            sessions.append((id, try XCTUnwrap(attributes)))
        }
        LocalShellRestorer.adopt(sessions, windowID: windowID, into: restored)
        XCTAssertEqual(restored.panes.map(\.id), [b, a])
        restored.disposeAll()
        model.disposeAll()
    }

    private func waitForSessionRemoved(_ id: UUID) async throws -> Bool {
        for _ in 0..<100 {
            if !(try await client.listSessions(namespace: Self.namespace)).contains(id) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// shell 在没人连着的时候退出：会话留着，接回时交出最后一屏再报告退出，之后才真正消失。
    func test_shell_exiting_while_detached_lingers_until_reattached() async throws {
        let id = makeSession()
        let (first, firstBackend) = try await connected(id)
        await firstBackend.write(Data("(sleep 1; echo FINAL_$((40+5))) & sleep 1.2; exit\n".utf8))
        try await Task.sleep(for: .milliseconds(200))
        first.dispose()
        await firstBackend.detach()
        try await Task.sleep(for: .milliseconds(2500))
        let listed = try await client.listSessions(namespace: Self.namespace)
        XCTAssertTrue(listed.contains(id), "退出的 shell 要等接回")

        let second = backend(id)
        try await second.connect()
        let taken = await second.takeReplay()
        let replay = try XCTUnwrap(taken)
        XCTAssertNotNil(replay.hello.exitStatus)
        XCTAssertTrue(String(decoding: replay.output, as: UTF8.self).contains("FINAL_45"))
        let drain = Task { for await _ in second.outputItems {} }
        defer { drain.cancel() }
        let removed = try await waitForSessionRemoved(id)
        XCTAssertTrue(removed, "交出最后一屏之后会话应该消失")
    }

    /// 同一个会话第二个客户端接入：第一个被告知结束，第二个接管。
    func test_second_attach_replaces_first_client() async throws {
        let id = makeSession()
        let first = backend(id)
        try await first.connect()
        let firstEnded = Task { () -> Bool in
            for await _ in first.exitStream { return true }
            return false
        }
        let second = backend(id)
        try await second.connect()
        let wasReplaced = await firstEnded.value
        XCTAssertTrue(wasReplaced)
        let firstPID = await first.pid
        XCTAssertNil(firstPID)
        let secondPID = await second.pid
        XCTAssertNotNil(secondPID)
        await second.close()
    }

    /// 大段粘贴不能丢尾巴：主端一次只收约 1 KB，holder 要排队写。
    func test_large_paste_arrives_intact() async throws {
        let id = makeSession()
        let (session, held) = try await connected(id)
        defer { session.dispose() }
        await held.write(Data("stty -echo; wc -c\n".utf8))
        try await Task.sleep(for: .milliseconds(500))
        // 没有换行的一行太长会被 canonical 模式截断，所以分行。
        let line = String(repeating: "x", count: 199) + "\n"
        await held.write(Data(String(repeating: line, count: 2000).utf8))
        await held.write(Data("\u{04}".utf8))
        let counted = await wait { self.screen(session).contains("400000") }
        XCTAssertTrue(counted, screen(session))
        await held.close()
    }
}

/// 不起真进程，验证回放的逐格还原和屏蔽。
@MainActor
final class LocalShellNetworkPolicyTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "LocalShellNetworkPolicyTests"

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func test_without_an_answer_connections_are_not_kept() {
        XCTAssertFalse(LocalShellNetworkPolicy.keepsLANConnections(in: defaults))
    }

    func test_asks_once_and_remembers_the_answer() {
        var asked = 0
        LocalShellNetworkPolicy.askIfNeeded(in: defaults) {
            asked += 1
            return true
        }
        XCTAssertTrue(LocalShellNetworkPolicy.keepsLANConnections(in: defaults))
        LocalShellNetworkPolicy.askIfNeeded(in: defaults) {
            asked += 1
            return false
        }
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(LocalShellNetworkPolicy.keepsLANConnections(in: defaults))
    }

    func test_answering_no_also_counts_as_answered() {
        var asked = 0
        for _ in 0..<2 {
            LocalShellNetworkPolicy.askIfNeeded(in: defaults) {
                asked += 1
                return false
            }
        }
        XCTAssertEqual(asked, 1)
    }
}

@MainActor
final class TerminalHeldReplayTests: XCTestCase {
    private actor MockHeldBackend: HeldTerminalBackend {
        nonisolated let outputItems: AsyncStream<TerminalOutputItem>
        nonisolated let exitStream: AsyncStream<Void>
        nonisolated let holderLink = HolderLink()
        private let replay: HolderReplay
        private(set) var written: [Data] = []

        init(replay: HolderReplay) {
            self.replay = replay
            outputItems = AsyncStream { _ in }
            exitStream = AsyncStream { _ in }
        }

        func connect() async throws {}
        func write(_ data: Data) async { written.append(data) }
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async {}
        func takeReplay() -> HolderReplay? { replay }
        func detach() async {}
    }

    private func replay(blob: [UInt8], cols: UInt16, rows: UInt16, hasGap: Bool = false, output: [UInt8]) -> HolderReplay {
        HolderReplay(
            hello: HolderHelloReply(version: 1, shellPID: 1, createdAt: 0, cols: cols, rows: rows, exitStatus: nil, attributes: []),
            checkpoint: HolderCheckpoint(offset: 0, cols: cols, rows: rows, hasGap: hasGap, blob: blob),
            output: output, endOffset: UInt64(output.count))
    }

    private let head = "\u{1b}]0;build\u{07}\u{1b}[31mred line\u{1b}[0m\r\n第二行 中文\r\n\u{1b}[?1049h\u{1b}[2;3Halt screen"
    private let tail = "\u{1b}[?1049l\r\nback on main\r\n\u{1b}[1mbold"

    // MARK: 程序状态跟着检查点走

    private func status(_ payload: String) -> String { "\u{1b}]7501;\(payload)\u{1b}\\" }

    /// 模拟重启：`original` 此刻存一次检查点，之后又输出了 `tail`；新会话接回。
    private func reattach(from original: TerminalSession, tail: String = "") async throws -> (TerminalSession, MockHeldBackend) {
        let blob = try original.makeHeldCheckpointBlob()
        let size = original.shadow.size
        let backend = MockHeldBackend(replay: replay(blob: blob, cols: UInt16(size.cols), rows: UInt16(size.rows),
                                                     output: Array(tail.utf8)))
        let restored = TerminalSession()
        var attentions: [TerminalAttention] = []
        restored.attentionSink = { attentions.append($0) }
        restored.userLookingOverride = { false }
        await restored.connect(using: backend)
        XCTAssertEqual(restored.connectionState, .connected)
        XCTAssertTrue(attentions.isEmpty, "接回不该发通知：\(attentions)")
        return (restored, backend)
    }

    /// 程序一直在 working：跨重启它不会再报一次，接回后标签上的状态来自检查点。
    func test_working_status_survives_reattach() async throws {
        let original = TerminalSession()
        original.attentionSink = { _ in }
        original.userLookingOverride = { false }
        original.feedOutput(text: "$ claude\r\n" + status("state=working:app=claude-code"))
        XCTAssertEqual(original.programStatus?.state, .working)

        let (restored, backend) = try await reattach(from: original)
        XCTAssertEqual(restored.programStatus?.state, .working, "接回的那一刻就该是运行中，不等程序下一次上报")
        XCTAssertEqual(restored.programStatus?.app, "claude-code")
        XCTAssertEqual(restored.programReport?.state, .working)
        let written = await backend.written
        XCTAssertTrue(written.isEmpty, "接回不该往 shell 里写东西：\(written)")
        original.dispose()
        restored.dispose()
    }

    /// 检查点之后、重启之前程序做完了：这次变化在 holder 留着的那段字节里，回放时要算上；查询不答、通知不发。
    func test_status_change_after_the_checkpoint_is_replayed() async throws {
        let original = TerminalSession()
        original.attentionSink = { _ in }
        original.userLookingOverride = { false }
        original.feedOutput(text: status("state=working:app=claude-code"))

        let tail = "output…\r\n" + status("?") + status("state=done:app=claude-code") + "\u{1b}]9;all done\u{07}"
        let (restored, backend) = try await reattach(from: original, tail: tail)
        XCTAssertEqual(restored.programStatus?.state, .done)
        let written = await backend.written
        XCTAssertTrue(written.isEmpty, "回放里的查询当年已经答过：\(written)")

        // 再重启一次（这回状态已经在新会话的记账副本里）：还是 done。
        let (again, _) = try await reattach(from: restored)
        XCTAssertEqual(again.programStatus?.state, .done)
        original.dispose()
        restored.dispose()
        again.dispose()
    }

    /// 检查点之后回到了 shell 提示符：程序已经结束，运行中的状态不该留着。
    func test_prompt_after_the_checkpoint_clears_running_status() async throws {
        let original = TerminalSession()
        original.attentionSink = { _ in }
        original.userLookingOverride = { false }
        original.feedOutput(text: status("state=working:app=codex"))

        let (restored, _) = try await reattach(from: original, tail: "\r\n\u{1b}]133;A\u{07}$ ")
        XCTAssertNil(restored.programStatus)
        original.dispose()
        restored.dispose()
    }

    /// 用户看过的结果不会在接回后又冒出来。
    func test_acknowledged_result_stays_acknowledged_after_reattach() async throws {
        let original = TerminalSession()
        original.attentionSink = { _ in }
        original.userLookingOverride = { false }
        original.feedOutput(text: status("state=done:app=codex"))
        XCTAssertEqual(original.programStatus?.state, .done)
        original.acknowledgeProgramStatus()

        let (restored, _) = try await reattach(from: original)
        XCTAssertNil(restored.programStatus)
        original.dispose()
        restored.dispose()
    }

    /// 检查点里带不带程序状态都解得开；状态和快照各归各的。
    func test_checkpoint_blob_carries_program_status_next_to_the_snapshot() throws {
        let terminal = ShadowTerminal(cols: 20, rows: 4, options: TerminalScrollbackLimits(lines: 100).shadowOptions)
        terminal.feed(Data("x".utf8))
        let snapshot = try terminal.snapshot()
        let journal = ProgramStatusJournal()
        journal.receive(.programStatus(.report(id: "", record: ProgramStatusRecord(state: .working, app: "codex"))))

        let with = try XCTUnwrap(TerminalCheckpointBlob.decodeContents(
            TerminalCheckpointBlob.encode(snapshot: snapshot, programStatus: journal.encoded)))
        XCTAssertEqual(with.snapshot, snapshot)
        XCTAssertEqual(with.programStatus.flatMap(ProgramStatusJournal.decode), journal.current)

        let without = try XCTUnwrap(TerminalCheckpointBlob.decodeContents(TerminalCheckpointBlob.encode(snapshot: snapshot)))
        XCTAssertEqual(without.snapshot, snapshot)
        XCTAssertNil(without.programStatus)
    }

    /// 喂「检查点 + 之后的字节」应该和一直连着喂到底得到一模一样的终端。检查点是影子终端的二进制快照
    /// （`TerminalCheckpointBlob`），还原只动影子终端；画面等标签露出、surface 建好时由输出泵回放。
    func test_checkpoint_plus_tail_matches_uninterrupted_terminal() async throws {
        let original = TerminalSession()
        original.shadow.resize(cols: 83, rows: 25)
        original.feedOutput(text: head)
        let blob = TerminalCheckpointBlob.encode(snapshot: try original.shadow.snapshot())
        original.feedOutput(text: tail)

        let restored = TerminalSession()
        let backend = MockHeldBackend(replay: replay(blob: blob, cols: 83, rows: 25, output: Array(tail.utf8)))
        await restored.connect(using: backend)
        XCTAssertEqual(restored.connectionState, .connected)
        XCTAssertEqual(restored.shadow.size.cols, 83)
        XCTAssertEqual(restored.shadow.size.rows, 25)
        XCTAssertEqual(restored.shadow.mirrorDifferences(from: original.shadow), [:])
        XCTAssertEqual(restored.shadow.title, "build", "标题在快照里，跟着回来")
        XCTAssertFalse(restored.shadow.isOnAlternateScreen)
        XCTAssertEqual(restored.shellTitle, "build", "接回后标签沿用重启前的标题，不回落成默认名")
        restored.dispose()
        original.dispose()
    }

    /// 检查点从备用屏上存的（vim / Claude 全屏开着时退出）：接回来还在备用屏上，主屏的内容也还在底下。
    func test_checkpoint_taken_on_the_alternate_screen_restores_both_screens() async throws {
        let original = TerminalSession()
        original.feedOutput(text: head)
        XCTAssertTrue(original.shadow.isOnAlternateScreen)
        let blob = TerminalCheckpointBlob.encode(snapshot: try original.shadow.snapshot())
        let size = original.shadow.size

        let restored = TerminalSession()
        let backend = MockHeldBackend(replay: replay(blob: blob, cols: UInt16(size.cols), rows: UInt16(size.rows), output: []))
        await restored.connect(using: backend)
        XCTAssertTrue(restored.shadow.isOnAlternateScreen)
        XCTAssertEqual(restored.shadow.mirrorDifferences(from: original.shadow), [:])
        // 程序退出备用屏：主屏上原来的两行还在。
        restored.feedOutput(text: "\u{1b}[?1049l")
        original.feedOutput(text: "\u{1b}[?1049l")
        XCTAssertEqual(restored.shadow.recentLines(5).lines, ["red line", "第二行 中文"])
        XCTAssertEqual(restored.shadow.mirrorDifferences(from: original.shadow), [:])
        restored.dispose()
        original.dispose()
    }

    /// 检查点不是这个引擎版本存的（升级前留下的、旧的 VT 流检查点）：丢弃，只回放 holder 里那段字节，
    /// 尺寸先回到存检查点时的行列数（那段字节是按它产生的）。
    func test_checkpoint_from_another_engine_is_discarded_and_only_the_tail_replays() async throws {
        let original = TerminalSession()
        original.feedOutput(text: "old history\r\n")
        let snapshot = try original.shadow.snapshot()
        original.dispose()

        for blob in [TerminalCheckpointBlob.encode(snapshot: snapshot, engine: "ghostty-ffffffff+p0000/snapshot-9"),
                     Array("\u{1b}c\u{1b}[2Jold history\r\n".utf8), Array(snapshot)] {
            let restored = TerminalSession()
            let backend = MockHeldBackend(replay: replay(blob: blob, cols: 83, rows: 25, output: Array("tail only\r\n".utf8)))
            await restored.connect(using: backend)
            XCTAssertEqual(restored.connectionState, .connected)
            XCTAssertEqual(restored.shadow.size.cols, 83)
            XCTAssertEqual(restored.shadow.size.rows, 25)
            XCTAssertEqual(restored.shadow.recentLines(10).lines, ["tail only"])
            restored.dispose()
        }
    }

    /// 换了引擎（App 更新、快照格式变了）：二进制快照解不开，改用退出时一起存的回放流重画那一屏，再接上之后的字节。
    /// 回放流从备用屏上拍的（全屏程序开着时退出），接回来仍在备用屏上、主屏的内容在底下。
    func test_checkpoint_from_another_engine_restores_from_its_replay_stream() async throws {
        let original = TerminalSession()
        original.shadow.resize(cols: 83, rows: 25)
        original.feedOutput(text: head)
        let snapshot = try original.shadow.snapshot()
        let stream = try ShadowTerminal.replayStream(fromSnapshot: snapshot)
        let blob = TerminalCheckpointBlob.encode(snapshot: snapshot, replay: stream, engine: "ghostty-ffffffff+p0000/snapshot-9")
        XCTAssertNil(TerminalCheckpointBlob.decode(blob), "前提：这张的二进制快照现在的引擎不认")
        original.feedOutput(text: tail)

        let restored = TerminalSession()
        let backend = MockHeldBackend(replay: replay(blob: blob, cols: 83, rows: 25, output: Array(tail.utf8)))
        await restored.connect(using: backend)
        XCTAssertEqual(restored.connectionState, .connected)
        XCTAssertEqual(restored.shadow.size.cols, 83)
        XCTAssertEqual(restored.shadow.size.rows, 25)
        XCTAssertEqual(restored.shadow.recentLines(10).lines, original.shadow.recentLines(10).lines)
        XCTAssertEqual(restored.shadow.mirrorDifferences(from: original.shadow), [:])
        XCTAssertFalse(restored.shadow.isOnAlternateScreen)
        let written = await backend.written
        XCTAssertTrue(written.isEmpty, "回放流按历史喂，不该往 shell 里写东西：\(written)")
        restored.dispose()
        original.dispose()
    }

    /// 主机上的保持进程那条路（iOS）：存的检查点经 `addingReplay` 带上回放流；换了引擎时 `restorableSnapshot`
    /// 用现在的引擎把回放流重画成一张快照，还原出来和原来的终端一致（含备用屏和底下的主屏）。
    func test_host_checkpoint_replay_is_redrawn_into_a_snapshot_when_the_engine_changed() throws {
        let options = TerminalScrollbackLimits(lines: 1_000).shadowOptions
        let original = ShadowTerminal(cols: 83, rows: 25, options: options)
        original.feed(Data(head.utf8))
        XCTAssertTrue(original.isOnAlternateScreen)
        let status = Data("status-v1".utf8)
        let plain = TerminalCheckpoint(blob: TerminalCheckpointBlob.encode(snapshot: try original.snapshot(), programStatus: status),
                                       cols: 83, rows: 25)
        let checkpoint = plain.addingReplay()
        XCTAssertEqual(checkpoint.cols, 83)
        let replay = try XCTUnwrap(TerminalCheckpointBlob.decodeReplay(checkpoint.blob), "要带上回放流")
        XCTAssertEqual(TerminalCheckpointBlob.decode(checkpoint.blob), TerminalCheckpointBlob.decode(plain.blob), "二进制快照不变")
        XCTAssertEqual(TerminalCheckpointBlob.decodeProgramStatus(checkpoint.blob), status)
        XCTAssertEqual(TerminalCheckpointBlob.restorableSnapshot(checkpoint.blob, cols: 83, rows: 25),
                       TerminalCheckpointBlob.decode(checkpoint.blob), "同一个引擎：直接用二进制快照")

        let foreign = TerminalCheckpointBlob.encode(snapshot: Data("unreadable".utf8), programStatus: status, replay: replay,
                                                    engine: "ghostty-ffffffff+p0000/snapshot-9")
        let redrawn = try XCTUnwrap(TerminalCheckpointBlob.restorableSnapshot(foreign, cols: 83, rows: 25))
        let restored = ShadowTerminal(cols: 40, rows: 10, options: options)
        try restored.restore(snapshot: redrawn)
        XCTAssertEqual(restored.size.cols, 83, "尺寸跟着快照回到存的时候")
        XCTAssertEqual(restored.size.rows, 25)
        XCTAssertTrue(restored.isOnAlternateScreen)
        XCTAssertEqual(restored.mirrorDifferences(from: original), [:])
        restored.feed(Data("\u{1b}[?1049l".utf8))
        original.feed(Data("\u{1b}[?1049l".utf8))
        XCTAssertEqual(restored.mirrorDifferences(from: original), [:], "主屏也在")

        XCTAssertNil(TerminalCheckpointBlob.restorableSnapshot(
            TerminalCheckpointBlob.encode(snapshot: Data("unreadable".utf8), engine: "ghostty-ffffffff+p0000/snapshot-9"),
            cols: 83, rows: 25), "别的引擎存的、又没有回放流：用不了")
    }

    /// 接回之后镜像订阅者（手机一直连着等）拿到的是还原后的画面：影子是绕过输出泵改的，要重发快照。
    func test_restore_resends_the_snapshot_to_mirror_subscribers() async throws {
        let original = TerminalSession()
        original.shadow.resize(cols: 83, rows: 25)
        original.feedOutput(text: head)
        let blob = TerminalCheckpointBlob.encode(snapshot: try original.shadow.snapshot())
        original.feedOutput(text: tail)

        let restored = TerminalSession()
        let subscriber = restored.mirrorTap.subscribe(id: UUID()) {}
        _ = subscriber.take(maxBytes: .max)   // 接回之前的那张（空屏）
        let backend = MockHeldBackend(replay: replay(blob: blob, cols: 83, rows: 25, output: Array(tail.utf8)))
        await restored.connect(using: backend)

        let phone = MirrorPhone(cols: 80, rows: 24)
        let assembly = SnapshotAssembly()
        while let chunk = subscriber.take(maxBytes: .max) {
            switch chunk {
            case .snapshot(let piece, let isFirst, let isLast):
                if let snapshot = assembly.append(piece, isFirst: isFirst, isLast: isLast) { phone.pump.applySnapshot(snapshot) }
            case .output(let bytes):
                phone.pump.route(bytes)
            }
        }
        XCTAssertEqual(phone.shadow.mirrorDifferences(from: original.shadow), [:])
        restored.dispose()
        original.dispose()
    }

    func test_replay_suppresses_replies_clipboard_and_tracked_markers() async {
        let query = Array("\u{1b}[c\u{1b}[6n\u{1b}]52;c;aGVsbG8=\u{07}".utf8)
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let session = TerminalSession()
        let backend = MockHeldBackend(replay: replay(blob: [], cols: 80, rows: 24, output: query))
        await session.connect(using: backend)
        // send 走的是 Task，给它一轮机会。
        try? await Task.sleep(for: .milliseconds(100))
        let written = await backend.written
        XCTAssertEqual(written, [], "回放期间不该往 shell 写任何东西")
        XCTAssertEqual(pasteboard.changeCount, before, "回放期间不该写剪贴板")

        // 回放结束后恢复正常应答（surface 还没建，由影子终端答）。
        session.feedOutput(text: "\u{1b}[6n")
        try? await Task.sleep(for: .milliseconds(100))
        let afterReplay = await backend.written
        XCTAssertEqual(afterReplay, [Data("\u{1b}[1;1R".utf8)], "回放结束后的查询要回答")
        session.dispose()
    }

    /// 回放是重启前的事：不能回答查询、不能再发一遍通知。
    func test_replay_of_program_status_sends_no_notifications_or_replies() async {
        let sequences = "\u{1b}]7501;state=blocked;kind=permission;app=claude-code\u{1b}\\"
            + "\u{1b}]7501;?\u{1b}\\"
            + "\u{1b}]777;notify;title;body\u{07}\u{1b}]9;done\u{07}"
        let session = TerminalSession()
        let backend = MockHeldBackend(replay: replay(blob: [], cols: 80, rows: 24, output: Array(sequences.utf8)))
        var attentions = 0
        session.attentionSink = { _ in attentions += 1 }
        await session.connect(using: backend)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(attentions, 0, "回放不发通知")
        let written = await backend.written
        XCTAssertEqual(written, [], "回放不回答查询")
        session.dispose()
    }

    func test_gap_inserts_a_visible_notice() async {
        let session = TerminalSession()
        let backend = MockHeldBackend(replay: replay(blob: [], cols: 80, rows: 24, hasGap: true, output: Array("tail".utf8)))
        await session.connect(using: backend)
        let text = session.snapshotScreen(lines: 50).lines.joined(separator: "\n").filter { !$0.isWhitespace && $0 != "\0" }
        XCTAssertTrue(text.contains("较早内容已丢弃"), text)
        XCTAssertTrue(text.contains("tail"), text)
        session.dispose()
    }
}

/// App 重启后的接回：读 holder 里存的归属，放回原来的窗口；已退出的 shell 不开窗口。
@MainActor
final class LocalShellRestorerTests: XCTestCase {
    private static let namespace = "integration-test"
    private let client = LocalShellAgentClient()

    override func tearDown() async throws {
        client.invalidate()
        try await super.tearDown()
    }

    /// 起一个 shell，写好归属，然后断开，等同于 App 退出后留下的会话。
    private func leaveSession(windowID: UUID?, ordinal: Int, exitFirst: Bool = false) async throws -> UUID {
        let id = UUID()
        let backend = LocalShellBackend(client: client, namespace: Self.namespace, sessionID: id, columns: 80, rows: 24)
        try await backend.connect()
        if let windowID {
            await backend.setAttributes(try JSONEncoder().encode(LocalShellSessionAttributes(windowID: windowID, ordinal: ordinal)))
        }
        if exitFirst {
            await backend.write(Data("sleep 0.3; exit\n".utf8))
            try await Task.sleep(for: .milliseconds(100))
        }
        await backend.detach()
        return id
    }

    private func terminate(_ id: UUID) async {
        await HolderProbe.terminate(id, client: client, namespace: Self.namespace)
    }

    /// 机器忙时 shell 启动就要一秒多，不能靠固定等待。
    private func waitUntilShellExited(_ id: UUID) async {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let reply = await HolderProbe.hello(id, client: client, namespace: Self.namespace)
            if reply?.exitStatus != nil { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("shell 没有退出")
    }

    func test_restore_groups_sessions_back_into_their_windows_in_order() async throws {
        let window = UUID()
        let second = try await leaveSession(windowID: window, ordinal: 2)
        let first = try await leaveSession(windowID: window, ordinal: 1)
        let orphan = try await leaveSession(windowID: nil, ordinal: 1)
        let exited = try await leaveSession(windowID: UUID(), ordinal: 1, exitFirst: true)
        await waitUntilShellExited(exited)

        let restorer = LocalShellRestorer(client: client, namespace: Self.namespace, gateTimeout: .milliseconds(50),
                                          reopenDelay: .milliseconds(10))
        var opened: [UUID: UUID] = [:]
        var openCount: [UUID: Int] = [:]
        restorer.install { windowID, firstPane in
            opened[windowID] = firstPane
            openCount[windowID, default: 0] += 1
        }
        await restorer.restore()
        XCTAssertGreaterThan(openCount[window] ?? 0, 1, "标签没被领走时要再开一次：第一次可能被正在关闭的旧窗口抢走")

        XCTAssertEqual(opened[window], first, "按序号，第一个标签开窗口")
        XCTAssertTrue(opened.values.contains(orphan), "没有归属的会话单独开窗口，不丢")
        XCTAssertFalse(opened.values.contains(exited), "已退出的 shell 不开窗口")

        // 窗口出现后领走自己的标签。
        let model = LocalShellWindowModel(startShell: { _ in })
        restorer.adoptPending(windowID: window, into: model)
        XCTAssertEqual(model.panes.map(\.id), [first, second])
        XCTAssertEqual(model.panes.map(\.ordinal), [1, 2])
        // 只领一次，不会重复开标签。
        restorer.adoptPending(windowID: window, into: model)
        XCTAssertEqual(model.panes.count, 2)

        for id in [first, second, orphan, exited] { await terminate(id) }
        for pane in model.panes { pane.session.dispose() }
    }

    /// 手机在等 `finished()`：恢复做完就放行，不等到超时之外。
    func test_finished_returns_after_restore_completes() async throws {
        let restorer = LocalShellRestorer(client: client, namespace: "integration-test-empty", gateTimeout: .milliseconds(50))
        await restorer.restore()
        await restorer.finished()
    }
}
