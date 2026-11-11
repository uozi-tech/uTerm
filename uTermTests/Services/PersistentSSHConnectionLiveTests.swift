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

    private func makeBackend(sessionID: UUID = UUID(), resumesSession: Bool = false) -> PersistentSSHConnection {
        let backend = PersistentSSHConnection(
            sessionID: sessionID, resumesSession: resumesSession, profile: profile, auth: auth, jumpHostAuth: nil,
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
                    switch item {
                    case .bytes(let data), .history(let data): self.collected.withLock { $0.append(data) }
                    case .snapshot, .afterFed: break
                    }
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

    // MARK: - App 重新打开后接回

    /// 一个「终端」：影子终端 + 输出泵吃后端的输出，检查点从它身上拍（和 iOS 的 `MobileTerminalController` 同一个接法）。
    private final class DataLog: Sendable {
        private let collected = Mutex<[Data]>([])
        var values: [Data] { collected.withLock { $0 } }
        var isEmpty: Bool { values.isEmpty }
        func append(_ data: Data) { collected.withLock { $0.append(data) } }
    }

    private final class Terminal: Sendable {
        let phone: MirrorPhone
        let restoredStatus = DataLog()

        init(_ backend: PersistentSSHConnection, cols: Int = 80, rows: Int = 24) {
            let phone = MirrorPhone(cols: cols, rows: rows, scrollbackLines: 5000)
            self.phone = phone
            let restoredStatus = restoredStatus
            backend.setCheckpointHooks(TerminalCheckpointHooks(
                capture: { phone.pump.makeCheckpoint(scrollbackLines: 2000, programStatus: Data("status-v1".utf8)) },
                restoreProgramStatus: { status in restoredStatus.append(status) }))
            phone.start(backend.outputItems)
        }

        var text: String { phone.shadow.viewportText() }

        func wait(for needle: String, timeout: Duration = .seconds(20),
                  file: StaticString = #filePath, line: UInt = #line) async {
            let deadline = ContinuousClock.now + timeout
            while !text.contains(needle) {
                guard ContinuousClock.now < deadline else {
                    XCTFail("屏幕上等不到「\(needle)」：\(text)", file: file, line: line)
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    /// 主机上还有没有这个会话。
    private func sessionIsOnHost(_ sessionID: UUID) async throws -> Bool {
        let listing = try await run("~/.local/share/uterm/bin/uterm-holder-\(HostHolder.version) list; echo CHECKED")
        return listing.contains(sessionID.uuidString)
    }

    /// App 被系统结束（后端直接丢下，没告诉主机）之后用同一个会话 id 再连：画面从存在主机上的检查点回来，
    /// 检查点之后、App 不在期间的输出按历史补上，shell 还是原来那个。
    func testReopeningWithTheSameSessionRestoresTheScreenFromTheCheckpoint() async throws {
        let sessionID = UUID()
        let first = makeBackend(sessionID: sessionID)
        let firstTerminal = Terminal(first)
        try await first.connect()
        await first.write(Data("stty -echo; clear; echo PID=$$; echo first-run-line\n".utf8))
        await firstTerminal.wait(for: "first-run-line")
        let pid = try XCTUnwrap(shellPID(in: firstTerminal.text, marker: "PID"))

        // 进后台：存一张检查点。
        await first.saveCheckpoint()
        // 检查点之后、App 被结束之前又来了一些输出；被结束之后主机上接着跑。里面夹一个查询（历史里的不该再答）。
        await first.write(Data("echo after-checkpoint; (sleep 1; printf '\\033[c'; echo while-away) &\n".utf8))
        await firstTerminal.wait(for: "after-checkpoint")
        await first.abandonForTesting()
        let alive = try await sessionIsOnHost(sessionID)
        XCTAssertTrue(alive, "App 没了，会话应当留在主机上")
        try await Task.sleep(for: .milliseconds(1500))

        // App 重新打开：新的后端、空的终端，同一个会话 id。
        let second = makeBackend(sessionID: sessionID, resumesSession: true)
        let secondTerminal = Terminal(second)
        let replies = DataLog()
        secondTerminal.phone.shadow.setReplyHandler { reply in replies.append(reply) }
        try await second.connect()

        await secondTerminal.wait(for: "while-away")
        let screen = secondTerminal.text
        XCTAssertTrue(screen.contains("first-run-line"), "检查点里的内容：\(screen)")
        XCTAssertTrue(screen.contains("after-checkpoint"), "检查点之后的输出：\(screen)")
        XCTAssertEqual(secondTerminal.phone.snapshots, 1, "画面从检查点还原，不是从头重放")
        XCTAssertEqual(secondTerminal.restoredStatus.values, [Data("status-v1".utf8)])
        XCTAssertTrue(replies.isEmpty, "App 不在期间的查询不该再答")

        await second.write(Data("echo AGAIN=$$\n".utf8))
        await secondTerminal.wait(for: "AGAIN=\(pid)")
        // 接回之后是实时输出：查询照答。
        await second.write(Data("printf '\\033[c'; echo asked\n".utf8))
        await secondTerminal.wait(for: "asked")
        let deadline = ContinuousClock.now + .seconds(5)
        while replies.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(replies.isEmpty, "接回之后的查询要答")
    }

    /// 没存过检查点（App 还没进过后台就没了）：主机上留着的输出整段按历史补上，画面照样回来。
    func testReopeningWithoutACheckpointReplaysWhatTheHostKept() async throws {
        let sessionID = UUID()
        let first = makeBackend(sessionID: sessionID)
        let firstTerminal = Terminal(first)
        try await first.connect()
        await first.write(Data("stty -echo; clear; echo never-checkpointed\n".utf8))
        await firstTerminal.wait(for: "never-checkpointed")
        await first.abandonForTesting()

        let second = makeBackend(sessionID: sessionID, resumesSession: true)
        let secondTerminal = Terminal(second)
        try await second.connect()
        await secondTerminal.wait(for: "never-checkpointed")
        XCTAssertEqual(secondTerminal.phone.snapshots, 0)
    }

    /// 恢复的标签没连上就被关掉：主机上的会话也要结束，不留到 24 小时后。
    func testClosingAResumedSessionThatNeverAttachedStillEndsItOnTheHost() async throws {
        let sessionID = UUID()
        let first = makeBackend(sessionID: sessionID)
        let terminal = Terminal(first)
        try await first.connect()
        await first.write(Data("echo up\n".utf8))
        await terminal.wait(for: "up")
        await first.abandonForTesting()

        let second = makeBackend(sessionID: sessionID, resumesSession: true)
        await second.close()

        let deadline = ContinuousClock.now + .seconds(20)
        var listing = ""
        repeat {
            listing = try await run("~/.local/share/uterm/bin/uterm-holder-\(HostHolder.version) list; echo CHECKED")
            if !listing.contains(sessionID.uuidString) { break }
            try await Task.sleep(for: .milliseconds(200))
        } while ContinuousClock.now < deadline
        XCTAssertFalse(listing.contains(sessionID.uuidString), listing)
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
