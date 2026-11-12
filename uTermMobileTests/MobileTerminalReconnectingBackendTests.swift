import SwiftData
import XCTest
@testable import uTermMobile

/// 断线自己重连的后端（`ReconnectingTerminalBackend`：远控连 Mac、直连主机接回主机上的会话）接进控制器之后：
/// 重连期间界面有提示、会话不算断开；App 回前台、网络刚变时立刻让后端查一次连接。
@MainActor
final class MobileTerminalReconnectingBackendTests: XCTestCase {

    /// 能由测试拨动重连状态、记「查一次连接」次数的后端。
    actor ReconnectingBackend: ReconnectingTerminalBackend {
        nonisolated let outputItems = AsyncStream<TerminalOutputItem> { _ in }
        nonisolated let exitStream = AsyncStream<Void> { _ in }
        nonisolated let reconnecting: AsyncStream<Bool>
        private nonisolated let reconnectingContinuation: AsyncStream<Bool>.Continuation
        /// 每次 `recheckAfterDisruption` 收到的 `lostInterface`。
        private(set) var rechecks: [Bool] = []
        private(set) var probeCount = 0

        init() {
            (reconnecting, reconnectingContinuation) = AsyncStream<Bool>.makeStream()
        }

        func connect() async throws {}
        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async { reconnectingContinuation.finish() }
        func verifyConnectionAlive() async -> Bool {
            probeCount += 1
            return true
        }
        func recheckAfterDisruption(lostInterface: Bool) async { rechecks.append(lostInterface) }

        nonisolated func setReconnecting(_ value: Bool) { reconnectingContinuation.yield(value) }
    }

    private func connectedController(_ backend: ReconnectingBackend) async throws -> MobileTerminalController {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let controller = MobileTerminalController(transportFactory: MobileTerminalTransportFactory { _ in backend })
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        return controller
    }

    /// 重连期间：标记亮着，会话仍然是「已连接」（不进断开页、不丢终端）。接回后标记灭掉。
    func testReconnectingIsShownWithoutDroppingTheSession() async throws {
        let backend = ReconnectingBackend()
        let controller = try await connectedController(backend)
        XCTAssertFalse(controller.isReconnecting)

        backend.setReconnecting(true)
        let shown = await MobileFakeTerminal.waitUntil { controller.isReconnecting }
        XCTAssertTrue(shown)
        XCTAssertEqual(controller.state, .connected)

        backend.setReconnecting(false)
        let hidden = await MobileFakeTerminal.waitUntil { !controller.isReconnecting }
        XCTAssertTrue(hidden)
        XCTAssertEqual(controller.state, .connected)
        controller.close()
    }

    /// 关掉会话后，后端迟到的重连状态不再点亮标记。
    func testCloseClearsTheReconnectingMark() async throws {
        let backend = ReconnectingBackend()
        let controller = try await connectedController(backend)
        backend.setReconnecting(true)
        let shown = await MobileFakeTerminal.waitUntil { controller.isReconnecting }
        XCTAssertTrue(shown)

        controller.close()
        XCTAssertFalse(controller.isReconnecting)
    }

    private func waitForRechecks(_ backend: ReconnectingBackend, count: Int) async throws -> [Bool] {
        let deadline = ContinuousClock.now + .seconds(2)
        while await backend.rechecks.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        return await backend.rechecks
    }

    /// 从后台回来立刻查一次；进后台、已经在前台时再报一次前台都不查。
    func testReturningToForegroundRechecksTheConnectionOnce() async throws {
        let backend = ReconnectingBackend()
        let controller = try await connectedController(backend)

        controller.appVisibilityChanged(inBackground: false)
        controller.appVisibilityChanged(inBackground: true)
        try await Task.sleep(for: .milliseconds(100))
        var rechecks = await backend.rechecks
        XCTAssertEqual(rechecks, [])

        controller.appVisibilityChanged(inBackground: false)
        rechecks = try await waitForRechecks(backend, count: 1)
        XCTAssertEqual(rechecks, [false])
        controller.close()
    }

    /// 网络刚变：不等看门狗的稳定期，立刻转给后端，网卡没了这件事原样带到。
    func testNetworkPathChangeGoesStraightToTheBackend() async throws {
        let backend = ReconnectingBackend()
        let controller = try await connectedController(backend)

        controller.networkPathChanged(lostInterface: true)
        let first = try await waitForRechecks(backend, count: 1)
        XCTAssertEqual(first, [true])
        controller.networkPathChanged(lostInterface: false)
        let second = try await waitForRechecks(backend, count: 2)
        XCTAssertEqual(second, [true, false])
        let probes = await backend.probeCount
        XCTAssertEqual(probes, 0, "这条路不走看门狗的探活")
        controller.close()
    }

    /// 会话已经关了：网络变化不再转给后端。
    func testNetworkPathChangeIsIgnoredOnceClosed() async throws {
        let backend = ReconnectingBackend()
        let controller = try await connectedController(backend)
        controller.close()

        controller.networkPathChanged(lostInterface: true)
        try await Task.sleep(for: .milliseconds(200))
        let rechecks = await backend.rechecks
        XCTAssertEqual(rechecks, [])
    }
}
