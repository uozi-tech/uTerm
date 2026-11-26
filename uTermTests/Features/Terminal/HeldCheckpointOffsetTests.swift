import XCTest
@testable import uTerm

/// 检查点声称的字节位置必须是保持进程（holder）那条输出流上的位置。
///
/// 用户报告（2026-11-26）：Mac 本机终端里跑 Claude Code，输入框里有时凭空多出 `3;3H`、`?2026l` 这样的字，
/// 「切换会话」和「更新后重启 App」之后见到。这两串正好是 Claude Code 每一帧结尾的两个序列去掉开头的 `ESC [`：
/// 光标停回输入框（`ESC [ 3 ; 3 H`）、结束同步输出（`ESC [ ? 2026 l`）。
///
/// 原因：检查点的位置是数输出泵的 tap 数出来的（`TerminalHeldCheckpoints.noteFed`），而 tap 里除了后端来的字节，
/// 还有本端加进泵的字节——Code 标签页（和历史窗口「继续这个会话」、命令行 `terminal open -- 命令`）起会话时改写回显
/// （`TrackedRunEchoRewrite`，一百多字节），还有清屏（`clearOutput`，11 字节，现在只有测试在调）。这些字节不在
/// holder 的输出流里，位置于是多算了它们的长度。重启后接回时 holder 从检查点声称的位置往后补，检查点之后的头一百多个
/// 字节被跳过，剩下的从一个序列的半中间开始，被当成文字画在光标所在的地方——Claude Code 的光标就停在输入框里。
/// 这些字只在画面上，没有发给程序。
@MainActor
final class HeldCheckpointOffsetTests: XCTestCase {
    /// 假的保持进程，和真的记同一本账（`HolderServer`）：程序的输出按先后记进日志，位置从 0 起；App 交来的检查点原样存着；
    /// 接入时补「检查点 + 它声称的位置之后的字节」。
    private final class FakeHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [UInt8] = []
        private var stored: HolderCheckpoint?
        private var storedCount = 0

        var logCount: Int { lock.withLock { log.count } }
        var checkpoint: HolderCheckpoint? { lock.withLock { stored } }
        var checkpointCount: Int { lock.withLock { storedCount } }

        func appendOutput(_ bytes: [UInt8]) {
            lock.withLock { log.append(contentsOf: bytes) }
        }

        func store(_ checkpoint: HolderCheckpoint) {
            lock.withLock {
                stored = checkpoint
                storedCount += 1
            }
        }

