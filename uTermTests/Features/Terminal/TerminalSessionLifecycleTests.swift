import GhosttyTerminal
import XCTest
@testable import uTerm

/// 会话的生命周期与接回回放：关掉之后放得掉、回放途中按键不丢、影子替 surface 答的版本号和 surface 一样。
@MainActor
final class TerminalSessionLifecycleTests: XCTestCase {

    /// 关掉标签（`dispose`）之后，泵、镜像 tap、影子、surface 的 IO 都要放掉。原来泵的 tap 强持着镜像 tap、镜像 tap 借锁的
    /// 闭包又强持着泵，成了环，一个都放不掉（每个影子带着整段回滚，几 MB 到几十 MB）。
    func testDisposedSessionReleasesPumpTapShadowAndSurfaceIO() async {
        weak var weakSession: TerminalSession?
        weak var weakPump: TerminalOutputPump?
        weak var weakTap: TerminalMirrorTap?
        weak var weakShadow: ShadowTerminal?
        weak var weakIO: InMemoryTerminalSession?
        autoreleasepool {
            let session = TerminalSession()
            session.attentionSink = { _ in }
            session.feedOutput(text: "hello\r\n")
            weakSession = session
            weakPump = session.outputPump
            weakTap = session.mirrorTap
            weakShadow = session.shadow
            weakIO = session.surfaceIO
            session.dispose()
        }
        // 跳回主线程的那几下（擦屏、事件）排干。
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(weakSession, "会话没放掉")
        XCTAssertNil(weakPump, "输出泵没放掉")
        XCTAssertNil(weakTap, "镜像 tap 没放掉")
        XCTAssertNil(weakShadow, "影子终端没放掉")
        XCTAssertNil(weakIO, "surface 的 IO 没放掉")
    }

    /// 持有 PTY 的后端：回放一大段历史（每片之间让出主线程），回放途中用户的按键要照常发出。原来回放期间整个会话
    /// 关着「发给后端」，这期间的按键直接丢了。
    private actor HeldReplayBackend: HeldTerminalBackend {
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

    func testKeysTypedDuringHeldReplayAreSent() async throws {
        // 4 MiB 的历史：回放分 16 片，每片之间让出主线程。里面夹着查询（DA1）——历史里的查询不能答。
        var line = Array(repeating: UInt8(ascii: "x"), count: 1023) + [0x0A]
        line.replaceSubrange(0..<3, with: Array("\u{1B}[c".utf8))
        let history = Array([[UInt8]](repeating: line, count: 4096).joined())
        let replay = HolderReplay(
            hello: HolderHelloReply(version: 1, shellPID: 1, createdAt: 0, cols: 80, rows: 24, exitStatus: nil, attributes: []),
            checkpoint: HolderCheckpoint(offset: 0, cols: 80, rows: 24, hasGap: false, blob: []),
            output: history, endOffset: UInt64(history.count))
        let backend = HeldReplayBackend(replay: replay)
        let session = TerminalSession()
        session.attentionSink = { _ in }
        defer { session.dispose() }

        let connecting = Task { await session.connect(using: backend) }
        // 等回放开始（影子开始吃历史），这时按一个键。
        var sentDuringReplay = false
        for _ in 0..<10_000 {
            if session.shadow.totalFedBytes > 0, session.connectionState != .connected {
                session.sendHostBytes(Data("k".utf8))
                sentDuringReplay = true
                break
            }
            await Task.yield()
        }
        await connecting.value
        XCTAssertTrue(sentDuringReplay, "用例前提：在回放途中按到了键")
        XCTAssertEqual(session.connectionState, .connected)
        try await Task.sleep(for: .milliseconds(100))
        let written = await backend.written
        XCTAssertEqual(written, [Data("k".utf8)], "回放途中的按键要发出去，历史里的查询不答")
    }

    /// 重启后接回：检查点里存着的标题、回放字节里后来设的标题，接回完成时都要落到标签上（`shellTitle`），
    /// 不能等程序下一次设标题，更不能回落成「zsh 2」这种默认名。
    func testHeldReattachRestoresShellTitle() async throws {
        for (checkpointTitle, replayed, expected) in [("~/Workspace", "", "~/Workspace"),
                                                      ("~/Workspace", "\u{1B}]2;vim notes.md\u{07}", "vim notes.md")] {
            let source = ShadowTerminal(cols: 80, rows: 24, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
            source.feed(Data("\u{1B}]2;\(checkpointTitle)\u{07}prompt$ ".utf8))
            let blob = TerminalCheckpointBlob.encode(snapshot: try source.snapshot())
            let output = Array(replayed.utf8)
            let replay = HolderReplay(
                hello: HolderHelloReply(version: 1, shellPID: 1, createdAt: 0, cols: 80, rows: 24, exitStatus: nil, attributes: []),
                checkpoint: HolderCheckpoint(offset: 0, cols: 80, rows: 24, hasGap: false, blob: blob),
                output: output, endOffset: UInt64(output.count))
            let session = TerminalSession()
            session.attentionSink = { _ in }
            defer { session.dispose() }

            await session.connect(using: HeldReplayBackend(replay: replay))
            XCTAssertEqual(session.connectionState, .connected)
            for _ in 0..<100 where session.shellTitle != expected {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(session.shellTitle, expected, "接回后的标签标题")
        }
    }

    /// surface 不吃字节时由影子答查询：XTVERSION（`CSI > q`）要和 surface 答的一样（「ghostty <版本>」），不是 vt 默认的
    /// 「libghostty」。原来只有 iOS 设了。
    func testShadowAnswersXTVersionLikeTheSurface() async throws {
        let backend = MockBackend()
        let session = TerminalSession()
        session.attentionSink = { _ in }
        defer { session.dispose() }
        await session.connect(using: backend)
        XCTAssertFalse(session.outputPump.isFeedingSurface, "用例前提：surface 没建，影子在答")
        session.feedOutput(text: "\u{1B}[>q")
        var reply = ""
        for _ in 0..<100 {
            reply = await backend.writtenData.map { String(decoding: $0, as: UTF8.self) }.joined()
            if !reply.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let expected = TerminalScrollbackLimits.surfaceVersionReport
        XCTAssertTrue(expected.hasPrefix("ghostty "), expected)
        XCTAssertEqual(reply, "\u{1B}P>|\(expected)\u{1B}\\")
    }
}
