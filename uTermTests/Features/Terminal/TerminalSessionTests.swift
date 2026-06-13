import XCTest
@testable import uTerm

@MainActor
final class TerminalSessionTests: XCTestCase {

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
        session.send(source: session.terminalView, data: ArraySlice(Array("ls\n".utf8)))
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
