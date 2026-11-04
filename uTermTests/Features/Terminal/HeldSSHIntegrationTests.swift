import AppKit
import SwiftData
import SwiftTerm
import XCTest
@testable import uTerm

/// 真的起 `uterm-holder` + `uterm-ssh` 连一台真 sshd。没有测试服务器时跳过，起一个：
///
/// `docker run -d --name uterm-s6 -p 127.0.0.1:2277:22 <alpine+openssh>`，root 密码 `s6-test-pass`，`PermitRootLogin yes`。
///
/// App 没了用断开连接代替（对 holder 来说没有区别）。
@MainActor
final class HeldSSHIntegrationTests: XCTestCase {
    private static let namespace = "integration-test-ssh"
    private static let host = "127.0.0.1"
    private static let port = 2277
    private let client = LocalShellAgentClient()
    private var sessionIDs: [UUID] = []
    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        guard Self.serverIsReachable() else { throw XCTSkip("没有测试用 sshd（\(Self.host):\(Self.port)）") }
        container = try ModelContainer(for: KnownHost.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    override func tearDown() async throws {
        for id in sessionIDs { await HolderProbe.terminate(id, client: client, namespace: Self.namespace) }
        client.invalidate()
        try await super.tearDown()
    }

    private static func serverIsReachable() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    private func makeSession() -> UUID {
        let id = UUID()
        sessionIDs.append(id)
        return id
    }

    /// 记下解析了几次凭据、问了几次主机密钥。
    private final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var _auth = 0
        private var _approvals = 0
        var auth: Int { lock.withLock { _auth } }
        var approvals: Int { lock.withLock { _approvals } }
        func countAuth() { lock.withLock { _auth += 1 } }
        func countApproval() { lock.withLock { _approvals += 1 } }
    }

    private func backend(_ id: UUID, password: String = "s6-test-pass", approve: Bool = true, counters: Counters = Counters(),
                         attributes: Data? = nil) -> HeldSSHBackend {
        HeldSSHBackend(
            client: client, namespace: Self.namespace, sessionID: id, columns: 100, rows: 30,
            target: HeldSSHBackend.Target(
                profile: SSHConnection.ProfileSnapshot(host: Self.host, port: Self.port, jumpHost: nil),
                resolveAuth: {
                    counters.countAuth()
                    return (.password(username: "root", password: password), nil)
                },
                hostKeyVerifier: HostKeyVerifier(modelContainer: container),
                hostKeyApprover: { _ in
                    counters.countApproval()
                    return approve
                }),
            attributes: attributes)
    }

    private func screen(_ session: TerminalSession) -> String {
        session.snapshotScreen(lines: 200).lines.joined(separator: "\n")
    }

    private func wait(timeout: TimeInterval = 15, for condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return true
    }

    private func sessionExists(_ id: UUID) async throws -> Bool {
        try await client.listSessions(namespace: Self.namespace).contains(id)
    }

    func test_new_session_then_reattach_keeps_remote_shell_without_credentials() async throws {
        let id = makeSession()
        let counters = Counters()
        let first = TerminalSession()
        let firstBackend = backend(id, counters: counters)
        await first.connect(using: firstBackend)
        XCTAssertEqual(first.connectionState, .connected)
        XCTAssertEqual(counters.auth, 1)
        XCTAssertEqual(counters.approvals, 1, "首次连接要问主机密钥")

        try await first.injectInput("echo shell-$$", appendEnter: true)
        let appeared = await wait { self.screen(first).firstMatch(of: /shell-\d+/) != nil }
        XCTAssertTrue(appeared)
        let remotePID = try XCTUnwrap(screen(first).firstMatch(of: /shell-(\d+)/)?.1).description

        first.saveHeldCheckpointNow()
        // App 不在期间远端接着输出。
        try await first.injectInput("sleep 1; echo while-away", appendEnter: true)
        await firstBackend.detach()
        first.dispose()
        try await Task.sleep(for: .seconds(2))

        let second = TerminalSession()
        await second.connect(using: backend(id, counters: counters))
        XCTAssertEqual(second.connectionState, .connected)
        XCTAssertEqual(counters.auth, 1, "接回不碰凭据")
        XCTAssertEqual(counters.approvals, 1, "接回不问主机密钥")
        let restored = await wait { self.screen(second).contains("while-away") }
        XCTAssertTrue(restored, screen(second))

        try await second.injectInput("echo again-$$", appendEnter: true)
        let sameShell = await wait { self.screen(second).contains("again-\(remotePID)") }
        XCTAssertTrue(sameShell, "接回的是同一个远端 shell：\(screen(second))")
        await second.close()
    }

