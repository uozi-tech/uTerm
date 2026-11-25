import XCTest
@testable import uTerm

@MainActor
final class TerminalSessionTests: XCTestCase {

    /// 换连接 / 重连后，上一条连接上的程序设过的光标形状（DECSCUSR）复位成设置里的：复位序列 `CSI 0 q` 经泵进了
    /// 影子、画面和镜像同一条字节流（镜像订阅者收得到，说明画面那边也收到了）。全新的会话不发。
    func testReconnectResetsTheCursorShapeAProgramSet() async {
        let session = TerminalSession()
        session.attentionSink = { _ in }
        defer { session.dispose() }
        let subscriber = session.mirrorTap.subscribe(id: UUID()) {}
        await session.connect(using: MockBackend())
        var first = Data()
        while let chunk = subscriber.take(maxBytes: 1 << 20) { if case .output(let bytes) = chunk { first.append(bytes) } }
        XCTAssertNil(first.range(of: TerminalOutputPump.resetCursorShape), "全新的会话不用复位")

        session.feedOutput(text: "\u{1B}[6 q$ ")
        while subscriber.take(maxBytes: 1 << 20) != nil {}
        await session.connect(using: MockBackend())
        var after = Data()
        while let chunk = subscriber.take(maxBytes: 1 << 20) { if case .output(let bytes) = chunk { after.append(bytes) } }
        XCTAssertNotNil(after.range(of: TerminalOutputPump.resetCursorShape), "重连后要复位光标形状")
    }

    /// 合盖断线后重连：上一条连接上的程序（Claude、tmux、vim）开着鼠标上报 / 焦点上报 / 备用屏 / 藏了光标就断了，
    /// 新 shell 不知道，终端却继续把鼠标移动报给它——readline 吞掉 `ESC [ <` 前缀，命令行里满屏 `35;65;9M35;65;10M…`。
    /// 重连要把这些模式复位：影子（和画面吃的是同一条字节流）里鼠标上报关了、回到主屏、光标可见，主屏原来的内容还在。
    func testReconnectTurnsOffModesTheOldProgramLeftOn() async {
        let session = TerminalSession()
        session.attentionSink = { _ in }
        defer { session.dispose() }
        await session.connect(using: MockBackend())
        session.feedOutput(text: "main-screen-line\r\n$ ")
        session.feedOutput(text: "\u{1B}[?1049h\u{1B}[?1003h\u{1B}[?1006h\u{1B}[?1004h\u{1B}[?25lTUI")
        XCTAssertTrue(session.shadow.isMouseTracking)
        XCTAssertTrue(session.shadow.isOnAlternateScreen)
        XCTAssertFalse(session.shadow.cursor.visible)

        await session.connect(using: MockBackend())
        XCTAssertFalse(session.shadow.isMouseTracking, "新连接上的 shell 没开鼠标上报，终端不能再往它发鼠标事件")
        XCTAssertFalse(session.shadow.isOnAlternateScreen, "新 shell 画在主屏上")
        XCTAssertTrue(session.shadow.cursor.visible)
        XCTAssertTrue(session.shadow.viewportText().contains("main-screen-line"), "回到主屏，原来的内容还在")
        XCTAssertFalse(session.shadow.viewportText().contains("TUI"))
    }

    /// 不在备用屏时不送 1049 复位：它会把光标还原到不知哪次存的位置。
    func testReconnectOnMainScreenDoesNotMoveTheCursor() async {
        let session = TerminalSession()
        session.attentionSink = { _ in }
        defer { session.dispose() }
        await session.connect(using: MockBackend())
        session.feedOutput(text: "\u{1B}7\u{1B}[?1003hline1\r\nline2\r\n$ ")
        let before = session.shadow.cursor
        await session.connect(using: MockBackend())
        XCTAssertFalse(session.shadow.isMouseTracking)
        XCTAssertEqual(session.shadow.cursor.x, before.x)
        XCTAssertEqual(session.shadow.cursor.y, before.y)
    }

    func testInitialStateIsIdle() {
        let session = TerminalSession()
        XCTAssertEqual(session.connectionState, .idle)
    }

    func testConnectSuccessReachesConnected() async {
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        XCTAssertEqual(session.connectionState, .connected)
        let didConnect = await backend.didConnect
        XCTAssertTrue(didConnect)
    }

    func testConnectFailureReachesFailed() async {
        let session = TerminalSession()
        let backend = MockBackend()
        await backend.setConnectError(SSHConnection.SSHConnectionError.connectFailed("boom"))
        await session.connect(using: backend)
        guard case .failed(let msg) = session.connectionState else {
            return XCTFail("应为 .failed")
        }
        XCTAssertTrue(msg.contains("boom"))
    }

