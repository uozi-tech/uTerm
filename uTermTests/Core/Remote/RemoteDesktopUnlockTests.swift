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

    func test_unlock_that_leaves_the_mac_locked_is_not_called_a_wrong_password() async throws {
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
        XCTAssertEqual(outcome, .stillLocked, "Mac 读不到锁屏拒绝密码的信号，只能说仍锁着")
        XCTAssertFalse(mac.screen.isCurtained, "解锁失败不进帘幕")
    }

    /// 截图选区等抓着键盘：Mac 不输密码，告诉手机是键盘被占着（手机声明了 `desktopUnlockOutcomes`）。
    func test_blocked_keyboard_is_reported_as_such() async throws {
        let mac = FakeDesktopMac()
        mac.screen.locked = true
        mac.screen.inputBlocked = true
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        defer { client.disconnect() }
        let session = await startSession(client)
        defer { session.stop() }
        let becameLocked = await waitUntil { session.screen.locked }
        XCTAssertTrue(becameLocked)

        let outcome = await session.unlock(password: "pw")
        XCTAssertEqual(outcome, .inputBlocked)
        XCTAssertFalse(mac.screen.isCurtained, "没解开：撤掉临时帘幕")
    }

    /// 老手机不认 `inputBlocked`（整条结果解不开会等到超时），Mac 对它退回 `stillLocked`。
    func test_old_peer_gets_still_locked_instead_of_input_blocked() {
        XCTAssertEqual(RemoteHostConnection.unlockOutcome(.inputBlocked, peerKnowsBlocked: false), .stillLocked)
        XCTAssertEqual(RemoteHostConnection.unlockOutcome(.inputBlocked, peerKnowsBlocked: true), .inputBlocked)
        XCTAssertEqual(RemoteHostConnection.unlockOutcome(.stillLocked, peerKnowsBlocked: true), .stillLocked)
        XCTAssertEqual(RemoteHostConnection.unlockOutcome(.unlocked, peerKnowsBlocked: false), .unlocked)
        XCTAssertEqual(RemoteDesktopUnlockResult.Outcome.stillLocked.rawValue, "rejected", "线上值不能变，老手机认的是它")
    }

    /// 只有铺满屏的截图遮罩才算占着键盘；截完图的小缩略图、别的程序的大窗口都不算。
    func test_keyboard_blocker_is_a_full_screen_screenshot_overlay() {
        func window(pid: pid_t, width: Double, height: Double) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid,
             kCGWindowBounds as String: CGRect(x: 0, y: 0, width: width, height: height).dictionaryRepresentation]
        }
        let names: [pid_t: String] = [1: "screencapture", 2: "screencaptureui", 3: "Terminal"]
        let area = 1512.0 * 982
        let find = { (windows: [[String: Any]]) in
            RemoteKeyboardBlocker.blocker(windows: windows, screenArea: area, processName: { names[$0] })
        }
        XCTAssertEqual(find([window(pid: 1, width: 1512, height: 982)]), "screencapture")
        XCTAssertEqual(find([window(pid: 3, width: 1512, height: 982), window(pid: 2, width: 1512, height: 982)]),
                       "screencaptureui")
        XCTAssertNil(find([window(pid: 2, width: 240, height: 160)]), "截完图的缩略图")
        XCTAssertNil(find([window(pid: 3, width: 1512, height: 982)]), "别的程序")
        XCTAssertNil(find([]))
    }

    /// 叫醒锁屏的序列里没有 Esc（锁屏上 Esc 会把刚弹出的输入框收回去），先叫醒再唤出输入框，
    /// 唤出到 ⌘A 之间留足动画时间。
    func test_unlock_preparation_wakes_then_summons_field_without_escape() {
        typealias T = RemoteUnlockTypist
        let steps = T.preparation()
        XCTAssertFalse(steps.contains(.key(T.escape)), "Esc 只在截图选区占着键盘时按")
        XCTAssertEqual(steps.first, .nudgeMouse)
        let summon = try? XCTUnwrap(steps.firstIndex(of: .key(T.delete)))
        let selectAll = try? XCTUnwrap(steps.firstIndex(of: .key(T.keyA, .maskCommand)))
        guard let summon, let selectAll else { return XCTFail("缺唤出或全选") }
        XCTAssertLessThan(summon, selectAll)
        let waited = steps[summon..<selectAll].reduce(0) { total, step in
            if case let .wait(ms) = step { return total + ms }
            return total
        }
        XCTAssertGreaterThanOrEqual(waited, 800, "输入框弹出动画要几百毫秒")
        XCTAssertEqual(steps.last(where: { if case .key = $0 { return true } else { return false } }), .key(T.delete),
                       "最后一下是清空用的 Delete，之后才打密码")
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

    /// 打密码时帘幕是关的（帘幕开着时按键进不了锁屏密码框），回车前挂上：锁屏一消失物理屏已经是黑的。
    func test_curtain_goes_up_after_typing_and_before_submit() async throws {
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
        XCTAssertEqual(mac.screen.curtainedDuringUnlock, [false])
        XCTAssertEqual(mac.screen.curtainedAtSubmit, [true])
        XCTAssertTrue(mac.screen.isCurtained, "解开后进入帘幕")
    }

    /// 手机先手动开了帘幕再解锁：打字时也要临时撤掉；没解开就恢复成开着。
    func test_manual_curtain_is_lifted_while_typing_and_restored_on_failure() async throws {
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
        session.setCurtain(true)
        let curtained = await waitUntil { mac.screen.isCurtained }
        XCTAssertTrue(curtained)

        let outcome = await session.unlock(password: "hunter2")
        XCTAssertEqual(outcome, .stillLocked)
        XCTAssertEqual(mac.screen.curtainedDuringUnlock, [false])
        let restored = await waitUntil { mac.screen.isCurtained }
        XCTAssertTrue(restored, "没解开：帘幕恢复成解锁前的开着")
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