    func test_wrong_password_fails_with_connect_error_and_leaves_no_session() async throws {
        let id = makeSession()
        let session = TerminalSession()
        await session.connect(using: backend(id, password: "wrong"))
        guard case .failed(let message) = session.connectionState else {
            return XCTFail("应该失败：\(session.connectionState)")
        }
        XCTAssertTrue(message.contains("connectFailed"), message)
        let gone = try await waitForRemoved(id)
        XCTAssertTrue(gone, "失败的会话不能留在机器上")
    }

    func test_rejected_host_key_fails_and_is_not_remembered() async throws {
        let id = makeSession()
        let counters = Counters()
        let session = TerminalSession()
        await session.connect(using: backend(id, approve: false, counters: counters))
        guard case .failed = session.connectionState else { return XCTFail("拒绝主机密钥应该失败") }
        XCTAssertEqual(counters.approvals, 1)

        let retry = TerminalSession()
        let retryCounters = Counters()
        let retryID = makeSession()
        await retry.connect(using: backend(retryID, counters: retryCounters))
        XCTAssertEqual(retry.connectionState, .connected)
        XCTAssertEqual(retryCounters.approvals, 1, "上次拒绝了，这次还要问")

        // 这次接受了，记住了：再开一条不用问。
        let thirdID = makeSession()
        let thirdCounters = Counters()
        let third = TerminalSession()
        await third.connect(using: backend(thirdID, counters: thirdCounters))
        XCTAssertEqual(third.connectionState, .connected)
        XCTAssertEqual(thirdCounters.approvals, 0)
        await retry.close()
        await third.close()
    }

    /// 同时开几个标签连一台新主机只问一次，一起得到答案。
    func test_concurrent_connects_to_unknown_host_ask_once() async throws {
        let counters = Counters()
        let sessions = [TerminalSession(), TerminalSession(), TerminalSession()]
        let backends = sessions.map { _ in backend(makeSession(), counters: counters) }
        await withTaskGroup(of: Void.self) { group in
            for (session, backend) in zip(sessions, backends) {
                group.addTask { await session.connect(using: backend) }
            }
        }
        for session in sessions { XCTAssertEqual(session.connectionState, .connected) }
        XCTAssertEqual(counters.approvals, 1, "同时到达的只问一次；晚到的看到已信任，不用问")
        for session in sessions { await session.close() }
    }

    /// 经跳板机：外层连测试服务器，内层连它自己的 22 端口。
    func test_connects_through_jump_host() async throws {
        let counters = Counters()
        let session = TerminalSession()
        await session.connect(using: HeldSSHBackend(
            client: client, namespace: Self.namespace, sessionID: makeSession(), columns: 100, rows: 30,
            target: HeldSSHBackend.Target(
                profile: SSHConnection.ProfileSnapshot(
                    host: "127.0.0.1", port: 22,
                    jumpHost: .init(host: Self.host, port: Self.port)),
                resolveAuth: {
                    counters.countAuth()
                    let auth = ResolvedAuth.password(username: "root", password: "s6-test-pass")
                    return (auth, auth)
                },
                hostKeyVerifier: HostKeyVerifier(modelContainer: container),
                hostKeyApprover: { _ in
                    counters.countApproval()
                    return true
                }),
            attributes: nil))
        XCTAssertEqual(session.connectionState, .connected)
        XCTAssertEqual(counters.approvals, 2, "跳板机和目标各问一次")
        try await session.injectInput("echo via-jump-$((1+1))", appendEnter: true)
        let works = await wait { self.screen(session).contains("via-jump-2") }
        XCTAssertTrue(works, screen(session))
        await session.close()
    }

