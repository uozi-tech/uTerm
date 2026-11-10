import XCTest
@testable import uTerm

/// 远控镜像走二进制快照之后的那条链：`TerminalMirrorTap`（Mac 端）→ 快照分段（`RemoteTerminalSnapshotPiece`）→
/// 接收端拼回（`SnapshotAssembly`）→ 输出泵 `applySnapshot` / 实时字节 → 接收端的影子终端。
/// 「手机端」在这里就是另一台影子终端 + 一台泵；两边读到的画面必须一致。不建窗口、不走网络
/// （经真实连接的在 `RemoteHostServerTests` / `RemoteEndToEndTests`）。
@MainActor
final class TerminalMirrorSnapshotTests: XCTestCase {

    /// 接收端：影子终端 + 泵（surface 不建，泵只喂影子）。
    private final class Receiver {
        let shadow = ShadowTerminal(cols: 80, rows: 24, options: TerminalScrollbackLimits(lines: 3_000).shadowOptions)
        let assembly = SnapshotAssembly()
        private(set) var snapshots = 0
        private(set) var outputBytes = 0
        private lazy var pump = TerminalOutputPump(shadow: shadow, surface: NullSurface())

        /// 取走订阅者攒着的全部数据，按到达顺序交给泵。`pieceBytes` 小于快照时快照会分成多段。
        func drain(_ subscriber: TerminalMirrorTap.Subscriber, pieceBytes: Int = 16 * 1024) {
            while let chunk = subscriber.take(maxBytes: pieceBytes) {
                switch chunk {
                case .snapshot(let piece, let isFirst, let isLast):
                    // 过一遍线上的编码，和连接上发的一样。
                    let wire = RemoteTerminalSnapshotPiece.encode(piece, isFirst: isFirst, isLast: isLast)
                    guard let decoded = RemoteTerminalSnapshotPiece.decode(wire) else { return XCTFail("快照段解不开") }
                    if let snapshot = assembly.append(decoded.data, isFirst: decoded.isFirst, isLast: decoded.isLast) {
                        snapshots += 1
                        pump.applySnapshot(snapshot)
                    }
                case .output(let bytes):
                    outputBytes += bytes.count
                    pump.route(bytes)
                }
            }
        }
    }

    private final class NullSurface: TerminalSurfaceSink, @unchecked Sendable {
        func receive(_ data: Data) {}
        func receiveReplay(_ data: Data) {}
        func discardPendingOutput() -> Int { 0 }
        func setOutputBacklogHandler(highWater: Int, lowWater: Int, _ handler: (@Sendable (Bool) -> Void)?) {}
    }

    private var session: TerminalSession!

    override func setUp() async throws {
        session = TerminalSession()
        session.attentionSink = { _ in }
    }

    override func tearDown() async throws {
        session.dispose()
        session = nil
    }

    private func assertMirrored(_ receiver: Receiver, file: StaticString = #filePath, line: UInt = #line) {
        let mac = session.shadow
        XCTAssertEqual(receiver.shadow.viewportText(), mac.viewportText(), "视口不同", file: file, line: line)
        XCTAssertEqual(receiver.shadow.totalRows, mac.totalRows, "总行数不同", file: file, line: line)
        XCTAssertEqual(receiver.shadow.cursor, mac.cursor, "光标不同", file: file, line: line)
        XCTAssertEqual(receiver.shadow.isOnAlternateScreen, mac.isOnAlternateScreen, file: file, line: line)
        XCTAssertEqual(receiver.shadow.size.cols, mac.size.cols, file: file, line: line)
        XCTAssertEqual(receiver.shadow.size.rows, mac.size.rows, file: file, line: line)
        XCTAssertEqual(receiver.shadow.title, mac.title, file: file, line: line)
    }