        /// `HolderServer.attach` 的规则。
        func replay() -> HolderReplay {
            lock.withLock {
                let start = Int(stored?.offset ?? 0)
                return HolderReplay(
                    hello: HolderHelloReply(version: 1, shellPID: 1, createdAt: 0, cols: 120, rows: 30, exitStatus: nil,
                                            attributes: []),
                    checkpoint: stored ?? HolderCheckpoint(offset: 0, cols: 120, rows: 30, hasGap: false, blob: []),
                    output: start < log.count ? Array(log[start...]) : [],
                    endOffset: UInt64(log.count))
            }
        }
    }

    /// 连着假 holder 的后端。检查点走真的 `HolderLink` / `HolderConnection`（一对 socket），另一头把帧切出来存进假 holder。
    private actor FakeHeldBackend: HeldTerminalBackend {
        nonisolated let outputItems: AsyncStream<TerminalOutputItem>
        nonisolated let exitStream: AsyncStream<Void>
        nonisolated let holderLink = HolderLink()
        private let output: AsyncStream<TerminalOutputItem>.Continuation
        private let holder: FakeHolder
        private var connection: HolderConnection?
        private var peer: DispatchSourceRead?
        private var attached = false
        private(set) var written: [Data] = []
        /// 程序（shell）收到输入后的反应：返回它接着输出的字节。
        private var respond: (@Sendable (Data) -> [UInt8])?

        init(holder: FakeHolder) {
            self.holder = holder
            (outputItems, output) = AsyncStream.makeStream(of: TerminalOutputItem.self)
            exitStream = AsyncStream { _ in }
        }

        func setResponder(_ respond: @escaping @Sendable (Data) -> [UInt8]) {
            self.respond = respond
        }

        func connect() async throws {
            var fds: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
            let connection = HolderConnection(FileHandle(fileDescriptor: fds[0], closeOnDealloc: true))
            connection.start()
            holderLink.install(connection)
            self.connection = connection

            let peerFD = fds[1]
            let holder = holder
            let reader = FrameBox()
            let source = DispatchSource.makeReadSource(fileDescriptor: peerFD, queue: DispatchQueue(label: "fake-holder"))
            source.setEventHandler {
                var buffer = [UInt8](repeating: 0, count: 256 * 1024)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(peerFD, $0.baseAddress, $0.count) }
                guard count > 0 else {
                    source.cancel()
                    return
                }
                buffer.withUnsafeBytes { reader.reader.append(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
                while let frame = try? reader.reader.next() {
                    guard frame.kind == .checkpoint, var checkpoint = HolderCheckpoint(decoding: frame.payload) else { continue }
                    checkpoint.hasGap = false
                    holder.store(checkpoint)
                }
            }
            source.setCancelHandler { Darwin.close(peerFD) }
            source.resume()
            peer = source
            attached = true
        }

        func takeReplay() -> HolderReplay? { holder.replay() }

        /// 程序输出了一段：holder 记进日志；有客户端接着就转给它。
        func emit(_ bytes: [UInt8]) {
            holder.appendOutput(bytes)
            if attached { output.yield(.bytes(Data(bytes))) }
        }

        func emit(_ text: String) { emit(Array(text.utf8)) }

        func write(_ data: Data) async {
            written.append(data)
            if let reply = respond?(data), !reply.isEmpty { emit(reply) }
        }

        func resize(cols: UInt16, rows: UInt16) async {}

        func close() async { await detach() }

        /// App 走了：之后的输出只进 holder 的日志。
        func detach() async {
            attached = false
            holderLink.install(nil)
            connection?.close()
            connection = nil
            output.finish()
        }
    }

    private final class FrameBox: @unchecked Sendable {
        var reader = HolderFrameReader()
    }

    private func wait(_ timeout: TimeInterval = 10, for condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func makeSession() -> TerminalSession {
        let session = TerminalSession()
        session.attentionSink = { _ in }
        return session
    }

    /// 清屏往泵里加了 11 个字节，它们不在 holder 的输出流里：检查点的位置不能把它们算进去。
    func testCheckpointOffsetDoesNotCountBytesTheAppRoutedItself() async throws {
        let holder = FakeHolder()
        let backend = FakeHeldBackend(holder: holder)
        let session = makeSession()
        defer { session.dispose() }
        await session.connect(using: backend)
        XCTAssertEqual(session.connectionState, .connected)

        await backend.emit("% ls\r\nfile-a  file-b\r\n% ")
        let fedBefore = await wait { session.shadow.totalFedBytes == holder.logCount }
        XCTAssertTrue(fedBefore)
        session.clearOutput()
        let local = session.shadow.totalFedBytes - holder.logCount
        XCTAssertEqual(local, 11, "用例前提：清屏往泵里加了本端的字节")
        await backend.emit("echo hi\r\nhi\r\n% ")
        let fedAfter = await wait { session.shadow.totalFedBytes == holder.logCount + local }
        XCTAssertTrue(fedAfter)

        session.saveHeldCheckpointNow()
        let saved = await wait { holder.checkpointCount > 0 }
        XCTAssertTrue(saved, "退出时的检查点没到 holder")
        let checkpoint = try XCTUnwrap(holder.checkpoint)
        XCTAssertEqual(checkpoint.offset, UInt64(holder.logCount),
                       "检查点的位置要是 holder 输出流上的位置；多出来的正好是本端加的 \(local) 个字节")
        await backend.detach()
    }

    /// Claude Code 那一屏：清屏后画输入框，光标停在输入框里（第 3 行第 3 列）。
    private nonisolated static let claudeScreen = "\u{1B}[?2004h\u{1B}[?1004h\u{1B}[?2031h\u{1B}[2J\u{1B}[3J\u{1B}[H\r\n"
        + String(repeating: "─", count: 60) + "\r\n❯ \r\n" + String(repeating: "─", count: 60)
        + "\r\n  ? for shortcuts\u{1B}[3;3H"

    private enum Stray: String, CaseIterable {
        case cursorHome = "3;3H"
        case endOfSync = "?2026l"
    }

    /// Claude Code 的一帧：开始同步输出、藏光标、改一行、光标停回输入框、显示光标、结束同步输出。
    /// `skipped`：接回时被跳过的字节数。往改的那一行后面补空格，让这一帧里 `stray` 那个序列的 `ESC [` 正好是被跳过的最后两个字节。
    private static func claudeFrame(skipping skipped: Int, leaving stray: Stray) -> String? {
        let head = "\u{1B}[?2026h\u{1B}[?25l\u{1B}[6;1H\u{1B}[38;2;215;119;87m✻\u{1B}[39m Thinking…"
        let park = "\u{1B}[3;3H", show = "\u{1B}[?25h", end = "\u{1B}[?2026l"
        let before: String
        switch stray {
        case .cursorHome: before = head
        case .endOfSync: before = head + park + show
        }
        let padding = skipped - 2 - before.utf8.count
        guard padding >= 0 else { return nil }
        let padded = head + String(repeating: " ", count: padding)
        return padded + park + show + end
    }

    /// Code 标签页里起一个 Claude Code 会话（改写回显往泵里加字节），退出 App，这期间 Claude Code 画了一帧，再打开 App 接回：
    /// 画面要和「那一帧照常画上去」一样，输入框里不能多出字。
    func testReattachAfterCodeTabSessionLeavesNoStrayBytesInTheInputBox() async throws {
        for stray in Stray.allCases {
            let holder = FakeHolder()
            let backend = FakeHeldBackend(holder: holder)
            let first = makeSession()
            await first.connect(using: backend)

            // shell：提示符两行（路径一行、`❯ ` 一行），行编辑器起来时开括号粘贴。收到打进来的那一行就回显、
            // 跑 printf 打出开始标记，然后 Claude Code 起来画它的那一屏。
            await backend.setResponder { input in
                let line = String(decoding: input, as: UTF8.self)
                guard let marker = line.range(of: "6973;S;"), line.hasSuffix("\r") else { return [] }
                let id = line[marker.upperBound...].prefix { $0 != "\\" }
                let echo = String(line.dropLast())
                return Array((echo + "\r\n\u{1B}[?2004l\u{1B}]6973;S;\(id)\u{07}" + Self.claudeScreen).utf8)
            }
            await backend.emit("\r\n~/Workspace/app\r\n\u{1B}[?2004h❯ ")
            first.startCodeCommand("cd -- '/Users/me/Workspace/app' && claude --resume 0b0e5f3a-1c2d-4e5f-8a9b-0c1d2e3f4a5b")
            let started = await wait { first.trackedRun?.phase == .running && first.shadow.cursor == .init(x: 2, y: 2, pendingWrap: false, visible: true) }
            XCTAssertTrue(started, "Claude Code 没起来：\(first.shadow.viewportText())")
            XCTAssertFalse(first.shadow.viewportText().contains("6973"), "用例前提：回显改写过了")
            let local = first.shadow.totalFedBytes - holder.logCount
            XCTAssertGreaterThan(local, 0, "用例前提：改写回显往泵里加了本端的字节")

            // 退出 App：存最后一张检查点，断开。
            first.saveHeldCheckpointNow()
            let saved = await wait { holder.checkpointCount > 0 }
            XCTAssertTrue(saved, "退出时的检查点没到 holder")
            let checkpoint = try XCTUnwrap(holder.checkpoint)
            let streamPosition = holder.logCount
            first.dispose()
            await backend.detach()

            // App 不在的时候 Claude Code 画了一帧。
            let frame = try XCTUnwrap(Self.claudeFrame(skipping: local, leaving: stray), "帧比本端加的字节还长，凑不出用例")
            await backend.emit(frame)

            // 应当看到的画面：检查点那一屏接着画这一帧。
            let snapshot = try XCTUnwrap(TerminalCheckpointBlob.decode(checkpoint.blob))
            let expected = try ShadowTerminal(snapshot: snapshot, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
            expected.feed(Data(frame.utf8), asHistory: true)

            // 再打开 App：新的会话接回同一个 holder。
            let second = makeSession()
            let reattached = FakeHeldBackend(holder: holder)
            await second.connect(using: reattached)
            XCTAssertEqual(second.connectionState, .connected)
            let lines = second.shadow.viewportText().components(separatedBy: "\n")
            XCTAssertEqual(lines.count > 2 ? lines[2] : "", "❯",
                           "输入框那一行多出了字（\(stray.rawValue)）：检查点声称的位置 \(checkpoint.offset)，"
                           + "holder 输出流上的位置 \(streamPosition)，接回时跳过了 \(Int(checkpoint.offset) - streamPosition) 个字节")
            XCTAssertEqual(second.shadow.viewportText(), expected.viewportText())
            XCTAssertEqual(checkpoint.offset, UInt64(streamPosition))
            second.dispose()
            await reattached.detach()
        }
    }
}