    func test_missing_jump_credentials_fail_without_falling_back_to_direct() async throws {
        let session = TerminalSession()
        await session.connect(using: HeldSSHBackend(
            client: client, namespace: Self.namespace, sessionID: makeSession(), columns: 100, rows: 30,
            target: HeldSSHBackend.Target(
                profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: 22, jumpHost: .init(host: Self.host, port: Self.port)),
                resolveAuth: { (.password(username: "root", password: "s6-test-pass"), nil) },
                hostKeyVerifier: HostKeyVerifier(modelContainer: container),
                hostKeyApprover: { _ in true }),
            attributes: nil))
        guard case .failed(let message) = session.connectionState else { return XCTFail("应该失败") }
        XCTAssertTrue(message.contains("jumpHostFailed"), message)
    }

    func test_close_ends_session_and_same_id_can_open_again_immediately() async throws {
        let id = makeSession()
        let first = TerminalSession()
        await first.connect(using: backend(id))
        XCTAssertEqual(first.connectionState, .connected)
        await first.close()

        // 窗口关了马上重开：快照里还是这个 id，要得到新连接而不是接上将死的会话。
        let counters = Counters()
        let second = TerminalSession()
        await second.connect(using: backend(id, counters: counters))
        XCTAssertEqual(second.connectionState, .connected)
        XCTAssertEqual(counters.auth, 1, "这是新连接")
        try await second.injectInput("echo fresh", appendEnter: true)
        let works = await wait { self.screen(second).contains("fresh\n") || self.screen(second).contains("fresh") }
        XCTAssertTrue(works)
        await second.close()
    }

    func test_remote_shell_exit_reports_disconnected_and_keeps_last_output_for_reattach() async throws {
        let id = makeSession()
        let session = TerminalSession()
        await session.connect(using: backend(id))
        try await session.injectInput("exit", appendEnter: true)
        let ended = await wait { session.connectionState == .disconnected }
        XCTAssertTrue(ended)
        let gone = try await waitForRemoved(id)
        XCTAssertTrue(gone)
    }

    func test_resize_reaches_remote_pty() async throws {
        let id = makeSession()
        let session = TerminalSession()
        let held = backend(id)
        await session.connect(using: held)
        await held.resize(cols: 111, rows: 37)
        try await Task.sleep(for: .milliseconds(300))
        try await session.injectInput("stty size", appendEnter: true)
        let reached = await wait { self.screen(session).contains("37 111") }
        XCTAssertTrue(reached, screen(session))
        await session.close()
    }

    func test_probe_on_healthy_connection_keeps_session() async throws {
        let id = makeSession()
        let session = TerminalSession()
        let held = backend(id)
        await session.connect(using: held)
        let alive = await held.verifyConnectionAlive()
        XCTAssertTrue(alive)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(session.connectionState, .connected)
        try await session.injectInput("echo still-here", appendEnter: true)
        let works = await wait { self.screen(session).contains("still-here\n") || self.screen(session).contains("still-here") }
        XCTAssertTrue(works)
        await session.close()
    }

    func test_restorer_hands_sessions_to_their_window_in_order_and_ends_orphans() async throws {
        let window = UUID()
        let server = UUID()
        let deletedServer = UUID()
        let held: [(UUID, UUID, Double)] = [(makeSession(), server, 2), (makeSession(), server, 1), (makeSession(), deletedServer, 3)]
        var backends: [HeldSSHBackend] = []
        for (id, serverID, order) in held {
            let attributes = try JSONEncoder().encode(SSHSessionAttributes(
                windowID: window, windowKind: TerminalWindowKind.terminal, serverID: serverID, title: "t\(order)", order: order))
            let session = TerminalSession()
            let backend = backend(id, attributes: attributes)
            await session.connect(using: backend)
            XCTAssertEqual(session.connectionState, .connected)
            backends.append(backend)
        }
        let unattributed = makeSession()
        let noAttributes = backend(unattributed)
        await TerminalSession().connect(using: noAttributes)
        backends.append(noAttributes)
        for backend in backends { await backend.detach() }

        let restorer = SSHSessionRestorer(client: client, namespace: Self.namespace)
        restorer.install(knownServerIDs: { [server] }, openWindow: { _, _, _ in })
        await restorer.takeInventory()
        let claimed = restorer.takePending(windowID: window)
        XCTAssertEqual(claimed.map(\.id), [held[1].0, held[0].0], "按打开的先后排，已删除服务器的不算")
        XCTAssertEqual(claimed.first?.title, "t1.0")
        XCTAssertEqual(restorer.takePending(windowID: window), [], "只给一次")
        let orphanGone = try await waitForRemoved(held[2].0)
        let unattributedGone = try await waitForRemoved(unattributed)
        XCTAssertTrue(orphanGone)
        XCTAssertTrue(unattributedGone)
    }

    /// 后台标签的窗格没有视图，不会自己连接。恢复时要立刻接回，否则手机、CLI 和退出收尾都看不到它。
    func test_restored_background_tabs_reattach_without_being_shown() async throws {
        let namespace = SSHSessionNamespace.current
        let id = UUID()
        let first = TerminalSession()
        let held = HeldSSHBackend(
            client: client, namespace: namespace, sessionID: id, columns: 100, rows: 30,
            target: HeldSSHBackend.Target(
                profile: SSHConnection.ProfileSnapshot(host: Self.host, port: Self.port, jumpHost: nil),
                resolveAuth: { (.password(username: "root", password: "s6-test-pass"), nil) },
                hostKeyVerifier: HostKeyVerifier(modelContainer: container),
                hostKeyApprover: { _ in true }),
            attributes: nil)
        await first.connect(using: held)
        XCTAssertEqual(first.connectionState, .connected)
        await held.detach()
        first.dispose()

        let profile = ServerProfile()
        profile.host = Self.host
        profile.port = Self.port
        profile.username = "root"
        let model = WorkspaceModel()
        let session = SSHSessionRestorer.Session(id: id, serverID: profile.id, title: "t", order: 1)
        // 后面再开一个标签盖住它，这个就是后台标签。
        model.adoptHeldSessions([session])
        model.openServer(profileID: UUID(), title: "front")
        model.reattachHeldSessions([session], profiles: [profile], modelContainer: container)
        let pane = try XCTUnwrap(model.terminalGroups.allTabs.first { $0.payload.id == id }?.payload)
        let reattached = await wait { pane.session.connectionState == .connected }
        XCTAssertTrue(reattached, "\(pane.session.connectionState)")
        await pane.session.close()
        model.dispose()
    }

    /// macOS 的本地网络权限可能拦 `uterm-ssh`（它不是 App 本身）。要手动跑：
    /// `TEST_RUNNER_UTERM_LAN_SSH_HOST=<局域网 IP>`。走到主机密钥这一步就拒绝，不发凭据，能碰任何开着 22 的设备。
    func test_lan_host_is_reachable_from_helper() async throws {
        guard let host = ProcessInfo.processInfo.environment["UTERM_LAN_SSH_HOST"] else { throw XCTSkip("没给局域网主机") }
        let counters = Counters()
        let target = HeldSSHBackend.Target(
            profile: SSHConnection.ProfileSnapshot(host: host, port: 22, jumpHost: nil),
            resolveAuth: { (.password(username: "uterm-probe", password: "unused"), nil) },
            hostKeyVerifier: HostKeyVerifier(modelContainer: container),
            hostKeyApprover: { _ in
                counters.countApproval()
                return false
            })
        let session = TerminalSession()
        await session.connect(using: HeldSSHBackend(client: client, namespace: Self.namespace, sessionID: makeSession(),
                                                    columns: 80, rows: 24, target: target, attributes: nil))
        print("LAN held: approvals=\(counters.approvals) state=\(session.connectionState)")
        XCTAssertEqual(counters.approvals, 1, "到得了主机密钥这一步才算连上：\(session.connectionState)")
    }

    private func waitForRemoved(_ id: UUID) async throws -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while try await sessionExists(id) {
            if Date() > deadline { return false }
            try await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}

