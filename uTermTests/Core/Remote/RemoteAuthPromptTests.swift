import CoreGraphics
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 远程过 Mac 上的系统验证框：找框（`RemoteAuthPromptDetector`）、回应的步骤与守卫（`RemoteAuthPromptTypist`，
/// 系统能力换成假的），以及经真实服务端 / 加密链路 / 主控端会话的端到端（`FakeScreenController` 代替真屏幕）。
@MainActor
final class RemoteAuthPromptTests: XCTestCase {
    // MARK: - 找框

    private func windowInfo(id: CGWindowID, pid: pid_t, layer: Int,
                            bounds: CGRect = CGRect(x: 1022, y: 254, width: 260, height: 321)) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
         kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary]
    }

    func test_detector_finds_the_frontmost_auth_window_by_process_name() {
        let names: [pid_t: String] = [10: "Finder", 20: "SecurityAgent", 30: "coreautha", 40: "SecurityAgent"]
        let windows = [
            windowInfo(id: 1, pid: 10, layer: 1000),                       // 别的进程
            windowInfo(id: 2, pid: 40, layer: 0),                          // 普通层（不是弹框）
            windowInfo(id: 3, pid: 20, layer: 1000, bounds: CGRect(x: 0, y: 0, width: 40, height: 40)),  // 太小
            windowInfo(id: 4, pid: 30, layer: 1000),
            windowInfo(id: 5, pid: 20, layer: 1000),
        ]
        let found = RemoteAuthPromptDetector.find(windows: windows) { names[$0] }
        XCTAssertEqual(found?.id, 4, "从前往后取第一个合格的")
        XCTAssertEqual(found?.kind, .localAuthentication)
        XCTAssertEqual(found?.pid, 30)

        let admin = RemoteAuthPromptDetector.find(windows: [windows[4]]) { names[$0] }
        XCTAssertEqual(admin?.prompt, RemoteDesktopAuthPrompt(id: 5, kind: .authorization))
        XCTAssertNil(RemoteAuthPromptDetector.find(windows: Array(windows.prefix(3))) { names[$0] })
    }

    func test_unknown_prompt_kind_from_a_newer_mac_still_decodes() throws {
        let json = #"{"locked":false,"curtained":false,"unlockAvailable":true,"authPrompt":{"id":9,"kind":"smartCard"}}"#
        let state = try RemoteJSON.decode(RemoteDesktopScreenState.self, from: Data(json.utf8))
        XCTAssertEqual(state.authPrompt, RemoteDesktopAuthPrompt(id: 9, kind: .other))
        let old = try RemoteJSON.decode(RemoteDesktopScreenState.self,
                                        from: Data(#"{"locked":true,"curtained":false,"unlockAvailable":false}"#.utf8))
        XCTAssertNil(old.authPrompt, "老 Mac 不带这个键")
    }

    func test_request_description_hides_the_password() {
        let request = RemoteDesktopAuthPromptRequest(requestID: UUID(), promptID: 3, action: .fill, password: "hunter2")
        XCTAssertFalse("\(request)".contains("hunter2"))
        XCTAssertFalse(String(reflecting: request).contains("hunter2"))
    }

    // MARK: - 回应的步骤与守卫

    /// 假的系统：一个框、前台、安全输入，记下每个动作。点框能不能把它叫到前台、密码对不对都可编排。
    @MainActor
    private final class FakeSystem {
        enum Action: Equatable {
            case click(CGPoint)
            case key(CGKeyCode, CGEventFlags)
            case type(Character)
        }

        var window: RemoteAuthPromptWindow?
        var front: pid_t? = 99
        var secure = false
        var actions: [Action] = []
        /// 点框后它会不会到前台。
        var clickFocuses = true
        /// 框到前台时焦点是不是已在密码框（SecurityAgent 是；LocalAuthentication 的 Touch ID 页不是）。
        var focusLandsInPassword = true
        var rightPassword = "hunter2"
        /// 打到第几个字时有人在 Mac 上点走了（nil = 不会）。
        var stealFocusAfter: Int?
        private var typed = ""

        init(kind: RemoteDesktopAuthPrompt.Kind) {
            window = RemoteAuthPromptWindow(id: 7, pid: 42, bounds: CGRect(x: 100, y: 200, width: 260, height: 300),
                                            kind: kind)
        }

        var typedCharacters: String { String(actions.compactMap { if case .type(let c) = $0 { c } else { nil } }) }

        var environment: RemoteAuthPromptTypist.Environment {
            RemoteAuthPromptTypist.Environment(
                window: { self.window },
                frontPID: { self.front },
                secureInput: { self.secure },
                click: { point in
                    self.actions.append(.click(point))
                    guard self.clickFocuses, let window = self.window, window.bounds.contains(point) else { return }
                    self.front = window.pid
                    self.secure = self.focusLandsInPassword
                },
                key: { code, flags in
                    self.actions.append(.key(code, flags))
                    guard self.front == self.window?.pid else { return }
                    switch code {
                    case RemoteAuthPromptTypist.escape:
                        self.window = nil
                        self.front = 99
                        self.secure = false
                    case RemoteAuthPromptTypist.returnKey where !self.secure:
                        self.secure = true  // 「使用密码…」
                    case RemoteAuthPromptTypist.returnKey:
                        if self.typed == self.rightPassword {
                            self.window = nil
                            self.front = 99
                            self.secure = false
                        }
                        self.typed = ""
                    case RemoteAuthPromptTypist.delete:
                        self.typed = ""
                    default:
                        break
                    }
                },
                type: { character in
                    self.actions.append(.type(character))
                    self.typed.append(character)
                    if let limit = self.stealFocusAfter, self.typed.count >= limit {
                        self.front = 99
                        self.secure = false
                    }
                },
                sleep: { _ in await Task.yield() })
        }
    }

    func test_fill_brings_the_dialog_forward_then_types_and_reports_accepted() async {
        let system = FakeSystem(kind: .authorization)
        let outcome = await RemoteAuthPromptTypist.answer(promptID: 7, action: .fill, password: "hunter2",
                                                          environment: system.environment)
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(system.actions.first, .click(CGPoint(x: 230, y: 230)), "先点标题区把框叫到前台")
        XCTAssertEqual(system.typedCharacters, "hunter2")
        XCTAssertEqual(system.actions.last, .key(RemoteAuthPromptTypist.returnKey, []))
        XCTAssertTrue(system.actions.contains(.key(RemoteAuthPromptTypist.keyA, .maskCommand)), "打字前清空密码框")
    }

    func test_local_authentication_switches_to_password_with_return_and_reports_rejected() async {
        let system = FakeSystem(kind: .localAuthentication)
        system.focusLandsInPassword = false
        let outcome = await RemoteAuthPromptTypist.answer(promptID: 7, action: .fill, password: "wrong",
                                                          environment: system.environment)
        XCTAssertEqual(outcome, .rejected)
        let firstReturn = system.actions.firstIndex(of: .key(RemoteAuthPromptTypist.returnKey, []))
        let firstType = system.actions.firstIndex { if case .type = $0 { true } else { false } }
        XCTAssertNotNil(firstReturn)
        XCTAssertLessThan(firstReturn ?? .max, firstType ?? .min, "先回车改用密码，再打字")
        XCTAssertNotNil(system.window, "密码不对：框还在")
    }

    func test_never_types_when_the_dialog_cannot_be_brought_forward() async {
        let system = FakeSystem(kind: .authorization)
        system.clickFocuses = false
        let outcome = await RemoteAuthPromptTypist.answer(promptID: 7, action: .fill, password: "hunter2",
                                                          environment: system.environment)
        XCTAssertEqual(outcome, .notFocused)
        XCTAssertEqual(system.actions.count, 1, "只点了一下，没有任何按键：按键会落进当时的前台 App")
    }

    func test_stops_typing_when_focus_is_lost_midway() async {
        let system = FakeSystem(kind: .authorization)
        system.stealFocusAfter = 3
        let outcome = await RemoteAuthPromptTypist.answer(promptID: 7, action: .fill, password: "hunter2",
                                                          environment: system.environment)
        XCTAssertEqual(outcome, .notFocused)
        XCTAssertEqual(system.typedCharacters, "hun", "点走之后一个字都不再打")
        XCTAssertNotEqual(system.actions.last, .key(RemoteAuthPromptTypist.returnKey, []), "也不回车")
    }

    func test_replaced_dialog_and_empty_password_do_nothing() async {
        let system = FakeSystem(kind: .authorization)
        let replaced = await RemoteAuthPromptTypist.answer(promptID: 8, action: .fill, password: "hunter2",
                                                           environment: system.environment)
        XCTAssertEqual(replaced, .gone)
        let empty = await RemoteAuthPromptTypist.answer(promptID: 7, action: .fill, password: "",
                                                        environment: system.environment)
        XCTAssertEqual(empty, .notFocused)
        XCTAssertTrue(system.actions.isEmpty)
    }

    func test_cancel_presses_escape_and_types_nothing() async {
        let system = FakeSystem(kind: .localAuthentication)
        system.focusLandsInPassword = false
        let outcome = await RemoteAuthPromptTypist.answer(promptID: 7, action: .cancel, password: nil,
                                                          environment: system.environment)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(system.actions.last, .key(RemoteAuthPromptTypist.escape, []))
        XCTAssertTrue(system.typedCharacters.isEmpty)
    }

    // MARK: - 端到端（回环）

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func connect(_ mac: FakeDesktopMac) async throws -> (RemoteHostServer, RemoteMacClient, RemoteDesktopSession) {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      desktopEnvironment: mac.environment())
        server.start()
        let ready = await waitUntil { server.port != nil }
        XCTAssertTrue(ready, "服务端没起来：\(server.status)")
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "测试 iPhone",
                                    publicKey: try identity.localIdentity().publicKey.rawRepresentation, pairedAt: Date()))
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(server.port))!),
                                     identity: identity)
        await client.connect()
        XCTAssertEqual(client.state, .connected)
        let session = RemoteDesktopSession(client: client, maxWidth: 1206, maxHeight: 2622)
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        return (server, client, session)
    }

    func test_prompt_is_reported_filled_and_cleared_end_to_end() async throws {
        let mac = FakeDesktopMac()
        mac.screen.locked = false
        let (server, client, session) = try await connect(mac)
        defer { session.stop(); client.disconnect(); server.stop() }
        XCTAssertTrue(client.supportsAuthPrompt)
        _ = await waitUntil { !session.awaitingFirstFrame }

        let prompt = RemoteDesktopAuthPrompt(id: 31, kind: .localAuthentication)
        mac.screen.authPrompt = prompt
        let reported = await waitUntil { session.screen.authPrompt == prompt }
        XCTAssertTrue(reported, "框出现后半秒内报给主控端")
        guard case .actionable(let shown, let title, _) = session.authPromptBanner(macName: "测试 Mac") else {
            return XCTFail("开了远程解锁：给填密码 / 取消的入口")
        }
        XCTAssertEqual(shown, prompt)
        XCTAssertTrue(title.contains("测试 Mac"))

        let outcome = await session.answerAuthPrompt(prompt, action: .fill, password: "hunter2")
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(mac.screen.authPromptAnswers.map(\.id), [31])
        XCTAssertEqual(mac.screen.authPromptAnswers.first?.password, "hunter2")
        let cleared = await waitUntil { session.screen.authPrompt == nil }
        XCTAssertTrue(cleared, "框关了：状态跟着清掉")
        XCTAssertEqual(session.authPromptBanner(macName: "测试 Mac"), .none)
    }

    func test_rejected_password_keeps_the_prompt_and_says_why() async throws {
        let mac = FakeDesktopMac()
        mac.screen.locked = false
        mac.screen.authPrompt = RemoteDesktopAuthPrompt(id: 5, kind: .authorization)
        mac.screen.authPromptAttempt = .rejected
        let (server, client, session) = try await connect(mac)
        defer { session.stop(); client.disconnect(); server.stop() }
        let reported = await waitUntil { session.screen.authPrompt != nil }
        XCTAssertTrue(reported, "开流时已有的框随第一份状态报过去")

        let outcome = await session.answerAuthPrompt(try XCTUnwrap(session.screen.authPrompt), action: .fill,
                                                     password: "nope")
        XCTAssertEqual(outcome, .rejected)
        XCTAssertNotNil(outcome.failureMessage)
        XCTAssertNotNil(session.screen.authPrompt)
    }

    func test_setting_off_reports_prompt_but_refuses_to_fill() async throws {
        let mac = FakeDesktopMac()
        mac.screen.locked = false
        mac.unlockEnabled = false
        mac.screen.authPrompt = RemoteDesktopAuthPrompt(id: 5, kind: .authorization)
        let (server, client, session) = try await connect(mac)
        defer { session.stop(); client.disconnect(); server.stop() }
        _ = await waitUntil { !session.awaitingFirstFrame }
        let reported = await waitUntil { session.screen.authPrompt != nil }
        XCTAssertTrue(reported)
        guard case .caption(let text) = session.authPromptBanner(macName: "测试 Mac") else {
            return XCTFail("没开远程解锁：只提示一句")
        }
        XCTAssertTrue(text.contains("允许远程解锁"))

        let outcome = await session.answerAuthPrompt(try XCTUnwrap(session.screen.authPrompt), action: .fill,
                                                     password: "hunter2")
        XCTAssertEqual(outcome, .notAllowed)
        XCTAssertTrue(mac.screen.authPromptAnswers.isEmpty, "密码没交给屏幕控制")
    }

    func test_locked_mac_reports_no_prompt() async throws {
        let mac = FakeDesktopMac()
        mac.screen.locked = true
        mac.screen.authPrompt = RemoteDesktopAuthPrompt(id: 5, kind: .authorization)
        let (server, client, session) = try await connect(mac)
        defer { session.stop(); client.disconnect(); server.stop() }
        let locked = await waitUntil { session.screen.locked }
        XCTAssertTrue(locked)
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(session.screen.authPrompt, "锁屏上先解锁，不报框")
    }
}
