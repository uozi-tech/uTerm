import SwiftData
import XCTest
@testable import uTerm

/// `session-*` 动作走完整的 `ControlHandler`：门禁、开会话、引导、发输入、`--secret`
/// 的安全输入框、上限、关闭。远端是 `FakeRemote` 脚本化的假 shell。
@MainActor
final class ControlSessionHandlerTests: XCTestCase {

    // MARK: - 夹具

    /// 只会开 PTY 的假连接池。每开一条就造一个 `FakeRemote`。
    actor PTYPool: ControlConnectionPooling {
        private(set) var remotes: [FakeRemote] = []
        private var openError: (any Error)?

        func setOpenError(_ error: (any Error)?) { openError = error }

        func openPTY(
            for host: HostConnectionSpec,
            spec: PTYSpec,
            onOutput: @escaping @Sendable (Data) -> Void,
            onEnd: @escaping @Sendable (PTYEnding) -> Void
        ) async throws -> any PTYHandle {
            if let openError { throw openError }
            let remote = FakeRemote(onOutput: onOutput, onEnd: onEnd)
            remotes.append(remote)
            return remote
        }

        func executor(for host: HostConnectionSpec, maxLines: Int, maxBytes: Int) async throws -> SSHCommandExecutor {
            throw ControlConnectError.connectFailed("测试不跑 exec")
        }
        func borrowSFTP(for host: HostConnectionSpec) async throws -> any SFTPProviding {
            throw ControlConnectError.connectFailed("测试不建 SFTP")
        }
        func returnSFTP(_ session: any SFTPProviding, for hostID: UUID) async {}
        func disconnect(hostID: UUID) async {}
        func disconnectAll() async {}
        func heldHostIDs() async -> [UUID] { [] }
        func lastHostKeyChallenge(hostID: UUID) async -> HostKeyChallenge? { nil }
        func recordChallenge(hostID: UUID, _ challenge: HostKeyChallenge) async {}
        func trustHostKey(host: HostConnectionSpec, fingerprint: String) async throws {}
    }

    /// 脚本化的远端：登录 shell 先打 motd 与提示符；收到引导行就打就绪标记；收到 base64
    /// 命令就按命令表演 —— `sudo whoami` 要密码，密码对了回 `root` 并以 0 退出。
    nonisolated final class FakeRemote: PTYHandle, @unchecked Sendable {
        private let lock = NSLock()
        private let onOutput: @Sendable (Data) -> Void
        private let onEnd: @Sendable (PTYEnding) -> Void
        private var written = Data()
        private var payload: String?
        private var awaitingPassword = false
        private var isClosed = false

        init(onOutput: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable (PTYEnding) -> Void) {
            self.onOutput = onOutput
            self.onEnd = onEnd
            // 真实通道：开起来就有 motd 与提示符，早于任何输入的回话（在调用方 attach
            // 之前就到）。
            onOutput(Data("Welcome to FakeOS\r\n$ ".utf8))
        }

        var allWritten: String { lock.withLock { String(decoding: written, as: UTF8.self) } }
        var closed: Bool { lock.withLock { isClosed } }

        func write(_ data: Data) {
            let text = String(decoding: data, as: UTF8.self)
            let reply: String? = lock.withLock {
                written.append(data)
                if text == String(decoding: ControlPTYCommand.bootstrapLine, as: UTF8.self) {
                    payload = ""
                    return "\(text)\r\n\r\n__UTERM_PTY_READY__\r\n"
                }
                if var buffered = payload {
                    buffered += text
                    guard buffered.hasSuffix("\n.\n") else {
                        payload = buffered
                        return nil
                    }
                    payload = nil
                    let encoded = buffered.dropLast(3).replacingOccurrences(of: "\n", with: "")
                    let command = String(decoding: Data(base64Encoded: encoded) ?? Data(), as: UTF8.self)
                    if command == "sudo whoami" {
                        awaitingPassword = true
                        return "[sudo] password for root: "
                    }
                    return "ran: \(command)\r\n"
                }
                if awaitingPassword {
                    awaitingPassword = false
                    return text == "hunter2\r" ? "\r\nroot\r\n" : "\r\nSorry, try again.\r\n"
                }
                if text == "echo hi\r" { return "echo hi\r\nhi\r\n$ " }
                return nil
            }
            guard let reply else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { [self] in
                onOutput(Data(reply.utf8))
                if reply.hasSuffix("root\r\n") { onEnd(.exited(0)) }
            }
        }

        func resize(cols: Int, rows: Int) {}

        func close() {
            let first: Bool = lock.withLock {
                defer { isClosed = true }
                return !isClosed
            }
            if first { onEnd(.closedLocally) }
        }
    }

    final class FakeSecretPrompt: ControlSecretPrompting {
        var answer: String?
        private(set) var requests: [ControlSecretRequest] = []

        func requestSecret(_ request: ControlSecretRequest, timeout: TimeInterval) async -> String? {
            requests.append(request)
            return answer
        }
    }

    private struct StubKeychain: KeychainReading {
        func load(profileID: UUID, kind: SecretKind) throws -> String? {
            kind == .password ? "pw" : nil
        }
    }

