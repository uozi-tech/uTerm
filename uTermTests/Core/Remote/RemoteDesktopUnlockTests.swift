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
                                      identity: RemoteIdentityStore(storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      desktopEnvironment: mac.environment())
        server.start()
        let ready = await waitUntil { server.port != nil }
        XCTAssertTrue(ready, "服务端没起来：\(server.status)")
        return server
    }

    private func makeClient(_ server: RemoteHostServer) async throws -> RemoteMacClient {
        let identity = RemoteIdentityStore(storage: RemoteMemoryStorage())
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

    func test_unlock_feature_not_offered_when_setting_off() async throws {
        let mac = FakeDesktopMac()
        mac.unlockEnabled = false
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        defer { client.disconnect() }
        XCTAssertFalse(client.supportsUnlock, "关掉远程解锁时不应声明 desktop-unlock 能力")
        let session = await startSession(client)
        session.stop()
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
