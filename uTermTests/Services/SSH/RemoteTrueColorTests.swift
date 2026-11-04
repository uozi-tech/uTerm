import Foundation
import SwiftData
import XCTest
@testable import uTerm
@testable import USSHKit

/// 远端脚本用真 shell 跑，而不是比对字符串：引号嵌套错了字符串看不出来。
final class RemoteTrueColorTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uterm-truecolor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// 像 sshd 那样，用登录 shell 的 `-c` 跑命令。
    @discardableResult
    private func run(_ shell: String, _ command: String, env: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "SHELL": shell].merging(env) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)
    }

    private func touch(_ name: String) throws {
        try Data().write(to: home.appendingPathComponent(name))
    }

    // MARK: 解析

    func testColorTermAlreadyVisible() {
        XCTAssertEqual(RemoteTrueColor.parseProbe("truecolor\nuTerm\n/h/.zshenv\nno\n"), .active)
        XCTAssertEqual(RemoteTrueColor.parseProbe("24bit\n\n/h/.zshenv\nno\n"), .active)
    }

    func testCanEnableWhenTerminalNamePasses() {
        XCTAssertEqual(RemoteTrueColor.parseProbe("\nuTerm\n/h/.zshenv\nno\n"), .canEnable(rcFile: "/h/.zshenv"))
    }

    func testUnsupportedWhenServerDropsTerminalName() {
        XCTAssertEqual(RemoteTrueColor.parseProbe("\n\n/h/.zshenv\nno\n"), .unsupported)
        XCTAssertEqual(RemoteTrueColor.parseProbe(""), .unsupported)
    }

    func testEnabledFileMustBeAPath() {
        XCTAssertEqual(RemoteTrueColor.parseEnabledFile("rc noise\n/h/.zshenv\n"), "/h/.zshenv")
        XCTAssertNil(RemoteTrueColor.parseEnabledFile("sh: not found\n"))
        XCTAssertNil(RemoteTrueColor.parseEnabledFile(""))
    }

    // MARK: 真 shell

    func testProbeReportsEnvironment() throws {
        let output = try run("/bin/zsh", RemoteTrueColor.probeCommand, env: ["LC_TERMINAL": "uTerm"])
        XCTAssertEqual(RemoteTrueColor.parseProbe(output),
                       .canEnable(rcFile: home.appendingPathComponent(".zshenv").path))
    }

    /// 真 sshd 上发现的：exec 的 `bash -c` 不读 `.profile`，写过之后环境变量里依然没有，
    /// 只看环境变量的话提示会一直弹。
    func testProbeTreatsWrittenLineAsActiveEvenIfShellDoesNotReadIt() throws {
        try touch(".profile")
        try run("/bin/bash", RemoteTrueColor.enableCommand)

        let output = try run("/bin/bash", RemoteTrueColor.probeCommand, env: ["LC_TERMINAL": "uTerm"])

        XCTAssertEqual(RemoteTrueColor.parseProbe(output), .active)
    }

    func testZshLinePassesEnvironmentOnlyFromUTerm() throws {
        let file = RemoteTrueColor.parseEnabledFile(try run("/bin/zsh", RemoteTrueColor.enableCommand))
        XCTAssertEqual(file, home.appendingPathComponent(".zshenv").path)

        let fromUTerm = try run("/bin/zsh", "printf %s \"$COLORTERM\"", env: ["LC_TERMINAL": "uTerm"])
        XCTAssertEqual(fromUTerm, "truecolor")
        let fromOther = try run("/bin/zsh", "printf %s \"$COLORTERM\"", env: ["LC_TERMINAL": "iTerm2"])
        XCTAssertEqual(fromOther, "")
    }

    /// 条件不成立时不能留下非零退出码，否则第一个提示符会显示「上一条失败」。
    func testLineLeavesZeroExitStatusForOtherTerminals() throws {
        try run("/bin/zsh", RemoteTrueColor.enableCommand)
        XCTAssertEqual(try run("/bin/zsh", "printf %s \"$?\""), "0")
    }

    func testEnableIsIdempotent() throws {
        try run("/bin/zsh", RemoteTrueColor.enableCommand)
        try run("/bin/zsh", RemoteTrueColor.enableCommand)
        let lines = try read(".zshenv").components(separatedBy: "\n").filter { $0.contains("uTerm truecolor") }
        XCTAssertEqual(lines.count, 1)
    }

    func testEnableKeepsExistingContent() throws {
        try Data("export FOO=1".utf8).write(to: home.appendingPathComponent(".zshenv"))
        try run("/bin/zsh", RemoteTrueColor.enableCommand)
        let content = try read(".zshenv")
        XCTAssertTrue(content.hasPrefix("export FOO=1\n"), "原文件没有末尾换行时也不能粘到同一行")
        XCTAssertTrue(content.contains("uTerm truecolor"))
    }

    /// bash 登录 shell 只读第一个存在的文件，写到别的文件不生效。
    func testBashWritesFirstExistingLoginFile() throws {
        try touch(".profile")
        XCTAssertEqual(RemoteTrueColor.parseEnabledFile(try run("/bin/bash", RemoteTrueColor.enableCommand)),
                       home.appendingPathComponent(".profile").path)

        try touch(".bash_profile")
        try FileManager.default.removeItem(at: home.appendingPathComponent(".profile"))
        XCTAssertEqual(RemoteTrueColor.parseEnabledFile(try run("/bin/bash", RemoteTrueColor.enableCommand)),
                       home.appendingPathComponent(".bash_profile").path)
    }

    func testBashLoginShellPicksUpLine() throws {
        try run("/bin/bash", RemoteTrueColor.enableCommand)
        let output = try run("/bin/bash", "bash -lc 'printf %s \"$COLORTERM\"'", env: ["LC_TERMINAL": "uTerm"])
        XCTAssertEqual(output, "truecolor")
    }

    /// fish 没装时用 `sh` 验证脚本选文件的分支，语法由 rcLine 的字面量测试兜底。
    func testFishWritesFishSyntaxToConfD() throws {
        let output = try run("/bin/sh", RemoteTrueColor.enableCommand, env: ["SHELL": "/usr/bin/fish"])
        XCTAssertEqual(RemoteTrueColor.parseEnabledFile(output),
                       home.appendingPathComponent(".config/fish/conf.d/uterm.fish").path)
        let content = try read(".config/fish/conf.d/uterm.fish")
        XCTAssertTrue(content.contains("if test \"$LC_TERMINAL\" = uTerm; set -gx COLORTERM truecolor; end"))
    }

    /// 脚本要经 fish 这样的登录 shell 转交给 `sh -c`，里面不能有单引号。
    func testCommandsHaveNoNestedSingleQuotes() {
        for command in [RemoteTrueColor.probeCommand, RemoteTrueColor.enableCommand] {
            XCTAssertEqual(command.filter { $0 == "'" }.count, 2)
        }
    }

    // MARK: 会话

    private actor ColorBackend: TerminalBackend, TerminalTrueColorConfiguring {
        nonisolated let outputStream = AsyncStream<Data> { _ in }
        nonisolated let exitStream = AsyncStream<Void> { _ in }
        nonisolated let trueColorHostKey: String
        let status: RemoteTrueColor.Status
        private(set) var probes = 0
        private(set) var enables = 0
        init(status: RemoteTrueColor.Status, hostKey: String = "host-\(UUID().uuidString):22") {
            self.status = status
            trueColorHostKey = hostKey
        }
        func connect() async throws {}
        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async {}
        func trueColorStatus() async throws -> RemoteTrueColor.Status {
            probes += 1
            return status
        }
        func enableTrueColor() async throws -> String {
            enables += 1
            return "/h/.zshenv"
        }
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待超时")
    }

    @MainActor
    private func agentReports(_ session: TerminalSession) {
        session.applyProgramStatus(.report(id: "", record: ProgramStatusRecord(state: .idle)), isLooking: false)
    }

    @MainActor
    func testOfferAppearsOnlyAfterAgentReports() async throws {
        let session = TerminalSession()
        let backend = ColorBackend(status: .canEnable(rcFile: "/h/.zshenv"))
        await session.connect(using: backend)
        try await Task.sleep(for: .milliseconds(50))
        let before = await backend.probes
        XCTAssertEqual(before, 0, "普通 shell 不打扰")

        agentReports(session)
        agentReports(session)

        try await waitUntil { session.trueColorOffer == .available(rcFile: "/h/.zshenv") }
        let after = await backend.probes
        XCTAssertEqual(after, 1, "一条连接只查一次")
    }

    @MainActor
    func testNoOfferWhenAlreadyActiveOrUnsupported() async throws {
        for status in [RemoteTrueColor.Status.active, .unsupported] {
            let session = TerminalSession()
            let backend = ColorBackend(status: status)
            await session.connect(using: backend)
            agentReports(session)
            try await waitUntil { await backend.probes == 1 }
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertNil(session.trueColorOffer)
        }
    }

    @MainActor
    func testEnableWritesOnlyAfterExplicitCall() async throws {
        let session = TerminalSession()
        let backend = ColorBackend(status: .canEnable(rcFile: "/h/.zshenv"))
        await session.connect(using: backend)
        agentReports(session)
        try await waitUntil { session.trueColorOffer != nil }
        let beforeConfirm = await backend.enables
        XCTAssertEqual(beforeConfirm, 0)

        session.enableTrueColor()

        try await waitUntil { session.trueColorOffer == .enabled(rcFile: "/h/.zshenv") }
    }

    @MainActor
    func testDismissIsRememberedPerHost() async throws {
        let host = "dismiss-\(UUID().uuidString):22"
        defer { UserDefaults.standard.removeObject(forKey: "trueColorOfferDismissedHosts") }
        let first = TerminalSession()
        let firstBackend = ColorBackend(status: .canEnable(rcFile: "/h/.zshenv"), hostKey: host)
        await first.connect(using: firstBackend)
        agentReports(first)
        try await waitUntil { first.trueColorOffer != nil }
        first.dismissTrueColorOfferForHost()
        XCTAssertNil(first.trueColorOffer)

        let second = TerminalSession()
        let secondBackend = ColorBackend(status: .canEnable(rcFile: "/h/.zshenv"), hostKey: host)
        await second.connect(using: secondBackend)
        agentReports(second)
        try await Task.sleep(for: .milliseconds(50))
        let probes = await secondBackend.probes
        XCTAssertEqual(probes, 0)
    }

    @MainActor
    func testDisconnectClearsOfferAndAllowsRecheck() async throws {
        let session = TerminalSession()
        await session.connect(using: ColorBackend(status: .canEnable(rcFile: "/h/.zshenv")))
        agentReports(session)
        try await waitUntil { session.trueColorOffer != nil }
        session.markFailed("断了")
        XCTAssertNil(session.trueColorOffer)
        XCTAssertFalse(session.trueColorChecked)
    }

    // MARK: 真 sshd

    /// 设 `UTERM_TRUECOLOR_SSH_PORT` 后对 Docker 里的 sshd 跑（要求 `AcceptEnv LANG LC_*`，
    /// 用户名 / 密码取 `UTERM_TRUECOLOR_SSH_USER` / `UTERM_TRUECOLOR_SSH_PASSWORD`）。
    @MainActor
    func testRealServerEnablesTrueColorForNewShells() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_TRUECOLOR_SSH_PORT"], let port = Int(raw) else {
            throw XCTSkip("没设 UTERM_TRUECOLOR_SSH_PORT")
        }
        let user = env["UTERM_TRUECOLOR_SSH_USER"] ?? "dev"
        let password = env["UTERM_TRUECOLOR_SSH_PASSWORD"] ?? "x"
        let first = try await openConnection(port: port, user: user, password: password)
        let status = try await first.trueColorStatus()
        guard case .canEnable(let rcFile) = status else { return XCTFail("应当可启用：\(status)") }
        let enabledFile = try await first.enableTrueColor()
        XCTAssertEqual(enabledFile, rcFile)
        await first.close()

        let second = try await openConnection(port: port, user: user, password: password)
        let collected = Task { () -> String in
            var output = Data()
            for await chunk in second.outputStream {
                output.append(chunk)
                if String(decoding: output, as: UTF8.self).contains("CT=truecolor") { break }
            }
            return String(decoding: output, as: UTF8.self)
        }
        await second.write(Data("echo CT=$COLORTERM\n".utf8))
        let output = try await withTimeout(seconds: 10) { await collected.value }
        XCTAssertTrue(output.contains("CT=truecolor"), output)
        let afterStatus = try await second.trueColorStatus()
        XCTAssertEqual(afterStatus, .active)
        await second.close()
    }

    @MainActor
    private func openConnection(port: Int, user: String, password: String) async throws -> SSHConnection {
        let profile = ServerProfile()
        profile.host = "127.0.0.1"
        profile.port = port
        profile.username = user
        profile.authMethod = .password
        let container = try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let connection = SSHConnection(
            profile: SSHConnection.ProfileSnapshot(profile),
            auth: .password(username: user, password: password),
            jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container),
            hostKeyApprover: { _ in true })
        try await connection.connect()
        return connection
    }
}