@MainActor
final class WorkspaceHeldSessionTests: XCTestCase {
    func test_snapshot_records_session_id_and_restore_reuses_it() throws {
        let server = UUID()
        let model = WorkspaceModel()
        model.openServer(profileID: server, title: "t")
        let paneID = try XCTUnwrap(model.terminalGroups.allTabs.first?.payload.id)
        let snapshot = model.snapshot()
        let session = try XCTUnwrap(snapshot.terminalGroups?.groups.first?.tabs.first?.sessionID)
        XCTAssertEqual(session, paneID)

        let restored = WorkspaceModel()
        restored.restore(from: snapshot, knownServerIDs: [server])
        XCTAssertEqual(restored.terminalGroups.allTabs.first?.payload.id, session)
        model.dispose()
        restored.dispose()
    }

    func test_old_snapshot_without_session_id_still_decodes() throws {
        let json = #"{"serverProfileID":"\#(UUID().uuidString)","title":"t"}"#
        let decoded = try JSONDecoder().decode(TerminalTabSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(decoded.sessionID)
    }

    func test_adopt_skips_tabs_already_restored_from_snapshot() {
        let server = UUID()
        let model = WorkspaceModel()
        model.openServer(profileID: server, title: "t")
        let existing = model.terminalGroups.allTabs[0].payload.id
        let extra = UUID()
        model.adoptHeldSessions([
            SSHSessionRestorer.Session(id: existing, serverID: server, title: "t", order: 1),
            SSHSessionRestorer.Session(id: extra, serverID: server, title: "new", order: 2),
        ])
        XCTAssertEqual(model.terminalGroups.allTabs.count, 2)
        XCTAssertEqual(model.terminalGroups.allTabs.first { $0.payload.id == extra }?.payload.tabTitle, "new")
        model.dispose()
    }
}
