import SwiftData
import XCTest
@testable import uTermMobile

/// 断线自己重连的后端（`ReconnectingTerminalBackend`：远控连 Mac、直连主机接回主机上的会话）接进控制器之后：
/// 重连期间界面有提示、会话不算断开；App 回前台立刻探一次连接。
@MainActor
final class MobileTerminalReconnectingBackendTests: XCTestCase {

    /// 能由测试拨动重连状态、记探测次数的后端。
    actor ReconnectingBackend: ReconnectingTerminalBackend {
        nonisolated let outputItems = AsyncStream<TerminalOutputItem> { _ in }
        nonisolated let exitStream = AsyncStream<Void> { _ in }
        nonisolated let reconnecting: AsyncStream<Bool>
        private nonisolated let reconnectingContinuation: AsyncStream<Bool>.Continuation
        nonisolated let probesOnForeground: Bool
        private(set) var probeCount = 0

        init(probesOnForeground: Bool) {
            self.probesOnForeground = probesOnForeground
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
        let backend = ReconnectingBackend(probesOnForeground: true)
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
        let backend = ReconnectingBackend(probesOnForeground: true)
        let controller = try await connectedController(backend)
        backend.setReconnecting(true)
        let shown = await MobileFakeTerminal.waitUntil { controller.isReconnecting }
        XCTAssertTrue(shown)

        controller.close()
        XCTAssertFalse(controller.isReconnecting)
    }

    /// 从后台回来立刻探一次；进后台、已经在前台时再报一次前台都不探。
    func testReturningToForegroundProbesTheConnectionOnce() async throws {
        let backend = ReconnectingBackend(probesOnForeground: true)
        let controller = try await connectedController(backend)

        controller.appVisibilityChanged(inBackground: false)
        controller.appVisibilityChanged(inBackground: true)
        try await Task.sleep(for: .milliseconds(100))
        var count = await backend.probeCount
        XCTAssertEqual(count, 0)

        controller.appVisibilityChanged(inBackground: false)
        let deadline = ContinuousClock.now + .seconds(2)
        while await backend.probeCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        count = await backend.probeCount
        XCTAssertEqual(count, 1)
        controller.close()
    }

    /// 判错就等于断开的后端（不声明 `probesOnForeground`）回前台不探，仍然等看门狗在网络稳了之后探。
    func testBackendsThatDoNotAskForItAreNotProbedOnForeground() async throws {
        let backend = ReconnectingBackend(probesOnForeground: false)
        let controller = try await connectedController(backend)

        controller.appVisibilityChanged(inBackground: true)
        controller.appVisibilityChanged(inBackground: false)
        try await Task.sleep(for: .milliseconds(200))
        let count = await backend.probeCount
        XCTAssertEqual(count, 0)
        controller.close()
    }
}
