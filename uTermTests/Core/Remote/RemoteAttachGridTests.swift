import XCTest
@preconcurrency import Network
@testable import uTerm

/// 远控接入时的尺寸对齐，Mac 当主控端（远程 Mac 窗口的标签 `RemoteTerminalPane`）。两端都是带真 surface 的会话：
/// 被控端钉尺寸是异步的（视图改尺寸 → 引擎在 IO 线程上改网格），主控端的画面是本地网格。
///
/// 要的顺序：主控端在接入请求里就报本地尺寸 → 被控端钉住、等影子终端报出那个网格 → 才拍第一张快照；
/// 主控端的影子跟着对端的快照走，网格和本地 surface 不一致时画面不跟（等同网格的快照）。
@MainActor
final class RemoteAttachGridTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private struct Host {
        let rig: GhosttySurfaceRig
        let server: RemoteHostServer
        let client: RemoteMacClient
        let sessionID: UUID
    }

    /// 被控的 Mac：一个带真 surface 的终端（800×500 的窗格），登记进会话表，起远控服务；主控端连上它。
    private func makeHost() async throws -> Host {
        let rig = await GhosttySurfaceRig(size: NSSize(width: 800, height: 500))
        let sessionID = UUID()
        let registry = TerminalSessionRegistry()
        registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "测试主机",
                                               windowKind: TerminalWindowKind.workspace, title: "zsh",
                                               connectedAt: Date()), session: rig.session)
        let hostIdentity = RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage())
        let controller = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try hostIdentity.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "这台 Mac",
                                          publicKey: try controller.localIdentity().publicKey.rawRepresentation,
                                          pairedAt: Date()))
        let server = RemoteHostServer(registry: registry, identity: hostIdentity, localName: "远程 Mac", localID: UUID(),
                                      advertises: false)
        server.start()
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: try XCTUnwrap(server.port)))
        let client = RemoteMacClient(macName: "远程 Mac", endpoint: .hostPort(host: "127.0.0.1", port: port),
                                     identity: controller)
        await client.connect()
        XCTAssertEqual(client.state, .connected)
        addTeardownBlock { @MainActor in
            client.disconnect()
            server.stop()
            rig.close()
        }
        // 被控端的画面上先有内容（接入时整屏都要过去）。
        await rig.feed((1...40).map { "host line \($0)" }.joined(separator: "\r\n") + "\r\n$ ")
        return Host(rig: rig, server: server, client: client, sessionID: sessionID)
    }

    /// 主控端每次把影子回放进 surface 时，影子的网格与 surface 的终端在用的网格（IO 线程报过的那个）。
    private final class ReplayGrids: @unchecked Sendable {
        private let lock = NSLock()
        private var grids: [String] = []
        var all: [String] { lock.withLock { grids } }
        func record(_ value: String) { lock.withLock { grids.append(value) } }
    }

    private func recordReplays(of session: TerminalSession) -> ReplayGrids {
        let grids = ReplayGrids()
        replayLog = grids
        let shadow = session.shadow, io = session.surfaceIO
        session.outputPump.onReplayed = {
            let s = shadow.size
            let g = io.reportedGrid.map { "\($0.columns)x\($0.rows)" } ?? "nil"
            grids.record("\(s.cols)x\(s.rows)/\(g)")
        }
        return grids
    }

    /// 两种读法对行尾空格处理不同（surface 读光标所在行时带着光标前的空格）：比之前去掉行尾空白。
    private static func trimmed(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    private var replayLog: ReplayGrids?

    private func assertMirrored(controller: GhosttySurfaceRig, host: Host, file: StaticString = #filePath, line: UInt = #line) async {
        let grid = try? XCTUnwrap(controller.bridge.grid)
        let hostShadow = host.rig.session.shadow
        let aligned = await waitUntil(5) {
            guard let grid else { return false }
            return hostShadow.size == grid && controller.session.shadow.size == grid
                && controller.session.shadow.viewportText() == hostShadow.viewportText()
                && Self.trimmed(controller.surfaceText) == Self.trimmed(hostShadow.viewportText())
        }
        XCTAssertTrue(aligned, "被控端、主控端影子、主控端画面应当同一个网格、同一屏内容："
                      + "被控端 \(hostShadow.size)，主控端影子 \(controller.session.shadow.size)，主控端网格 \(String(describing: grid))"
                      + "\n被控端影子：\(hostShadow.viewportText().debugDescription)"
                      + "\n主控端影子：\(controller.session.shadow.viewportText().debugDescription)"
                      + "\n主控端画面：\(controller.surfaceText.debugDescription)"
                      + "\n回放：\(replayLog?.all ?? [])；泵：\(controller.session.outputPump.currentStats)",
                      file: file, line: line)
    }

    /// 主控端的画面先建好（尺寸已知）再接入：接入请求带着本地尺寸，被控端钉好之后才拍第一张快照——
    /// 只发一张、主控端画面从没停下来等过对齐，回放时两边网格一致。
    func test_attach_with_known_size_sends_one_snapshot_at_the_controller_grid() async throws {
        let host = try await makeHost()
        let pane = RemoteTerminalPane(id: host.sessionID, client: host.client)
        let controller = await GhosttySurfaceRig(size: NSSize(width: 600, height: 360), session: pane.session,
                                                 connectsBackend: false)
        defer { pane.dispose(); controller.close() }
        let grid = try XCTUnwrap(controller.bridge.grid)
        XCTAssertNotEqual(grid.cols, host.rig.session.shadow.size.cols, "用例前提：两端窗格不一样大")
        let replays = recordReplays(of: pane.session)

        await pane.start()
        XCTAssertEqual(pane.session.connectionState, .connected)
        await assertMirrored(controller: controller, host: host)
        XCTAssertEqual(pane.session.outputPump.currentStats.gridHolds, 0, "第一张快照就是本地网格，不必停画面等")
        for entry in replays.all {
            let parts = entry.split(separator: "/")
            XCTAssertEqual(parts[0], parts[1], "回放时影子与画面的网格不一致：\(entry)")
        }
        // 之后的输出原样跟上。
        await host.rig.feed("echo after\r\nafter")
        await assertMirrored(controller: controller, host: host)
    }

    /// 主控端先接入、画面后建（标签还没露出过）：先按默认尺寸接入，画面建好后报真实尺寸。网格对齐之前画面停着，
    /// 被控端按新尺寸钉好、发来同网格的快照才回放；回放时两边网格一致。
    func test_attach_before_the_view_exists_holds_the_picture_until_aligned() async throws {
        let host = try await makeHost()
        let pane = RemoteTerminalPane(id: host.sessionID, client: host.client)
        let replays = recordReplays(of: pane.session)
        await pane.start()
        XCTAssertEqual(pane.session.connectionState, .connected)
        let gotSnapshot = await waitUntil { pane.session.shadow.viewportText().contains("host line 40") }
        XCTAssertTrue(gotSnapshot, "没有画面时影子照样收快照")

        let controller = await GhosttySurfaceRig(size: NSSize(width: 600, height: 360), session: pane.session,
                                                 connectsBackend: false)
        defer { pane.dispose(); controller.close() }
        await assertMirrored(controller: controller, host: host)
        XCTAssertFalse(pane.session.outputPump.isHoldingForGrid)
        XCTAssertEqual(pane.session.outputPump.currentStats.gridHoldTimeouts, 0, "被控端应当在超时之前钉好")
        // 主控端改窗格大小：一样停画面等对齐，之后一致。
        let before = try XCTUnwrap(controller.bridge.grid)
        controller.window.setContentSize(NSSize(width: 700, height: 420))
        controller.container.frame = controller.window.contentView?.bounds ?? .zero
        controller.container.layoutSubtreeIfNeeded()
        let resized = await waitUntil { controller.bridge.grid.map { $0 != before } ?? false }
        XCTAssertTrue(resized, "主控端的网格应当变了")
        await assertMirrored(controller: controller, host: host)
        XCTAssertEqual(pane.session.outputPump.currentStats.gridHoldTimeouts, 0)
        for entry in replays.all {
            let parts = entry.split(separator: "/")
            XCTAssertEqual(parts[0], parts[1], "回放时影子与画面的网格不一致：\(entry)")
        }
    }
}
