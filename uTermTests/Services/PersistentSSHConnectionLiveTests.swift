import Foundation
import SwiftData
import Synchronization
import XCTest
@testable import uTerm

/// `PersistentSSHConnection` 对着**真 sshd** 端到端跑：打包的 `uterm-holder` 传上去、经 exec 通道接入、
/// 断线后自己重连接回同一个 shell。
///
/// 需要外部 sshd，所以**默认跳过**。跑法（用完 `docker rm -f uterm-holder-live`）：
///
/// ```
/// docker build -t uterm-holder-e2e-sshd holder/e2e/sshd   # 先放一个 authorized_keys 进去，内容随意
/// docker run -d --name uterm-holder-live -p 127.0.0.1:2298:22 uterm-holder-e2e-sshd
/// TEST_RUNNER_UTERM_LIVE_SSH_PORT=2298 TEST_RUNNER_UTERM_LIVE_SSH_USER=dev TEST_RUNNER_UTERM_LIVE_SSH_PASSWORD=dev \
///   xcodebuild test-without-building … -only-testing:uTermTests/PersistentSSHConnectionLiveTests
/// ```
///
/// 账号缺省 root / `PASS`（和 `SupervisedExecLiveSSHTests` 的容器通用）。主机要是 Linux amd64 / arm64。
final class PersistentSSHConnectionLiveTests: XCTestCase {
    private var profile: SSHConnection.ProfileSnapshot!
    private var auth: ResolvedAuth!
    private var container: ModelContainer!
    private var opened: [PersistentSSHConnection] = []

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_LIVE_SSH_PORT"], let port = Int(raw) else {
            throw XCTSkip("没设 UTERM_LIVE_SSH_PORT，跳过真 sshd 集成测试")
        }
        profile = SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port, jumpHost: nil)
        auth = .password(username: env["UTERM_LIVE_SSH_USER"] ?? "root",
                         password: env["UTERM_LIVE_SSH_PASSWORD"] ?? "PASS")
        container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        // 每条用例从「没装」开始：安装那条路每次都走一遍。
        _ = try await run("rm -rf ~/.local/share/uterm ~/.local/state/uterm")
    }

    override func tearDown() async throws {
        for backend in opened { await backend.close() }
        opened = []
        try await super.tearDown()
    }

    // MARK: - 夹具

    private func makeBackend(sessionID: UUID = UUID()) -> PersistentSSHConnection {
        let backend = PersistentSSHConnection(
            sessionID: sessionID, profile: profile, auth: auth, jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: { _ in true })
        opened.append(backend)
        return backend
    }

    /// 另开一条独占连接跑一条命令（不经被测的后端）。
    private func run(_ command: String) async throws -> String {
        let client = try await SSHClientFactory.connect(
            profile: profile, auth: auth, jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: { _ in true })
        defer { Task { await client.close() } }
        return try await client.collectOutput(of: command)
    }

    /// 把后端的输出攒起来，供用例等某段文字出现。
    private final class Transcript: Sendable {
        private let collected = Mutex(Data())

        init(_ backend: PersistentSSHConnection) {
            Task {
                for await item in backend.outputItems {
                    if case .bytes(let data) = item { self.collected.withLock { $0.append(data) } }
                }
            }
        }

        var text: String { collected.withLock { String(decoding: $0, as: UTF8.self) } }

        func wait(for needle: String, timeout: Duration = .seconds(20),
                  file: StaticString = #filePath, line: UInt = #line) async {
            let deadline = ContinuousClock.now + timeout
            while !text.contains(needle) {
                guard ContinuousClock.now < deadline else {
                    XCTFail("等不到「\(needle)」，收到的最后一段：\(String(text.suffix(300)))", file: file, line: line)
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// `echo MARKER=$$` 的结果。回显的命令行里是 `MARKER=$$`，不会被当成结果。
    private func shellPID(in text: String, marker: String) -> String? {
        guard let range = text.range(of: "\(marker)=[0-9]+", options: .regularExpression) else { return nil }
        return String(text[range].dropFirst(marker.count + 1))
    }

    private func waitForShellPID(_ transcript: Transcript, marker: String,
                                 file: StaticString = #filePath, line: UInt = #line) async throws -> String {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if let pid = shellPID(in: transcript.text, marker: marker) { return pid }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等不到 \(marker)=<pid>：\(String(transcript.text.suffix(300)))", file: file, line: line)
        throw CancellationError()
    }

    // MARK: - 用例

    func testFirstConnectInstallsHolderAndRunsALoginShell() async throws {
        let backend = makeBackend()
        let transcript = Transcript(backend)
        await backend.resize(cols: 100, rows: 30)
        try await backend.connect()

        await backend.write(Data("echo \"S=$(stty size) T=$TERM L=$LANG\"; echo D''ONE\n".utf8))
        await transcript.wait(for: "DONE\r\n")
        XCTAssertTrue(transcript.text.contains("S=30 100 T=xterm-256color L=en_US.UTF-8"), transcript.text)

        // 装在用户目录下，会话进程不在这次登录下面。
        let installed = try await run("ls ~/.local/share/uterm/bin; ~/.local/share/uterm/bin/uterm-holder-\(HostHolder.version) list")
        XCTAssertTrue(installed.contains("uterm-holder-\(HostHolder.version)"), installed)
        XCTAssertTrue(installed.contains(backend.sessionID.uuidString), installed)
    }

    /// 连接被掐断：会话不结束，自己重连，接回同一个 shell，断开期间的输出一行不少、一行不重。
    func testTransportLossReconnectsToTheSameShellWithoutLosingOutput() async throws {
        let backend = makeBackend()
        let transcript = Transcript(backend)
        try await backend.connect()

        let reconnects = Mutex<[Bool]>([])
        Task { for await value in backend.reconnecting { reconnects.withLock { $0.append(value) } } }
        let ended = Mutex(false)
        Task { for await _ in backend.exitStream { ended.withLock { $0 = true } } }

        await backend.write(Data(
            "stty -echo; echo BEFORE=$$; for i in $(seq 1 40); do echo tick$i.; sleep 0.1; done; echo FINI''SHED\n".utf8))
        await transcript.wait(for: "tick5.")
        await backend.dropTransportForTesting()
        // 标记在命令里拆开写：回显的命令行里没有它。等到它，说明断开期间和之后的输出都接上了。
        await transcript.wait(for: "FINISHED")

        for index in 1...40 {
            XCTAssertEqual(transcript.text.components(separatedBy: "tick\(index).").count - 1, 1, "tick\(index)")
        }
        await backend.write(Data("echo AFTER=$$\n".utf8))
        let after = try await waitForShellPID(transcript, marker: "AFTER")
        XCTAssertEqual(after, try XCTUnwrap(shellPID(in: transcript.text, marker: "BEFORE")))
        XCTAssertEqual(reconnects.withLock { $0 }, [true, false])
        XCTAssertFalse(ended.withLock { $0 })
    }

    /// 看门狗判死（探活失败会强关连接）之后同样接回。连接正常时探活不打断会话。
    func testHealthProbeKeepsALiveSessionUntouched() async throws {
        let backend = makeBackend()
        let transcript = Transcript(backend)
        try await backend.connect()
        let alive = await backend.verifyConnectionAlive()
        XCTAssertTrue(alive)
        await backend.write(Data("echo STILL''HERE\n".utf8))
        await transcript.wait(for: "STILLHERE\r\n")
    }

    func testCloseEndsTheSessionOnTheHost() async throws {
        let backend = makeBackend()
        let transcript = Transcript(backend)
        try await backend.connect()
        await backend.write(Data("echo PID=$$\n".utf8))
        let pid = try await waitForShellPID(transcript, marker: "PID")

        await backend.close()

        let after = try await run(
            "kill -0 \(pid) 2>/dev/null && echo ALIVE; ~/.local/share/uterm/bin/uterm-holder-\(HostHolder.version) list; echo CHECKED")
        XCTAssertTrue(after.contains("CHECKED"), after)
        XCTAssertFalse(after.contains("ALIVE"), after)
        XCTAssertFalse(after.contains(backend.sessionID.uuidString), after)
    }

    func testShellExitEndsTheSession() async throws {
        let backend = makeBackend()
        _ = Transcript(backend)
        try await backend.connect()
        let ended = expectation(description: "exitStream")
        Task {
            for await _ in backend.exitStream { ended.fulfill() }
        }
        await backend.write(Data("exit\n".utf8))
        await fulfillment(of: [ended], timeout: 10)
        let sessions = try await run("~/.local/share/uterm/bin/uterm-holder-\(HostHolder.version) list; echo CHECKED")
        XCTAssertFalse(sessions.contains(backend.sessionID.uuidString), sessions)
    }

    /// 主机上留了「用不了」的标记：不装、不用保持进程，退回普通的 PTY 通道，照样能用。
    func testHostMarkedUnsupportedFallsBackToAPlainShell() async throws {
        _ = try await run(HostHolder.markUnsupportedCommand(reason: "test"))
        let backend = makeBackend()
        let transcript = Transcript(backend)
        try await backend.connect()
        await backend.write(Data("echo PLAIN''OK\n".utf8))
        await transcript.wait(for: "PLAINOK\r\n")
        let listing = try await run("ls ~/.local/share/uterm/bin; ls ~/.local/state/uterm/sessions 2>/dev/null; echo CHECKED")
        XCTAssertTrue(listing.contains("uterm-holder-\(HostHolder.version).unsupported"), listing)
        XCTAssertFalse(listing.contains(".sock"), listing)
    }
}
