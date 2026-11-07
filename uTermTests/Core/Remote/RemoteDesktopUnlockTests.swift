import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 远程解锁 / 帘幕的端到端（回环）：真实的 `RemoteHostServer` / 加密链路 / 手机侧 `RemoteMacClient` +
/// `RemoteDesktopSession`，只有「屏幕控制」换成 `FakeScreenController`（不碰真实锁屏、gamma、事件）。
@MainActor
final class RemoteDesktopUnlockTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func makeServer(_ mac: FakeDesktopMac) async throws -> RemoteHostServer {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      desktopEnvironment: mac.environment())
        server.start()
        let ready = await waitUntil { server.port != nil }
        XCTAssertTrue(ready, "服务端没起来：\(server.status)")
        return server
    }

    private func makeClient(_ server: RemoteHostServer) async throws -> RemoteMacClient {
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "测试 iPhone",
                                    publicKey: try identity.localIdentity().publicKey.rawRepresentation, pairedAt: Date()))
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(server.port))!),
                                     identity: identity)
        await client.connect()
        XCTAssertEqual(client.state, .connected)
        return client
    }

    private func startSession(_ client: RemoteMacClient) async -> RemoteDesktopSession {
        let session = RemoteDesktopSession(client: client, maxWidth: 1206, maxHeight: 2622)
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        return session
    }

    // MARK: - 能力门控

    /// 能力与开关无关（能力只在握手时交换一次，随开关增减的话，开关打开后已有连接永远看不到入口）；
    /// 开关关着时状态里 `unlockAvailable` 为 false，解锁请求被拒；打开开关后立刻推新状态，无需重连。
    func test_setting_off_blocks_unlock_and_turning_on_takes_effect_without_reconnect() async throws {
        let mac = FakeDesktopMac()
        mac.unlockEnabled = false
        mac.screen.locked = true
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        defer { client.disconnect() }
        XCTAssertTrue(client.supportsUnlock, "能力应始终声明")
        let session = await startSession(client)
        defer { session.stop() }
        let lockedButOff = await waitUntil { session.screen.locked && !session.screen.unlockAvailable }
        XCTAssertTrue(lockedButOff)

        let refused = await session.unlock(password: "x")
        XCTAssertEqual(refused, .notAllowed)
        XCTAssertEqual(mac.screen.unlockCalls, 0)

        mac.unlockEnabled = true
        server.desktopSettingsChanged()
        let available = await waitUntil { session.screen.unlockAvailable }
        XCTAssertTrue(available, "打开开关后不重连也应可用")
        let outcome = await session.unlock(password: "hunter2")
        XCTAssertEqual(outcome, .unlocked)
    }

    func test_unlock_feature_offered_when_setting_on() async throws {
        let mac = FakeDesktopMac()
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        defer { client.disconnect() }
        XCTAssertTrue(client.supportsUnlock)
    }

    // MARK: - 锁屏状态推送

    func test_locked_state_is_pushed_on_start() async throws {
        let mac = FakeDesktopMac()
        mac.screen.locked = true
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        defer { client.disconnect() }
        let session = await startSession(client)
        defer { session.stop() }
        let lockedAvail = await waitUntil { session.screen.locked && session.screen.unlockAvailable }
        XCTAssertTrue(lockedAvail)
    }

    // MARK: - 解锁

    func test_unlock_with_correct_password_enters_curtain() async throws {
        let mac = FakeDesktopMac()
        mac.screen.locked = true
        mac.screen.unlockSucceeds = true
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        defer { client.disconnect() }
        let session = await startSession(client)
        defer { session.stop() }
        let becameLocked = await waitUntil { session.screen.locked }
        XCTAssertTrue(becameLocked)

        let outcome = await session.unlock(password: "hunter2")
        XCTAssertEqual(outcome, .unlocked)
        XCTAssertEqual(mac.screen.unlockCalls, 1)
        XCTAssertEqual(mac.screen.curtainHistory, [true], "解锁成功后应自动进入帘幕")
        let unlockedCurtained = await waitUntil { !session.screen.locked && session.screen.curtained }
        XCTAssertTrue(unlockedCurtained)
    }

    func test_unlock_with_wrong_password_is_rejected() async throws {
        let mac = FakeDesktopMac()
        mac.screen.locked = true
        mac.screen.unlockSucceeds = false
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        defer { client.disconnect() }
        let session = await startSession(client)
        defer { session.stop() }
        let becameLocked = await waitUntil { session.screen.locked }
        XCTAssertTrue(becameLocked)

        let outcome = await session.unlock(password: "wrong")
        XCTAssertEqual(outcome, .rejected)
        XCTAssertFalse(mac.screen.isCurtained, "解锁失败不进帘幕")
    }

    func test_unlock_rejected_when_not_locked() async throws {
        let mac = FakeDesktopMac()
        mac.screen.locked = false
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        defer { client.disconnect() }
        let session = await startSession(client)
        defer { session.stop() }

        let outcome = await session.unlock(password: "x")
        XCTAssertEqual(outcome, .notLocked)
        XCTAssertEqual(mac.screen.unlockCalls, 0)
    }

    /// 先挂帘幕再输密码：锁屏一消失物理屏已经是黑的。
    func test_curtain_goes_up_before_password_is_typed() async throws {
        let mac = FakeDesktopMac()
        mac.screen.locked = true
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        defer { client.disconnect() }
        let session = await startSession(client)
        defer { session.stop() }
        let becameLocked = await waitUntil { session.screen.locked }
        XCTAssertTrue(becameLocked)

        _ = await session.unlock(password: "hunter2")
        XCTAssertEqual(mac.screen.curtainedDuringUnlock, [true])
    }

    /// 远程解锁后手机手动关了帘幕，结束远控时仍要锁回去。
    func test_remote_unlock_is_locked_back_even_if_curtain_was_turned_off() async throws {
        let mac = FakeDesktopMac()
        mac.screen.locked = true
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        defer { client.disconnect() }
        let session = await startSession(client)
        let becameLocked = await waitUntil { session.screen.locked }
        XCTAssertTrue(becameLocked)
        _ = await session.unlock(password: "hunter2")
        session.setCurtain(false)
        let off = await waitUntil { !mac.screen.isCurtained }
        XCTAssertTrue(off)

        server.endDesktop(reason: "测试结束")
        let lockedBack = await waitUntil { mac.screen.lockScreenCalls == 1 }
        XCTAssertTrue(lockedBack, "远程解锁过就要锁回去，不管帘幕开没开")
        session.stop()
    }

    /// 开关中途被关掉：手机仍能撤掉帘幕（只有开帘幕要求开关打开）。
    func test_curtain_can_be_turned_off_after_setting_is_disabled() async throws {
        let mac = FakeDesktopMac()
        mac.screen.locked = false
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        defer { client.disconnect() }
        let session = await startSession(client)
        defer { session.stop() }
        let ready = await waitUntil { session.screen.unlockAvailable }
        XCTAssertTrue(ready)
        session.setCurtain(true)
        let on = await waitUntil { mac.screen.isCurtained }
        XCTAssertTrue(on)

        mac.unlockEnabled = false
        server.desktopSettingsChanged()
        session.setCurtain(true)  // 关了开关后不能再开……
        session.setCurtain(false) // ……但必须能关
        let off = await waitUntil { !mac.screen.isCurtained }
        XCTAssertTrue(off)
    }

    // MARK: - 结束时锁回去

    func test_curtain_is_locked_back_when_stream_ends() async throws {
        let mac = FakeDesktopMac()
        mac.screen.locked = true
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        defer { client.disconnect() }
        let session = await startSession(client)
        let becameLocked = await waitUntil { session.screen.locked }
        XCTAssertTrue(becameLocked)
        _ = await session.unlock(password: "hunter2")
        let curtained = await waitUntil { mac.screen.isCurtained }
        XCTAssertTrue(curtained)

        server.endDesktop(reason: "测试结束")
        let lockedBack = await waitUntil { mac.screen.lockScreenCalls == 1 && !mac.screen.isCurtained }
        XCTAssertTrue(lockedBack, "结束时应先锁屏再撤帘幕")
        session.stop()
    }
}