    private var container: ModelContainer!
    private var settings: ControlSettings!
    private var pool: PTYPool!
    private var prompt: FakeSecretPrompt!
    private var sessions: ControlPTYSessions!
    private var handler: ControlHandler!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self, QuickCommand.self, QuickCommandRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "control-session-tests-\(UUID().uuidString)"))
        settings = ControlSettings(defaults: defaults)
        settings.isEnabled = true
        settings.allowMutations = true
        pool = PTYPool()
        prompt = FakeSecretPrompt()
        sessions = ControlPTYSessions()
        handler = ControlHandler(
            settings: settings,
            modelContainer: container,
            forwardingCoordinator: ForwardingCoordinator(),
            pool: pool,
            registry: TerminalSessionRegistry(),
            sessions: sessions,
            secretPrompt: prompt
        )
        HostConnectionSpec.keychainOverride = StubKeychain()
    }

    override func tearDown() async throws {
        sessions.closeAll()
        HostConnectionSpec.keychainOverride = nil
        try await super.tearDown()
    }

    @discardableResult
    private func makeProfile(name: String, sftpOnly: Bool = false) -> ServerProfile {
        let profile = ServerProfile()
        profile.name = name
        profile.host = "10.0.0.1"
        profile.port = 22
        profile.username = "root"
        profile.authMethod = .password
        profile.sftpOnly = sftpOnly
        container.mainContext.insert(profile)
        try? container.mainContext.save()
        return profile
    }

    private func start(_ host: String = "web", command: String? = nil) async -> ControlResponse {
        await handler.handle(ControlRequest(
            action: .sessionStart, host: host, command: command, waitSeconds: 3))
    }

    // MARK: - 用例

    func testLoginShellSessionShowsTheMotdAndRunsInput() async throws {
        makeProfile(name: "web")
        let started = await start()
        XCTAssertTrue(started.ok, started.message)
        let session = try XCTUnwrap(started.session)
        XCTAssertNil(session.command)
        XCTAssertEqual(session.output, "Welcome to FakeOS\n$ ")
        XCTAssertTrue(session.awaitingInput)

        let sent = await handler.handle(ControlRequest(
            action: .sessionSend, text: "echo hi", enter: true, session: String(session.id.prefix(6)),
            waitSeconds: 3))
        XCTAssertTrue(sent.ok, sent.message)
        XCTAssertEqual(sent.session?.output, "echo hi\nhi\n$ ")
    }

    func testCommandSessionWaitsForPasswordAndTakesItFromTheUser() async throws {
        makeProfile(name: "web")
        let started = await start(command: "sudo whoami")
        XCTAssertTrue(started.ok, started.message)
        let session = try XCTUnwrap(started.session)
        XCTAssertEqual(session.output, "[sudo] password for root: ", "motd / 回显 / 标记都不该透出来")
        XCTAssertTrue(session.passwordPrompt)
        XCTAssertTrue(started.message.contains("--secret"), "提示调用方改用 --secret")

        prompt.answer = "hunter2"
        let sent = await handler.handle(ControlRequest(
            action: .sessionSend, session: session.id, secret: true, prompt: "web 的 sudo 密码",
            waitSeconds: 3))
        XCTAssertTrue(sent.ok, sent.message)
        XCTAssertEqual(prompt.requests.first?.host, "web")
        XCTAssertEqual(prompt.requests.first?.promptLine, "[sudo] password for root:", "提示行取自真实输出")
        XCTAssertEqual(prompt.requests.first?.purpose, "web 的 sudo 密码")
        XCTAssertEqual(sent.session?.output, "\nroot\n")
        XCTAssertEqual(sent.session?.running, false)
        XCTAssertEqual(sent.session?.exitCode, 0)
        let data = try JSONEncoder().encode(sent)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("hunter2"), "密码绝不进响应")
    }

    func testCancelledSecretWritesNothing() async throws {
        makeProfile(name: "web")
        let startedSession = await start(command: "sudo whoami").session
        let session = try XCTUnwrap(startedSession)
        let remotes = await pool.remotes
        let remote = try XCTUnwrap(remotes.first)
        let before = remote.allWritten

        prompt.answer = nil
        let sent = await handler.handle(ControlRequest(action: .sessionSend, session: session.id, secret: true))
        XCTAssertFalse(sent.ok)
        XCTAssertEqual(sent.code, ControlErrorCode.secret_cancelled.rawValue)
        XCTAssertEqual(remote.allWritten, before)
    }

    func testSecretRejectsInlineText() async throws {
        makeProfile(name: "web")
        let startedSession = await start().session
        let session = try XCTUnwrap(startedSession)
        let sent = await handler.handle(ControlRequest(
            action: .sessionSend, text: "hunter2", session: session.id, secret: true))
        XCTAssertEqual(sent.code, ControlErrorCode.invalid_request.rawValue)
        XCTAssertTrue(prompt.requests.isEmpty)
    }

    func testKeysAreTranslatedAndUnknownKeysRejected() async throws {
        makeProfile(name: "web")
        let startedSession = await start().session
        let session = try XCTUnwrap(startedSession)
        let remotes = await pool.remotes
        let remote = try XCTUnwrap(remotes.first)

        let sent = await handler.handle(ControlRequest(
            action: .sessionSend, session: session.id, keys: ["ctrl-c", "up"], waitSeconds: 0))
        XCTAssertTrue(sent.ok, sent.message)
        XCTAssertTrue(remote.allWritten.hasSuffix("\u{03}\u{1B}[A"))

        let bad = await handler.handle(ControlRequest(
            action: .sessionSend, session: session.id, keys: ["hyper"], waitSeconds: 0))
        XCTAssertEqual(bad.code, ControlErrorCode.invalid_request.rawValue)
    }

    func testWaitForReportsWhetherItMatched() async throws {
        makeProfile(name: "web")
        let started = await handler.handle(ControlRequest(
            action: .sessionStart, host: "web", waitSeconds: 3, waitFor: "^\\$ $"))
        let session = try XCTUnwrap(started.session)
        XCTAssertEqual(session.matched, true)

        let read = await handler.handle(ControlRequest(
            action: .sessionRead, session: session.id, waitSeconds: 0.3, waitFor: "never"))
        XCTAssertTrue(read.ok)
        XCTAssertEqual(read.session?.matched, false)

        let badRegex = await handler.handle(ControlRequest(
            action: .sessionRead, session: session.id, waitFor: "("))
        XCTAssertEqual(badRegex.code, ControlErrorCode.invalid_request.rawValue)
    }

    func testPerHostLimit() async {
        makeProfile(name: "web")
        for _ in 0..<ControlProtocol.maxSessionsPerHost {
            let response = await handler.handle(ControlRequest(action: .sessionStart, host: "web", waitSeconds: 0))
            XCTAssertTrue(response.ok, response.message)
        }
        let over = await handler.handle(ControlRequest(action: .sessionStart, host: "web", waitSeconds: 0))
        XCTAssertEqual(over.code, ControlErrorCode.session_limit.rawValue)
    }

    func testCloseEndsTheSessionAndForgetsIt() async throws {
        makeProfile(name: "web")
        let startedSession = await start().session
        let session = try XCTUnwrap(startedSession)
        let remotes = await pool.remotes
        let remote = try XCTUnwrap(remotes.first)

        let listed = await handler.handle(ControlRequest(action: .sessions))
        XCTAssertEqual(listed.sessions?.count, 1)

        let closed = await handler.handle(ControlRequest(action: .sessionClose, session: session.id))
        XCTAssertTrue(closed.ok, closed.message)
        XCTAssertTrue(remote.closed)
        XCTAssertEqual(closed.session?.running, false)
        XCTAssertEqual(closed.session?.endReason, "closed")
        let after = await handler.handle(ControlRequest(action: .sessions))
        XCTAssertEqual(after.sessions?.count, 0)

        let gone = await handler.handle(ControlRequest(action: .sessionRead, session: session.id))
        XCTAssertEqual(gone.code, ControlErrorCode.session_not_found.rawValue)
    }

    func testSendToAnEndedSessionReportsSessionEnded() async throws {
        makeProfile(name: "web")
        let startedSession = await start(command: "sudo whoami").session
        let session = try XCTUnwrap(startedSession)
        prompt.answer = "hunter2"
        _ = await handler.handle(ControlRequest(action: .sessionSend, session: session.id, secret: true, waitSeconds: 3))

        let late = await handler.handle(ControlRequest(action: .sessionSend, text: "x", session: session.id))
        XCTAssertEqual(late.code, ControlErrorCode.session_ended.rawValue)
        XCTAssertEqual(late.session?.exitCode, 0)
    }

    func testGates() async {
        makeProfile(name: "web")
        makeProfile(name: "files", sftpOnly: true)

        let sftpOnly = await start("files")
        XCTAssertEqual(sftpOnly.code, ControlErrorCode.host_sftp_only.rawValue)

        settings.allowMutations = false
        let gated = await start()
        XCTAssertEqual(gated.code, ControlErrorCode.mutations_disabled.rawValue)
        // 看、关不受改动开关管 —— 开关关了也得能收拾残局。
        let listed = await handler.handle(ControlRequest(action: .sessions))
        XCTAssertTrue(listed.ok)
        let close = await handler.handle(ControlRequest(action: .sessionClose, session: "nope"))
        XCTAssertEqual(close.code, ControlErrorCode.session_not_found.rawValue)
    }

    func testOpenFailureIsReportedAsAConnectError() async {
        makeProfile(name: "web")
        await pool.setOpenError(ControlConnectError.hostKeyUnknown(fingerprint: "SHA256:abc", algorithm: ""))
        let response = await start()
        XCTAssertEqual(response.code, ControlErrorCode.host_key_unknown.rawValue)
        XCTAssertEqual(response.hostKey?.fingerprint, "SHA256:abc")
        XCTAssertEqual(sessions.all.count, 0, "没开起来的会话不进登记处")
    }

    func testRunWithTTYNeedsDescriptors() async {
        makeProfile(name: "web")
        let response = await handler.handle(ControlRequest(action: .run, host: "web", tty: true))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }
}