    /// 失败页上给人看的是本地化的原因，不是 Swift 枚举的调试写法（以前是 `connectFailed("…")`）。
    func testConnectFailureShowsLocalizedReasonNotEnumDump() async {
        let session = TerminalSession()
        let backend = MockBackend()
        await backend.setConnectError(SSHConnection.SSHConnectionError.connectFailed("10.0.0.1:22 拒绝了连接"))
        await session.connect(using: backend)
        guard case .failed(let msg) = session.connectionState else { return XCTFail("应为 .failed") }
        XCTAssertFalse(msg.contains("connectFailed("), msg)
        XCTAssertEqual(msg, SSHConnection.SSHConnectionError.connectFailed("10.0.0.1:22 拒绝了连接").localizedDescription)
    }

    /// 用户在失败 / 断开之后点「重试」/「重新连接」，又没连上：说「仍然连不上：原因」，不是又一句像是刚断开的话。
    func testRetryFailureSaysStillCannotConnectWithTheReason() async {
        let session = TerminalSession()
        let backend = MockBackend()
        await backend.setConnectError(SSHConnection.SSHConnectionError.connectFailed("10.0.0.1:22 拒绝了连接"))
        session.connectAttemptIsRetry = true
        await session.connect(using: backend)
        guard case .failed(let msg) = session.connectionState else { return XCTFail("应为 .failed") }
        XCTAssertTrue(msg.hasPrefix("仍然连不上："), msg)
        XCTAssertTrue(msg.contains("拒绝了连接"), msg)
        XCTAssertTrue(session.connectAttemptIsRetry, "没连上之前一直算重试")

        // 连上就清掉：之后的失败不再带「仍然」。
        let ok = MockBackend()
        await session.connect(using: ok)
        XCTAssertEqual(session.connectionState, .connected)
        XCTAssertFalse(session.connectAttemptIsRetry)
    }

    func testRemoteExitReachesDisconnected() async {
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        await backend.emitExit()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.connectionState, .disconnected)
    }

    /// 当第一个 `connect()` 在挂起期间被第二个 `connect()` 取代时，
    /// 恢复后的旧调用不得覆盖新绑定的状态。
    func testSupersededConnectDoesNotClobber() async {
        let session = TerminalSession()
        let backendA = MockBackend()
        let backendB = MockBackend()

        // 让 A 的 connect() 挂起，模拟挂起窗口内发生重入。
        await backendA.armConnectGate()

        // 启动针对 A 的 connect —— 会停在闸门处。
        async let connectA: Void = session.connect(using: backendA)

        // 让出执行权，确保 connectA 已进入挂起态。
        try? await Task.sleep(for: .milliseconds(20))

        // 第二个 connect 取代第一个；B 不设闸门，正常完成。
        await session.connect(using: backendB)

        // 放行 A，使其旧调用恢复执行。
        await backendA.releaseConnect()
        await connectA

        // 最终状态必须反映 B：connected，且绑定 backend 为 B。
        XCTAssertEqual(session.connectionState, .connected)
        XCTAssertTrue(session.backend === backendB)
        let bConnected = await backendB.didConnect
        XCTAssertTrue(bConnected)
    }

    func testKeyboardInputForwardsToBackend() async {
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        session.sendHostBytes(Data("ls\n".utf8))
        try? await Task.sleep(for: .milliseconds(50))
        let written = await backend.writtenData
        XCTAssertEqual(written.map { String(decoding: $0, as: UTF8.self) }.joined(), "ls\n")
    }

    /// 看门狗探测：后端报活 → 状态不动。
    func testProbeConnectionHealthKeepsConnectedWhenAlive() async {
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)

        await session.probeConnectionHealth()

        XCTAssertEqual(session.connectionState, .connected)
        let probes = await backend.probeCount
        XCTAssertEqual(probes, 1)
    }

    /// 看门狗探测：后端判死（真实实现会强制关通道 → exitStream 产元素）→
    /// 状态翻到 .disconnected，窗格据此盖「连接已断开 / 重新连接」。
    func testProbeConnectionHealthFlipsToDisconnectedWhenDead() async {
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        await backend.setAliveOnProbe(false)

        await session.probeConnectionHealth()

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.connectionState, .disconnected)
    }

    /// 未连接（idle / failed / disconnected）不探测 —— 避免对早已收尾的
    /// 后端做无意义往返。
    func testProbeConnectionHealthSkippedWhenNotConnected() async {
        let session = TerminalSession()
        await session.probeConnectionHealth()
        XCTAssertEqual(session.connectionState, .idle)
    }
}
