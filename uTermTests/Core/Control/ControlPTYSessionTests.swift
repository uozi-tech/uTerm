import Foundation
import XCTest
@testable import uTerm

/// 交互会话的纯逻辑：引导标记、输出清洗、按键表、会话缓冲与打码、登记处。
/// 不碰网络 —— PTY 通道是 `ScriptedPTY` 假货。
final class ControlPTYSessionTests: XCTestCase {

    // MARK: - 引导

    /// 引导行要远短于 macOS 规范模式的行长上限（1024 字节），且不含 tcsh 会做历史展开的 `!`。
    func testBootstrapLineIsShortAndShellNeutral() {
        let line = String(decoding: ControlPTYCommand.bootstrapLine, as: UTF8.self)
        XCTAssertLessThan(ControlPTYCommand.bootstrapLine.count, 512)
        XCTAssertFalse(line.contains("!"))
        XCTAssertTrue(line.hasPrefix(" "), "开头的空格让 shell 不记历史")
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "引导只能是一行")
        // 回显里的标记是拆开的，只有执行后打出来的才连在一起。
        XCTAssertFalse(line.contains("__UTERM_PTY_READY__"))
    }

    /// 命令按 base64 分行，每行远短于行长上限，以 `.` 结束，解回来与原文一致。
    func testPayloadRoundTripsAndKeepsLinesShort() throws {
        let command = "cd ~/vphone && sudo /bin/zsh -f ./bootstrap.zsh --only-root-entry\n"
            + "echo '多字节 ✓' \"$HOME\" \\ ! `id`\n" + String(repeating: "x", count: 3000)
        let text = String(decoding: ControlPTYCommand.payload(command), as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.removeLast(), "")
        XCTAssertEqual(lines.removeLast(), ".")
        XCTAssertTrue(lines.allSatisfy { $0.count <= 76 })
        let decoded = try XCTUnwrap(Data(base64Encoded: lines.joined()))
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), command)
    }

    func testBootstrapFilterDropsEverythingBeforeTheMarker() {
        var filter = PTYBootstrapFilter()
        // motd + 提示符 + 引导行的回显（标记是拆开的那种）都不该透出去。
        let echo = String(decoding: ControlPTYCommand.bootstrapLine, as: UTF8.self)
        var step = filter.feed(Data("Last login: Tue\r\n% \(echo)\r\n".utf8))
        XCTAssertTrue(step.deliver.isEmpty)
        XCTAssertFalse(step.becameReady)
        // 标记被拆在两块里。
        step = filter.feed(Data("\r\n__UTERM_PTY_RE".utf8))
        XCTAssertFalse(step.becameReady)
        step = filter.feed(Data("ADY__\r".utf8))
        XCTAssertFalse(step.becameReady, "换行还没到，再等一块")
        step = filter.feed(Data("\nhello".utf8))
        XCTAssertTrue(step.becameReady)
        XCTAssertEqual(String(decoding: step.deliver, as: UTF8.self), "hello")
        step = filter.feed(Data(" world".utf8))
        XCTAssertFalse(step.becameReady)
        XCTAssertEqual(String(decoding: step.deliver, as: UTF8.self), " world")
    }

    func testBootstrapFilterGivesUpAfterTheLimit() {
        var filter = PTYBootstrapFilter()
        _ = filter.feed(Data(count: PTYBootstrapFilter.limit + 1))
        XCTAssertTrue(filter.overflowed)
        XCTAssertFalse(filter.isReady)
    }

    // MARK: - 清洗

    func testCleanerStripsControlSequences() {
        let raw = "\u{1B}[1;32mgreen\u{1B}[0m \u{1B}]0;title\u{07}text\u{1B}[?2004h\u{1B}(B ok\r\n"
        XCTAssertEqual(PTYTextCleaner.clean(Data(raw.utf8)).text, "green text ok\n")
    }

    func testCleanerKeepsOnlyTheLastFrameOfACarriageReturnLine() {
        let raw = "progress 10%\rprogress 50%\rprogress 100%\r\ndone\r\n"
        XCTAssertEqual(PTYTextCleaner.clean(Data(raw.utf8)).text, "progress 100%\ndone\n")
    }

    func testCleanerAppliesBackspace() {
        XCTAssertEqual(PTYTextCleaner.clean(Data("abc\u{08}\u{08}x 好\u{08}了".utf8)).text, "ax 了")
    }

    /// 末尾不完整的控制序列 / UTF-8 字符不消费，留给下一次。
    func testCleanerHoldsBackIncompleteTails() {
        let partialEscape = PTYTextCleaner.clean(Data("ok\u{1B}[3".utf8))
        XCTAssertEqual(partialEscape.text, "ok")
        XCTAssertEqual(partialEscape.consumed, 2)

        var bytes = Array("好".utf8)
        bytes.removeLast()
        let partialChar = PTYTextCleaner.clean(Data(Array("a".utf8) + bytes))
        XCTAssertEqual(partialChar.text, "a")
        XCTAssertEqual(partialChar.consumed, 1)

        let lonelyCR = PTYTextCleaner.clean(Data("line\r".utf8))
        XCTAssertEqual(lonelyCR.consumed, 4, "单独的 \\r 要看下一个字节才知道是不是 \\r\\n")
        XCTAssertEqual(PTYTextCleaner.clean(Data("line\r".utf8), final: true).consumed, 5)
    }

    func testCleanerKeepsAPromptWithoutNewline() {
        XCTAssertEqual(PTYTextCleaner.clean(Data("[sudo] password for alice: ".utf8)).text,
                       "[sudo] password for alice: ")
    }

    // MARK: - 按键

    func testKeyNames() {
        XCTAssertEqual(PTYKeys.bytes(for: "enter"), "\r")
        XCTAssertEqual(PTYKeys.bytes(for: "Ctrl-C"), "\u{03}")
        XCTAssertEqual(PTYKeys.bytes(for: "ctrl+d"), "\u{04}")
        XCTAssertEqual(PTYKeys.bytes(for: "^z"), "\u{1A}")
        XCTAssertEqual(PTYKeys.bytes(for: "up"), "\u{1B}[A")
        XCTAssertNil(PTYKeys.bytes(for: "hyper-x"))
        XCTAssertNil(PTYKeys.bytes(for: "ctrl-1"))
    }

    func testPasswordPromptHeuristic() {
        for line in ["[sudo] password for alice:", "Password:", "Enter passphrase for key '/k':",
                     "请输入密码：", "root@db's password: "] {
            XCTAssertTrue(ControlPTYSession.looksLikePasswordPrompt(line), line)
        }
        for line in ["$", "Do you want to continue? [Y/n]", "password changed", "echo password"] {
            XCTAssertFalse(ControlPTYSession.looksLikePasswordPrompt(line), line)
        }
    }

    // MARK: - 会话

    func testSessionRunsTheBootstrapAndHidesTheNoise() throws {
        let pty = ScriptedPTY()
        let session = makeSession(command: "sudo whoami", pty: pty)
        XCTAssertEqual(pty.writes.first, ControlPTYCommand.bootstrapLine, "通道一开先写引导行")
        XCTAssertTrue(session.isBootstrapping)

        session.ingest(Data("Welcome to Ubuntu\r\n$ exec /bin/sh …\r\n\r\n__UTERM_PTY_READY__\r\n".utf8))
        XCTAssertFalse(session.isBootstrapping)
        XCTAssertEqual(pty.writes.last, ControlPTYCommand.payload("sudo whoami"), "就绪后写命令")

        session.ingest(Data("[sudo] password for root: ".utf8))
        let snapshot = session.snapshot(consume: true, includeScreen: true)
        XCTAssertEqual(snapshot.output, "[sudo] password for root: ")
        XCTAssertEqual(snapshot.promptLine, "[sudo] password for root:")
        XCTAssertTrue(snapshot.passwordPrompt)
        XCTAssertEqual(snapshot.screen, ["[sudo] password for root:"])
        XCTAssertEqual(session.snapshot(consume: true, includeScreen: false).output, "", "读过不再给")
    }

    func testSecretsAreScrubbedFromOutputAndScreen() throws {
        let pty = ScriptedPTY()
        let session = makeSession(command: nil, pty: pty)
        try session.writeSecret("hunter2")
        XCTAssertEqual(pty.writes.last, Data("hunter2\r".utf8))
        session.ingest(Data("echoed hunter2 back\r\n$ ".utf8))
        let snapshot = session.snapshot(consume: true, includeScreen: true)
        XCTAssertEqual(snapshot.output, "echoed ******** back\n$ ")
        XCTAssertFalse(snapshot.screen?.joined().contains("hunter2") ?? true)
    }

    func testWritesAfterTheEndFail() {
        let pty = ScriptedPTY()
        let session = makeSession(command: nil, pty: pty)
        session.ingest(Data("bye\r\n".utf8))
        session.finish(.exited(3))
        XCTAssertThrowsError(try session.write("x")) { error in
            XCTAssertEqual((error as? ControlFailure)?.code, .session_ended)
        }
        let snapshot = session.snapshot(consume: true, includeScreen: false)
        XCTAssertFalse(snapshot.running)
        XCTAssertEqual(snapshot.exitCode, 3)
        XCTAssertEqual(snapshot.endReason, "exited")
        XCTAssertEqual(snapshot.output, "bye\n", "结束后照样能读到最后的输出")
    }

    func testLocalCloseKeepsItsReason() {
        let pty = ScriptedPTY()
        let session = makeSession(command: nil, pty: pty)
        session.end(reason: "idle_timeout", message: "太久没人碰")
        XCTAssertTrue(pty.closed)
        session.finish(.closedLocally)
        let snapshot = session.snapshot(consume: false, includeScreen: false)
        XCTAssertEqual(snapshot.endReason, "idle_timeout")
        XCTAssertEqual(snapshot.endMessage, "太久没人碰")
    }

    func testTerminalQueriesAreAnsweredThroughThePTY() {
        let pty = ScriptedPTY()
        let session = makeSession(command: nil, pty: pty)
        session.ingest(Data("\u{1B}[6n".utf8))   // 问光标位置
        XCTAssertEqual(pty.writes.last.map { String(decoding: $0, as: UTF8.self) }, "\u{1B}[1;1R")
    }

    func testBufferOverflowDropsTheOldestBytes() {
        let session = makeSession(command: nil, pty: ScriptedPTY())
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 64 * 1024)
        for _ in 0..<20 { session.ingest(chunk) }
        let snapshot = session.snapshot(consume: true, includeScreen: false, maxBytes: 1000)
        XCTAssertGreaterThan(snapshot.droppedBytes, 0)
        XCTAssertTrue(snapshot.truncated)
        XCTAssertEqual(snapshot.output?.utf8.count, 1000)
    }

    // MARK: - 登记处

    @MainActor
    func testRegistryResolvesByPrefixAndReaps() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let registry = ControlPTYSessions(now: { clock })
        let a = makeSession(command: nil, pty: ScriptedPTY(), id: UUID(uuidString: "AAAA0000-0000-0000-0000-000000000001")!, now: clock)
        let b = makeSession(command: nil, pty: ScriptedPTY(), id: UUID(uuidString: "AAAB0000-0000-0000-0000-000000000002")!, now: clock)
        registry.add(a)
        registry.add(b)

        XCTAssertTrue(try registry.resolve("aaaa") === a)
        XCTAssertThrowsError(try registry.resolve("AAA")) { error in
            XCTAssertEqual((error as? ControlFailure)?.code, .session_ambiguous)
        }
        XCTAssertThrowsError(try registry.resolve("ffff")) { error in
            XCTAssertEqual((error as? ControlFailure)?.code, .session_not_found)
        }
        XCTAssertEqual(registry.runningCount(hostID: a.hostID), 2)

        // a 一直有人碰，b 没人碰 → 空闲回收只关 b。
        clock += ControlProtocol.sessionIdleSeconds + 1
        a.touch(clock)
        registry.reap()
        XCTAssertTrue(a.isRunning)
        XCTAssertFalse(b.isRunning)
        XCTAssertEqual(b.snapshot(consume: false, includeScreen: false).endReason, "idle_timeout")

        // 结束够久就从表里删掉。
        clock += ControlProtocol.endedSessionRetentionSeconds + 1
        a.touch(clock)
        XCTAssertEqual(registry.reap(), 1)
        XCTAssertTrue(registry.all.first === a)
    }

    // MARK: - 夹具

    private func makeSession(
        command: String?,
        pty: ScriptedPTY,
        id: UUID = UUID(),
        now: Date = Date()
    ) -> ControlPTYSession {
        let session = ControlPTYSession(
            id: id, hostName: "prod-web", hostID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            command: command, spec: PTYSpec(term: "xterm-256color", cols: 80, rows: 24), now: now)
        session.attach(pty)
        return session
    }
}

/// 记下写入、可被关掉的假 PTY。
nonisolated final class ScriptedPTY: PTYHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [Data] = []
    private var sizes: [(Int, Int)] = []
    private var isClosed = false
    /// 每次写入后回调（测试里用它模拟远端回话）。
    var onWrite: (@Sendable (Data) -> Void)?

    var writes: [Data] { lock.withLock { written } }
    var closed: Bool { lock.withLock { isClosed } }
    var text: String { writes.map { String(decoding: $0, as: UTF8.self) }.joined() }

    func write(_ data: Data) {
        lock.withLock { written.append(data) }
        onWrite?(data)
    }

    func resize(cols: Int, rows: Int) {
        lock.withLock { sizes.append((cols, rows)) }
    }

    func close() {
        lock.withLock { isClosed = true }
    }
}