    private func history(_ range: Range<Int>) -> String {
        range.map { "\u{1B}[3\($0 % 7 + 1)mline \($0) 中文 👍🏽 一行比较长的输出会折到下一行去看看软折行对不对\u{1B}[0m\r\n" }.joined()
    }

    // MARK: 用例

    /// 中途接入：先收一张快照，之后的字节原样跟上；两边一致。
    func test_attach_mid_session_then_stream_stays_identical() {
        session.feedOutput(text: "\u{1B}]0;build\u{07}" + history(0..<200))
        let receiver = Receiver()
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}

        receiver.drain(subscriber)
        XCTAssertEqual(receiver.snapshots, 1)
        XCTAssertEqual(receiver.outputBytes, 0, "接入时只有快照")
        assertMirrored(receiver)

        session.feedOutput(text: history(200..<230) + "\u{1B}[?1049h\u{1B}[3;5Hfull screen")
        receiver.drain(subscriber)
        XCTAssertEqual(receiver.snapshots, 1, "之后是原样字节，不再发快照")
        XCTAssertGreaterThan(receiver.outputBytes, 0)
        assertMirrored(receiver)
    }

    /// 接入的那一刻终端停在半个转义序列 / 半个 UTF-8 字符里：快照带着它，后半截到了照样接得上。
    func test_snapshot_taken_mid_escape_sequence_continues_correctly() {
        let bytes = Array("ok \u{1B}[38;2;215;119;87m橙色\u{1B}[0m 中".utf8)
        // 切在真彩 SGR 中间，再切在「中」的 UTF-8 中间。
        session.receiveOutputForTesting(Data(bytes[0..<9]))
        let receiver = Receiver()
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        receiver.drain(subscriber)

        session.receiveOutputForTesting(Data(bytes[9..<(bytes.count - 1)]))
        receiver.drain(subscriber)
        session.receiveOutputForTesting(Data(bytes[(bytes.count - 1)...]))
        receiver.drain(subscriber)

        XCTAssertEqual(session.shadow.recentLines(1).lines, ["ok 橙色 中"])
        assertMirrored(receiver)
    }

    /// 大快照切成很多段发，接收端拼回来还是那一张。
    func test_large_snapshot_is_delivered_in_pieces() {
        session.feedOutput(text: history(0..<1_500))
        let receiver = Receiver()
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        XCTAssertGreaterThan(subscriber.pendingBytes, 64 * 1024, "用例前提：快照比一段大得多")

        receiver.drain(subscriber, pieceBytes: 4 * 1024)
        XCTAssertEqual(receiver.snapshots, 1)
        XCTAssertEqual(subscriber.pendingBytes, 0)
        assertMirrored(receiver)
    }

    /// 订阅者一直不取（对端太慢）：积压超限后丢弃并改发快照，最终仍一致；没发完的旧快照也被新的顶掉。
    func test_overflow_drops_backlog_and_resyncs_with_snapshot() {
        let receiver = Receiver()
        let subscriber = session.mirrorTap.subscribe(id: UUID(), limit: 8 * 1024) {}
        receiver.drain(subscriber)

        session.feedOutput(text: history(0..<50))
        // 只取走新快照的第一段，然后又来一轮超限的输出。
        _ = subscriber.take(maxBytes: 16)
        session.feedOutput(text: history(50..<400))

        receiver.drain(subscriber)
        assertMirrored(receiver)
        XCTAssertGreaterThanOrEqual(receiver.snapshots, 2)
    }

    /// 清屏走泵的分流，镜像端看到的是同样的字节。
    func test_clear_output_reaches_the_mirror() {
        session.feedOutput(text: history(0..<40))
        let receiver = Receiver()
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        receiver.drain(subscriber)

        session.clearOutput()
        session.feedOutput(text: "fresh\r\n")
        receiver.drain(subscriber)

        XCTAssertEqual(session.shadow.recentLines(5).lines, ["fresh"])
        assertMirrored(receiver)
    }

    /// 尺寸变了（远端接管、窗格改大小）：订阅者改收一张新尺寸下的快照。
    func test_grid_change_resends_a_snapshot_at_the_new_size() {
        session.feedOutput(text: history(0..<30))
        let receiver = Receiver()
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        receiver.drain(subscriber)

        session.shadow.resize(cols: 57, rows: 23)
        session.shadowGridDidChange()
        receiver.drain(subscriber)

        XCTAssertEqual(receiver.snapshots, 2)
        XCTAssertEqual(receiver.shadow.size.cols, 57)
        assertMirrored(receiver)
    }

    /// 没有订阅者时 tap 什么也不攒；退订之后也一样。
    func test_tap_without_subscribers_is_inert() {
        XCTAssertFalse(session.mirrorTap.hasSubscribers)
        session.feedOutput(text: history(0..<10))
        let id = UUID()
        let subscriber = session.mirrorTap.subscribe(id: id) {}
        XCTAssertTrue(session.mirrorTap.hasSubscribers)
        session.mirrorTap.unsubscribe(id: id)
        _ = subscriber.take(maxBytes: .max)
        session.feedOutput(text: history(10..<20))
        XCTAssertEqual(subscriber.pendingBytes, 0)
        XCTAssertFalse(session.mirrorTap.hasSubscribers)
    }

    // MARK: 协议的小件

    func test_snapshot_piece_flags_round_trip() {
        for (isFirst, isLast) in [(true, false), (false, false), (false, true), (true, true)] {
            let wire = RemoteTerminalSnapshotPiece.encode(Data([1, 2, 3]), isFirst: isFirst, isLast: isLast)
            let decoded = RemoteTerminalSnapshotPiece.decode(wire)
            XCTAssertEqual(decoded?.data, Data([1, 2, 3]))
            XCTAssertEqual(decoded?.isFirst, isFirst)
            XCTAssertEqual(decoded?.isLast, isLast)
        }
        XCTAssertNil(RemoteTerminalSnapshotPiece.decode(Data()))
    }

    /// 没见过开头的中间段丢掉；新快照的第一段顶掉没收完的旧快照。
    func test_assembly_drops_orphans_and_restarts_on_a_new_first_piece() {
        let assembly = SnapshotAssembly()
        XCTAssertNil(assembly.append(Data([9]), isFirst: false, isLast: true), "没有开头：丢掉")
        XCTAssertNil(assembly.append(Data([1]), isFirst: true, isLast: false))
        XCTAssertNil(assembly.append(Data([7]), isFirst: true, isLast: false), "新的一张顶掉旧的")
        XCTAssertEqual(assembly.append(Data([8]), isFirst: false, isLast: true), Data([7, 8]))
        XCTAssertNil(assembly.append(Data([5]), isFirst: false, isLast: true), "收齐之后清空")
    }

    /// 握手里的引擎版本：一样才镜像；老版本不报，同样不行。
    func test_engine_version_must_match_for_mirroring() throws {
        XCTAssertTrue(RemoteTerminalEngine.matches(TerminalEngineVersion.current))
        XCTAssertFalse(RemoteTerminalEngine.matches(nil))
        XCTAssertFalse(RemoteTerminalEngine.matches("ghostty-ffffffff+p0000/snapshot-9"))

        // 新键不影响老版本解握手消息：不带它的 JSON 解出来是 nil。
        var hello = RemoteHello(version: 1, deviceID: UUID(), deviceName: "Mac", ephemeralKey: Data(), staticKey: Data())
        XCTAssertNil(try JSONDecoder().decode(RemoteHello.self, from: JSONEncoder().encode(hello)).terminalEngine)
        hello.terminalEngine = TerminalEngineVersion.current
        XCTAssertEqual(try JSONDecoder().decode(RemoteHello.self, from: JSONEncoder().encode(hello)).terminalEngine,
                       TerminalEngineVersion.current)
    }
}
