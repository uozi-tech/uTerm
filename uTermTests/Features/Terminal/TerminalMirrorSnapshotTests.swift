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
        /// 收到的快照里有几张是回放流（Mac 对快照格式不互认的设备改发的）。
        private(set) var replays = 0
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
                        if RemoteTerminalReplay.decode(snapshot) != nil { replays += 1 }
                        // 和 `RemoteTerminalBackend` 一样：回放流先在本机重画成快照。
                        guard let restorable = RemoteTerminalReplay.restorable(snapshot) else { return XCTFail("回放流重画不出来") }
                        pump.applySnapshot(restorable)
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

    /// `checksTitle`：回放流不带标题（标题由之后的字节或程序状态带），走回放流的用例不核。
    private func assertMirrored(_ receiver: Receiver, checksTitle: Bool = true,
                                file: StaticString = #filePath, line: UInt = #line) {
        let mac = session.shadow
        XCTAssertEqual(receiver.shadow.viewportText(), mac.viewportText(), "视口不同", file: file, line: line)
        if mac.totalRows - mac.size.rows <= RemoteConstants.snapshotScrollback {
            XCTAssertEqual(receiver.shadow.totalRows, mac.totalRows, "总行数不同", file: file, line: line)
        } else {
            // 快照只带最近约 `snapshotScrollback` 行回滚：接收端少了上面那段，留下的与 Mac 的最后几行逐行相同。
            XCTAssertLessThan(receiver.shadow.totalRows, mac.totalRows, "快照应当裁掉早的回滚", file: file, line: line)
            let kept = receiver.shadow.totalRows
            XCTAssertEqual(receiver.shadow.recentLines(kept).lines.suffix(kept - 1), mac.recentLines(kept).lines.suffix(kept - 1),
                           "留下的回滚与 Mac 的最后几行不同", file: file, line: line)
        }
        XCTAssertEqual(receiver.shadow.cursor, mac.cursor, "光标不同", file: file, line: line)
        XCTAssertEqual(receiver.shadow.isOnAlternateScreen, mac.isOnAlternateScreen, file: file, line: line)
        XCTAssertEqual(receiver.shadow.size.cols, mac.size.cols, file: file, line: line)
        XCTAssertEqual(receiver.shadow.size.rows, mac.size.rows, file: file, line: line)
        if checksTitle { XCTAssertEqual(receiver.shadow.title, mac.title, file: file, line: line) }
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

    /// 镜像快照只带最近约 `RemoteConstants.snapshotScrollback` 行回滚（整段回滚太大，窄链路上追不上）；
    /// 屏幕、光标、标题照旧一致，Mac 自己的回滚不受影响。
    func test_mirror_snapshot_keeps_only_recent_scrollback() throws {
        let limit = RemoteConstants.snapshotScrollback
        session.feedOutput(text: "\u{1B}]0;long\u{07}" + history(0..<3_000))
        let mac = session.shadow
        XCTAssertGreaterThan(mac.totalRows - mac.size.rows, 2 * limit, "用例前提：Mac 的回滚远超上限")
        let full = try mac.snapshot()
        let trimmed = try mac.snapshot(scrollbackLines: limit)
        XCTAssertLessThan(trimmed.count * 2, full.count, "裁过的快照应当小得多")

        let receiver = Receiver()
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        receiver.drain(subscriber)
        XCTAssertEqual(receiver.snapshots, 1)
        let kept = receiver.shadow.totalRows - receiver.shadow.size.rows
        XCTAssertLessThanOrEqual(kept, limit)
        XCTAssertGreaterThan(kept, limit / 2, "按页裁，留下的应当接近上限")
        XCTAssertGreaterThan(mac.totalRows - mac.size.rows, 2 * limit, "Mac 自己的回滚不受影响")
        assertMirrored(receiver)

        // 之后的实时字节照常接上。
        session.feedOutput(text: history(3_000..<3_010))
        receiver.drain(subscriber)
        XCTAssertEqual(receiver.snapshots, 1)
        assertMirrored(receiver)
    }

    /// 回滚不超上限时就是整张快照；备用屏上（读到的行数是备用屏的）照样裁主屏的回滚。
    func test_trimmed_snapshot_on_short_history_and_on_the_alternate_screen() throws {
        let limit = RemoteConstants.snapshotScrollback
        session.feedOutput(text: history(0..<20))
        let mac = session.shadow
        XCTAssertEqual(try mac.snapshot(scrollbackLines: limit), try mac.snapshot())

        session.feedOutput(text: history(20..<3_000) + "\u{1B}[?1049h\u{1B}[2;3Hvim")
        XCTAssertTrue(mac.isOnAlternateScreen)
        let restored = try ShadowTerminal(snapshot: try mac.snapshot(scrollbackLines: limit),
                                          options: TerminalScrollbackLimits(lines: 10_000).shadowOptions)
        XCTAssertEqual(restored.viewportText(), mac.viewportText())
        XCTAssertEqual(restored.cursor, mac.cursor)
        let leave = Data("\u{1B}[?1049l".utf8)
        restored.feed(leave)
        session.receiveOutputForTesting(leave)
        XCTAssertLessThanOrEqual(restored.totalRows - restored.size.rows, limit, "主屏的回滚也裁了")
        XCTAssertGreaterThan(mac.totalRows - mac.size.rows, 2 * limit)
        XCTAssertEqual(restored.viewportText(), mac.viewportText())
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

    /// 设备的引擎快照格式和 Mac 不互认（`RemoteFeature.terminalReplay`）：快照换成回放流，设备按本机引擎重画；
    /// 画面照样一致，之后的原样字节接着画，改尺寸、积压溢出后补发的也是回放流。
    func test_replay_subscriber_mirrors_through_a_redrawn_snapshot() {
        session.feedOutput(text: history(0..<200) + "\u{1B}[3;7H")
        let receiver = Receiver()
        let subscriber = session.mirrorTap.subscribe(id: UUID(), format: .replay) {}

        receiver.drain(subscriber, pieceBytes: 4 * 1024)
        XCTAssertEqual(receiver.snapshots, 1)
        XCTAssertEqual(receiver.replays, 1, "发的是回放流，不是二进制快照")
        assertMirrored(receiver, checksTitle: false)

        session.feedOutput(text: history(200..<230) + "\u{1B}[?1049h\u{1B}[3;5Hfull screen")
        receiver.drain(subscriber)
        XCTAssertEqual(receiver.snapshots, 1, "之后是原样字节")
        assertMirrored(receiver, checksTitle: false)

        // 全屏程序里改尺寸：补发的那张也是回放流，备用屏、光标都在。
        session.shadow.resize(cols: 64, rows: 18)
        session.shadowGridDidChange()
        receiver.drain(subscriber)
        XCTAssertEqual(receiver.replays, receiver.snapshots)
        XCTAssertGreaterThanOrEqual(receiver.snapshots, 2, "尺寸变了要补发")
        assertMirrored(receiver, checksTitle: false)
    }

    /// 同一刻要快照的有发二进制的、也有发回放流的：各拿各的。
    func test_binary_and_replay_subscribers_share_one_capture() {
        session.feedOutput(text: history(0..<50))
        let binary = Receiver(), replay = Receiver()
        let binarySubscriber = session.mirrorTap.subscribe(id: UUID()) {}
        let replaySubscriber = session.mirrorTap.subscribe(id: UUID(), format: .replay) {}
        binary.drain(binarySubscriber)
        replay.drain(replaySubscriber)
        XCTAssertEqual(binary.replays, 0)
        XCTAssertEqual(replay.replays, 1)
        assertMirrored(binary)
        assertMirrored(replay, checksTitle: false)
    }

    // MARK: 协议的小件

    /// 快照格式互认就发二进制；不互认时两端都认得回放流才改发回放流，否则不接入。
    func test_snapshot_format_falls_back_to_replay_only_when_both_sides_take_it() {
        let other = "ghostty-ffffffff+p0000/snapshot-9"
        XCTAssertEqual(RemoteTerminalEngine.snapshotFormat(peer: TerminalEngineVersion.current, replayBothWays: true), .binary,
                       "互认时仍发二进制（不多花生成回放流的时间）")
        XCTAssertEqual(RemoteTerminalEngine.snapshotFormat(peer: TerminalEngineVersion.current, replayBothWays: false), .binary)
        XCTAssertEqual(RemoteTerminalEngine.snapshotFormat(peer: other, replayBothWays: true), .replay)
        XCTAssertEqual(RemoteTerminalEngine.snapshotFormat(peer: nil, replayBothWays: true), .replay)
        XCTAssertNil(RemoteTerminalEngine.snapshotFormat(peer: other, replayBothWays: false))
        XCTAssertNil(RemoteTerminalEngine.snapshotFormat(peer: nil, replayBothWays: false))
        XCTAssertTrue(RemoteConstants.localFeatures.contains(RemoteFeature.terminalReplay))
    }

    /// 回放流的外包装；二进制快照认不成回放流，原样交给泵；空的一张（Mac 生成失败）不还原。
    func test_replay_payload_round_trip_and_binary_snapshots_pass_through() throws {
        let stream = Data("\u{1B}[31mred\u{1B}[0m\r\n".utf8)
        let wire = RemoteTerminalReplay.encode(cols: 300, rows: 2, stream: stream)
        let decoded = try XCTUnwrap(RemoteTerminalReplay.decode(wire))
        XCTAssertEqual(decoded.cols, 300)
        XCTAssertEqual(decoded.rows, 2)
        XCTAssertEqual(decoded.stream, stream)
        XCTAssertNil(RemoteTerminalReplay.decode(wire.dropLast(stream.count + 1)), "头不全")

        session.feedOutput(text: "hello")
        let binary = try session.shadow.snapshot()
        XCTAssertNil(RemoteTerminalReplay.decode(binary))
        XCTAssertEqual(RemoteTerminalReplay.restorable(binary), binary)
        XCTAssertNil(RemoteTerminalReplay.restorable(Data()))

        let redrawn = try XCTUnwrap(RemoteTerminalReplay.restorable(RemoteTerminalReplay.encode(cols: 20, rows: 3, stream: stream)))
        let terminal = try ShadowTerminal(snapshot: redrawn, options: TerminalScrollbackLimits(lines: 100).shadowOptions)
        XCTAssertEqual(terminal.size.cols, 20)
        XCTAssertEqual(terminal.size.rows, 3)
        XCTAssertEqual(terminal.recentLines(3).lines.first, "red")
    }

    /// XPC 上的接入请求加了可选的 `snapshotFormat`：老远控进程不带，App 当二进制快照。
    func test_agent_attach_request_snapshot_format_is_optional() throws {
        let old = #"{"sessionID":"\#(UUID().uuidString)","cols":80,"rows":24,"controller":"手机","settleTimeout":1}"#
        XCTAssertNil(try JSONDecoder().decode(RemoteHostAgentAttach.self, from: Data(old.utf8)).snapshotFormat)
        let new = RemoteHostAgentAttach(sessionID: UUID(), cols: 80, rows: 24, controller: "手机", settleTimeout: 1,
                                        snapshotFormat: RemoteTerminalSnapshotFormat.replay.rawValue)
        XCTAssertEqual(try JSONDecoder().decode(RemoteHostAgentAttach.self, from: JSONEncoder().encode(new)).snapshotFormat, "replay")
    }

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
