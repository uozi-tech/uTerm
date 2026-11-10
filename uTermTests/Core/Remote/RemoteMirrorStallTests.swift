import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 真机回归（build 883）：手机远控 Mac 上跑着 Claude Code 的标签、同时开着远程桌面，终端画面卡死、
/// 手机上打的字 Mac 也收不到，桌面照常。这里用真实的服务端 / 手机客户端（127.0.0.1）复现那种负载：
/// Claude 式 60 Hz 同步更新（DEC 2026）整屏重画 + OSC 7501 状态，手机持续打字，桌面 + 声音同时在跑。
/// 手机端是一台影子终端 + 输出泵（`MirrorPhone`），吃 `RemoteTerminalBackend.outputItems`（整屏快照 + 原样字节）。
@MainActor
final class RemoteMirrorStallTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// Claude Code 一拍的输出：同步更新里整屏重画，第一行写着拍号，夹一条 7501 状态。
    private func claudeFrame(_ number: Int, cols: Int, rows: Int) -> Data {
        var out = "\u{1b}[?2026h\u{1b}[H"
        out += "\u{1b}[2K\u{1b}[1;38;5;208mframe \(number)\u{1b}[0m\r\n"
        for row in 1..<(rows - 3) {
            let text = "\u{1b}[38;5;\(16 + (number + row) % 200)m" + String(repeating: "▌", count: (number + row) % 7)
                + " 正在思考 \(number) · 第 \(row) 行 " + String(repeating: "·", count: max(0, cols - 40)) + "\u{1b}[0m"
            out += "\u{1b}[2K" + text + "\r\n"
        }
        out += "\u{1b}[2K╭" + String(repeating: "─", count: cols - 2) + "╮\r\n"
        out += "\u{1b}[2K│ > " + String(repeating: " ", count: cols - 5) + "│\r\n"
        out += "\u{1b}[2K╰" + String(repeating: "─", count: cols - 2) + "╯"
        let state = number % 40 < 30 ? "working" : "idle"
        out += "\u{1b}]7501;state=\(state):app=claude-code\u{1b}\\"
        out += "\u{1b}[?2026l"
        return Data(out.utf8)
    }

    private func firstLine(_ terminal: ShadowTerminal) -> String {
        let text = terminal.viewportText()
        return String(text.prefix { $0 != "\n" })
    }

    private func frameNumber(_ terminal: ShadowTerminal) -> Int? {
        let line = firstLine(terminal)
        guard line.hasPrefix("frame ") else { return nil }
        return Int(line.dropFirst(6))
    }

    private enum Path { case lan, direct(RemoteLinkImpairment, RemoteLinkImpairment), relay(RemoteLinkImpairment) }

    func test_claude_like_output_with_desktop_keeps_mirror_and_input_flowing() async throws {
        try await runClaudeLoad(over: .lan)
    }

    /// 蜂窝上的打洞直连：单程 15 ms，偶发丢包。终端走 KCP，视频与声音走数据报。
    func test_claude_like_output_with_desktop_over_direct_path() async throws {
        let up = RemoteLinkImpairment(delay: 0.015, jitter: 0.004, lossRate: 0.005, bytesPerSecond: 2_500_000)
        let down = RemoteLinkImpairment(delay: 0.015, jitter: 0.004, lossRate: 0.005)
        try await runClaudeLoad(over: .direct(up, down))
    }

    /// 经中继（relay-sz）：TCP，单程 25 ms，限速 1 MB/s——视频和终端挤在同一条 TCP 上，靠 `link-flow` 分道。
    /// 会话里先攒几千行逐字换色的历史：整段回滚的快照一张约 2.7 MB，比积压上限（1 MB）大，接入和每次超限重发都是这么大一张，
    /// 1 MB/s 的中继上手机要落后好几秒。镜像快照只带最近约 1000 行回滚（`RemoteConstants.snapshotScrollback`）之后约 0.8 MB。
    func test_claude_like_output_with_heavy_styled_history_over_relay() async throws {
        try await runClaudeLoad(over: .relay(RemoteLinkImpairment(delay: 0.025, jitter: 0.005, bytesPerSecond: 1_000_000)),
                                styledHistoryLines: 3000)
    }

    /// 一行逐字换色的历史（Claude Code 的语法高亮 diff、彩色进度条都是这样）。
    private func styledLine(_ number: Int, cols: Int) -> String {
        var line = ""
        for column in 0..<(cols - 1) {
            let scalar = Character(UnicodeScalar(UInt8(33 + (number + column) % 90)))
            line += "\u{1b}[38;5;\((number * 7 + column) % 230 + 16)m\u{1b}[48;5;\((number + column * 3) % 230 + 16)m\(scalar)"
        }
        return line + "\u{1b}[0m\r\n"
    }

    /// Duo 展开 / 合上：手机终端格子在输出途中反复变尺寸（Mac 跟着改 PTY、重发快照），同时开着桌面、一直在打字。
    func test_phone_grid_changes_during_claude_output_on_every_path() async throws {
        let sizes = [(89, 32), (120, 40), (62, 30), (89, 32)]
        try await runClaudeLoad(over: .lan, resizes: sizes)
        try await runClaudeLoad(over: .direct(RemoteLinkImpairment(delay: 0.015, jitter: 0.004, lossRate: 0.005,
                                                                   bytesPerSecond: 2_500_000),
                                              RemoteLinkImpairment(delay: 0.015, jitter: 0.004, lossRate: 0.005)),
                                resizes: sizes)
        try await runClaudeLoad(over: .relay(RemoteLinkImpairment(delay: 0.025, jitter: 0.005, bytesPerSecond: 1_000_000)),
                                resizes: sizes)
    }

    private func runClaudeLoad(over path: Path, styledHistoryLines: Int = 0,
                               resizes: [(Int, Int)] = []) async throws {
        let mac = FakeDesktopMac()
        let registry = TerminalSessionRegistry()
        let session = TerminalSession()
        let macBackend = MockBackend()
        await session.connect(using: macBackend)
        let sessionID = UUID()
        registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "测试主机",
                                               windowKind: TerminalWindowKind.workspace, title: "claude",
                                               connectedAt: Date()), session: session)
        let server = RemoteHostServer(registry: registry,
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      desktopEnvironment: mac.environment())
        defer { server.stop(); session.dispose() }
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let phoneID = RemoteLocalDevice.id()
        try server.trust(RemotePeer(id: phoneID, name: "测试 iPhone",
                                    publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                    pairedAt: Date()))
        server.start()
        _ = await waitUntil { server.port != nil }
        let client: RemoteMacClient
        var keepAlive: [AnyObject] = []
        defer { _ = keepAlive }
        switch path {
        case .lan:
            client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1",
                                                         port: NWEndpoint.Port(rawValue: try XCTUnwrap(server.port))!),
                                     identity: phoneIdentity)
        case .direct(let up, let down):
            server.internetAccessPolicy = { $0 == phoneID }
            let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
            let (macPath, phonePath) = RemoteMemoryDatagramPath.pair(impairment: up, reverse: down)
            let datagramKeys = makeDatagramKeys()
            server.accept(transport: RemoteP2PTransport(path: macPath, keys: datagramKeys.first),
                          origin: .internet(peerID: phoneID, keys: RemoteHandshakeKeys(send: b, receive: a), path: .direct))
            client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: phoneIdentity)
            client.updateRoutes(endpoint: nil, internetDialer: { _ in
                RemoteDialedPath(transport: RemoteP2PTransport(path: phonePath, keys: datagramKeys.second),
                                 handshakeKeys: RemoteHandshakeKeys(send: a, receive: b), path: .direct)
            })
        case .relay(let impairment):
            server.internetAccessPolicy = { $0 == phoneID }
            let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
            let listener = try NWListener(using: RemoteLink.parameters(), on: .any)
            let accepted = AsyncStream<UInt16>.makeStream()
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue { accepted.continuation.yield(port) }
            }
            listener.newConnectionHandler = { [weak server] connection in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        server?.accept(transport: RemoteNWTransport(connection: connection),
                                       origin: .internet(peerID: phoneID, keys: RemoteHandshakeKeys(send: b, receive: a),
                                                         path: .relay))
                    }
                }
            }
            listener.start(queue: DispatchQueue(label: "test.mirror.listener"))
            var ports = accepted.stream.makeAsyncIterator()
            let readyPort = await ports.next()
            let proxy = try RemoteFaultProxy(targetPort: try XCTUnwrap(readyPort), impairment: impairment)
            keepAlive = [listener, proxy]
            _ = await waitUntil { proxy.port != nil }
            let proxyPort = try XCTUnwrap(proxy.port)
            client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: phoneIdentity)
            client.updateRoutes(endpoint: nil, internetDialer: { _ in
                let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!,
                                              using: RemoteLink.parameters())
                return RemoteDialedPath(transport: RemoteNWTransport(connection: connection),
                                        handshakeKeys: RemoteHandshakeKeys(send: a, receive: b), path: .relay)
            })
        }
        await client.connect()
        XCTAssertEqual(client.state, .connected)
        _ = await waitUntil { client.sessions.map(\.id) == [sessionID] }

        // 接入：手机 89×32；同时开远程桌面 + 声音（真机就是这样同时开的）。
        let cols = 89, rows = 32
        let backend = RemoteTerminalBackend(client: client, sessionID: sessionID)
        let phoneEnd = MirrorPhone(cols: cols, rows: rows)
        let phone = phoneEnd.shadow
        await backend.resize(cols: UInt16(cols), rows: UInt16(rows))
        try await backend.connect()
        phoneEnd.start(backend.outputItems)
        defer { phoneEnd.stop() }
        let desktop = RemoteDesktopSession(client: client, maxWidth: 1206, maxHeight: 2622,
                                           audioOutput: SilentAudioOutput())
        defer { desktop.stop() }
        await desktop.start()
        XCTAssertEqual(desktop.state, .streaming)
        desktop.setAudio(true)
        let source = try XCTUnwrap(mac.latestSource)
        source.prepareCycle(count: 8)
        source.run(fps: 30)
        let macTerminal = session.shadow
        XCTAssertEqual(macTerminal.size.cols, cols)
        XCTAssertEqual(macTerminal.size.rows, rows)
        if styledHistoryLines > 0 {
            for start in stride(from: 0, to: styledHistoryLines, by: 50) {
                var batch = ""
                for number in start..<min(styledHistoryLines, start + 50) { batch += styledLine(number, cols: cols) }
                await macBackend.emitOutput(Data(batch.utf8))
            }
            _ = await waitUntil { self.firstLine(macTerminal).isEmpty == false }
            let snapshot = try macTerminal.snapshot()
            print("[镜像回归] 快照 \(snapshot.count) 字节（\(macTerminal.totalRows) 行），积压上限 \(RemoteConstants.maxPendingOutputBytes)")
            // 读数：镜像实际发的那张（只带最近约 1000 行回滚）有多大、拍一张要多久。
            let started = DispatchTime.now().uptimeNanoseconds
            let trimmedSnapshot = try macTerminal.snapshot(scrollbackLines: RemoteConstants.snapshotScrollback)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            let trimmed = try ShadowTerminal(snapshot: trimmedSnapshot, options: TerminalScrollbackLimits(lines: 10_000).shadowOptions)
            print(String(format: "[镜像回归] 镜像快照（回滚上限 %d 行）：%d 字节（%d 行），%.1f ms",
                         RemoteConstants.snapshotScrollback, trimmedSnapshot.count, trimmed.totalRows, ms))
        }

        // 8 秒的 Claude 式输出，手机每 150 ms 打一个字。
        var typed: [Data] = []
        var lagging: [String] = []
        let started = Date()
        var number = 0
        while Date().timeIntervalSince(started) < 8 {
            number += 1
            let grid = macTerminal.size
            await macBackend.emitOutput(claudeFrame(number, cols: grid.cols, rows: grid.rows))
            if number % 9 == 0 {
                let key = Data("k\(number);".utf8)
                typed.append(key)
                await backend.write(key)
            }
            if !resizes.isEmpty, number % 60 == 30 {
                let (newCols, newRows) = resizes[(number / 60) % resizes.count]
                phoneEnd.resize(cols: newCols, rows: newRows)
                await backend.resize(cols: UInt16(newCols), rows: UInt16(newRows))
                let followed = await waitUntil(2) { macTerminal.size.cols == newCols && macTerminal.size.rows == newRows }
                if !followed { lagging.append("第 \(number) 拍：Mac 没跟上手机的 \(newCols)×\(newRows)，停在 \(macTerminal.size.cols)×\(macTerminal.size.rows)") }
            }
            if number % 60 == 0 {
                // 每秒核一次：手机画面最多落后 1 秒内追上，输入 1 秒内到 Mac。
                let target = self.frameNumber(macTerminal) ?? 0
                let caughtUp = await waitUntil(2) { (self.frameNumber(phone) ?? 0) >= target }
                if !caughtUp {
                    lagging.append("已发 \(number) 拍、Mac 画到第 \(target) 拍：2 秒后手机停在 \(firstLine(phone).prefix(20))，"
                                   + "Mac 已到 \(firstLine(macTerminal))；手机共收到 \(phoneEnd.snapshots) 份快照、\(phoneEnd.outputBytes / 1024) KB")
                }
                let expected = typed
                let delivered = await waitUntil(2) {
                    let written = await macBackend.writtenData.reduce(Data(), +)
                    return expected.allSatisfy { written.range(of: $0) != nil }
                }
                if !delivered { lagging.append("第 \(target) 拍：手机打的字没全到 Mac") }
                if !lagging.isEmpty { break }
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        if !lagging.isEmpty {
            // 区分「落后」与「卡死」：停掉输出，看手机还能不能追上。
            let last = number
            let recovered = await waitUntil(15) { (self.frameNumber(phone) ?? 0) >= last }
            lagging.append("Mac 停在 \(firstLine(macTerminal))，手机快照 \(phoneEnd.snapshots) 份、\(phoneEnd.outputBytes / 1024) KB")
            lagging.append(recovered ? "停止输出后 15 秒内追上了（是落后，不是卡死）"
                                     : "停止输出 15 秒后仍停在 \(firstLine(phone))（卡死）")
        }
        source.pause()
        XCTAssertTrue(lagging.isEmpty, lagging.joined(separator: "\n"))
        XCTAssertEqual(phoneEnd.pump.currentStats.rejectedSnapshots, 0, "手机端解得开 Mac 发来的每一张快照")
        // 停止输出后两边最终是同一个画面（不只是第一行的拍号追上）。
        let settled = await waitUntil(5) { macTerminal.mirrorDifferences(from: phone, includingHistory: false).isEmpty }
        XCTAssertTrue(settled, "停下来之后两边画面不一致：\(macTerminal.mirrorDifferences(from: phone, includingHistory: false))")
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(desktop.state, .streaming)
    }
}
