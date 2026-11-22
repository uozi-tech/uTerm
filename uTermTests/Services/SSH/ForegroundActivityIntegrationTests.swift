import SwiftData
import XCTest
@testable import uTerm

/// 集成测试 —— 对真实 sshd 探测前台。设置端口才跑，否则 SKIP：
/// `TEST_RUNNER_UTERM_TEST_FOREGROUND_SSH_PORT=2299 xcodebuild test-without-building …`
/// 用户名密码默认 tester / tester。
final class ForegroundActivityIntegrationTests: XCTestCase {

    private func environment(_ name: String) -> String? { ProcessInfo.processInfo.environment[name] }

    private func connect(port: Int) async throws -> SSHConnection {
        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        let user = environment("UTERM_TEST_FOREGROUND_SSH_USER") ?? "tester"
        let connection = SSHConnection(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port, jumpHost: nil),
            auth: .password(username: user, password: environment("UTERM_TEST_FOREGROUND_SSH_PASSWORD") ?? "tester"),
            jumpHostAuth: nil,
            hostKeyVerifier: verifier,
            hostKeyApprover: { _ in true })
        try await connection.connect()
        return connection
    }

    /// 同一条连接上的多个 shell 各答各的：这是共用连接下最容易答错的地方。
    func testEachShellOnASharedConnectionAnswersForItself() async throws {
        let port = try self.port(named: "UTERM_TEST_FOREGROUND_SSH_PORT")
        let idle = try await connect(port: port)
        let busy = try await connect(port: port)
        let alsoIdle = try await connect(port: port)
        try await Task.sleep(for: .seconds(1))

        // 只有一个标签在跑；另外两个要答空闲，不能被它带偏。
        await busy.write(Data("sleep 30\n".utf8))
        try await Task.sleep(for: .milliseconds(500))

        let started = ContinuousClock.now
        let first = await idle.foregroundActivity(timeout: .seconds(5))
        print("foreground-probe first=\(ContinuousClock.now - started)")
        XCTAssertEqual(first, .idle)
        let cachedStart = ContinuousClock.now
        let running = await busy.foregroundActivity(timeout: .seconds(5))
        print("foreground-probe busy=\(ContinuousClock.now - cachedStart)")
        XCTAssertEqual(running, .running("sleep"))
        let third = await alsoIdle.foregroundActivity(timeout: .seconds(5))
        XCTAssertEqual(third, .idle)

        // 程序退出后回到空闲（pty 已缓存）。
        await busy.write(Data([0x03]))
        try await Task.sleep(for: .milliseconds(500))
        let finished = await busy.foregroundActivity(timeout: .seconds(5))
        XCTAssertEqual(finished, .idle)

        // 只剩一个 shell 时不需要认 pty。
        await alsoIdle.close()
        await idle.close()
        await busy.write(Data("sleep 30\n".utf8))
        try await Task.sleep(for: .milliseconds(500))
        let alone = await busy.foregroundActivity(timeout: .seconds(5))
        XCTAssertEqual(alone, .running("sleep"))
        await busy.close()
    }

    /// ⌘ 点相对路径时的解析依据：前台进程（不是 shell）的当前目录，以及家目录。同一条连接上有几个 shell 时各答各的。
    func testForegroundDirectoriesFollowTheForegroundProcess() async throws {
        let port = try self.port(named: "UTERM_TEST_FOREGROUND_SSH_PORT")
        let idle = try await connect(port: port)
        let busy = try await connect(port: port)
        try await Task.sleep(for: .seconds(1))
        await idle.write(Data("cd /var\n".utf8))
        // 子 shell 里换目录再跑：前台进程的目录是 /tmp，shell 自己还在家目录。
        await busy.write(Data("(cd /tmp && exec sleep 30)\n".utf8))
        try await Task.sleep(for: .milliseconds(700))

        let running = await busy.foregroundDirectories()
        XCTAssertEqual(running?.workingDirectory, "/tmp")
        XCTAssertNotNil(running?.home)
        XCTAssertEqual(running.flatMap { TerminalLinkPath.resolve("~/a.md", workingDirectory: nil, home: $0.home) },
                       running?.home.map { $0 + "/a.md" })
        let atPrompt = await idle.foregroundDirectories()
        XCTAssertEqual(atPrompt?.workingDirectory, "/var", "停在提示符上就是 shell 的目录")

        await busy.write(Data([0x03]))
        await idle.close()
        await busy.close()
    }

    /// 探测不能往用户的屏幕上写东西。
    func testProbeLeavesNoVisibleOutput() async throws {
        let port = try self.port(named: "UTERM_TEST_FOREGROUND_SSH_PORT")
        let first = try await connect(port: port)
        let second = try await connect(port: port)
        let collected = Task { () -> Data in
            var all = Data()
            for await case .bytes(let chunk) in second.outputItems { all.append(chunk) }
            return all
        }
        try await Task.sleep(for: .seconds(1))
        _ = await first.foregroundActivity(timeout: .seconds(5))
        _ = await second.foregroundActivity(timeout: .seconds(5))
        await first.close()
        await second.close()
        let text = String(decoding: await collected.value, as: UTF8.self)
        XCTAssertFalse(text.contains("uterm-ps"), text)
        XCTAssertFalse(text.contains("ps -A"), text)
    }

    /// 没有可用 `ps` 的主机（alpine 自带 busybox）答不上来，不能误报空闲。
    func testHostWithoutUsablePSIsUnknown() async throws {
        let port = try self.port(named: "UTERM_TEST_FOREGROUND_BUSYBOX_SSH_PORT")
        let connection = try await connect(port: port)
        try await Task.sleep(for: .seconds(1))
        let activity = await connection.foregroundActivity(timeout: .seconds(5))
        XCTAssertEqual(activity, .unknown)
        await connection.close()
    }

    private func port(named name: String) throws -> Int {
        guard let value = environment(name), let port = Int(value) else {
            throw XCTSkip("设置 \(name) 后运行此集成测试")
        }
        return port
    }
}

/// 本机 shell 走内核接口，不依赖 ps。起真 shell。
@MainActor
final class LocalShellForegroundActivityTests: XCTestCase {
    func testReportsForegroundProgramThroughThePTY() async throws {
        let pane = LocalShellPane()
        await pane.start()
        let backend = try XCTUnwrap(pane.session.backend)
        try await Task.sleep(for: .seconds(1))
        let atPrompt = await pane.session.foregroundActivity()
        XCTAssertEqual(atPrompt, .idle)

        await backend.write(Data("sleep 30\n".utf8))
        try await Task.sleep(for: .milliseconds(500))
        let running = await pane.session.foregroundActivity()
        print("local-foreground running=\(running)")
        guard case .running = running else { return XCTFail("应当报告在跑，实际 \(running)") }

        await backend.write(Data([0x03]))
        try await Task.sleep(for: .milliseconds(500))
        let back = await pane.session.foregroundActivity()
        XCTAssertEqual(back, .idle)
        pane.dispose()
    }
}
