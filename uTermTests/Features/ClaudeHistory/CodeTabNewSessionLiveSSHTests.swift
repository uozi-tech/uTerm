import Foundation
import SwiftData
import XCTest
@testable import uTerm

/// Code 标签页新会话的「输入路径」对着**真 sshd**：经真的 SFTP 问到主目录、`~` 照它展开、核对存在 / 不存在 /
/// 是文件 / 指向目录的符号链接；再把起始页「开始」生成的那条命令（真的 Claude Code 数据源拼的）放进真的登录 shell
/// 里跑，看它落在选的目录里（目录名带空格、单引号、中文）。
///
/// 需要外部 sshd，**默认跳过**。跑法同 `ClaudeHistoryLiveSSHTests`（同一个镜像、同一组开关）：
///
/// ```
/// docker run -d --rm --name uterm-code-new-session-live -p 127.0.0.1:2297:22 uterm-holder-e2e-sshd
/// TEST_RUNNER_UTERM_LIVE_SSH_PORT=2297 TEST_RUNNER_UTERM_LIVE_SSH_USER=dev TEST_RUNNER_UTERM_LIVE_SSH_PASSWORD=dev \
///   xcodebuild test … -only-testing:uTermTests/CodeTabNewSessionLiveSSHTests
/// ```
///
/// 只动自己建的东西：主目录下一个带随机后缀的目录，结束时删掉。主机上不用装 Claude Code：`claude` 是放进 `PATH`
/// 最前面的假脚本，只把所在目录记下来。
@MainActor
final class CodeTabNewSessionLiveSSHTests: XCTestCase {
    private var profile: SSHConnection.ProfileSnapshot!
    private var auth: ResolvedAuth!
    private var container: ModelContainer!
    private var files: SFTPSession!
    private var home = ""
    private var scratch = ""
    /// 主目录下的相对写法（`~/…` 用）。
    private var scratchName = ""
    private var project = ""

    private final class FakeTerminal: CodeTabTerminal {
        let id = UUID()
        let directory: String
        private(set) var command: String?
        var codeCommandHasEnded = false
        init(directory: String) { self.directory = directory }
        func runCodeCommand(_ command: String) { self.command = command }
        func dispose() {}
    }

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
        let connected = try await SSHClientFactory.connectShared(
            profile: profile, auth: auth, jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: { _ in true })
        files = try await SFTPSession(connected: connected)
        home = try await files.realPath(".")
        scratchName = "uterm-code-new-session-e2e-" + UUID().uuidString.prefix(8).lowercased()
        scratch = home + "/" + scratchName
        project = scratch + "/it's a 新项目"
        _ = try await files.exec("mkdir -p \(Self.quoted(project)) \(Self.quoted(scratch + "/bin"))"
                                 + " && : > \(Self.quoted(scratch + "/plain.txt"))"
                                 + " && ln -s \(Self.quoted(project)) \(Self.quoted(scratch + "/link"))"
                                 + " && ln -s \(Self.quoted(scratch + "/gone")) \(Self.quoted(scratch + "/dangling"))")
    }

    override func tearDown() async throws {
        if let files {
            if !scratch.isEmpty { _ = try? await files.exec("rm -rf \(Self.quoted(scratch))") }
            await files.close()
        }
        files = nil
        try await super.tearDown()
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("等「\(what)」超时", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 和 SSH 终端窗口里的 Code 标签页同一条路：连接经文件通道建好、问主目录、列记录（真的 Claude Code 数据源）。
    /// 通道交给它之后由 `tearDown` 关，这里不调 `close()`。
    private func openConnection() async -> AgentHistoryConnection {
        let files = files!
        let connection = AgentHistoryConnection(preferredDirectory: nil, followsCurrentProject: false) { _ in files }
        await connection.open()
        await waitUntil("问到主目录") { connection.homeDirectory != nil }
        await waitUntil("列表") { connection.history.map { !$0.isListing } ?? false }
        return connection
    }

    // MARK: - 输入路径

    func testTypedPathsAreExpandedAndCheckedOnTheHost() async throws {
        let connection = await openConnection()
        XCTAssertEqual(connection.homeDirectory, ClaudeProjectPath.normalized(home), "主目录是 SFTP 的登录目录")

        func submit(_ text: String) async -> (String?, AgentHistoryDirectoryInput.Problem?) {
            let entry = AgentHistoryPathEntry(text: text)
            let path = await entry.submit(using: connection)
            return (path, entry.problem)
        }

        var result = await submit("~/\(scratchName)/it's a 新项目")
        XCTAssertEqual(result.0, project, "~ 照主机上的主目录展开，带空格、单引号、中文的目录过")
        XCTAssertNil(result.1)

        result = await submit("  \(project)/  ")
        XCTAssertEqual(result.0, project, "前后空格、末尾的 / 去掉")

        result = await submit("~")
        XCTAssertEqual(result.0, ClaudeProjectPath.normalized(home))

        result = await submit("~/\(scratchName)/link")
        XCTAssertEqual(result.0, scratch + "/link", "指向目录的符号链接算目录（路径照输入的留着）")

        result = await submit("~/\(scratchName)/nope")
        XCTAssertNil(result.0)
        XCTAssertEqual(result.1, .missing(scratch + "/nope"))

        result = await submit("~/\(scratchName)/dangling")
        XCTAssertEqual(result.1, .missing(scratch + "/dangling"), "断了的链接当不存在")

        result = await submit("~/\(scratchName)/plain.txt")
        XCTAssertEqual(result.1, .notDirectory(scratch + "/plain.txt"))

        result = await submit("\(scratchName)/it's a 新项目")
        XCTAssertEqual(result.1, .notAbsolute, "相对路径不认")

        result = await submit("~root")
        XCTAssertEqual(result.1, .notAbsolute, "~别人 不认")
    }

    // MARK: - 选好之后开始

    /// 起始页上输入路径、点「开始」：命令由真的 Claude Code 数据源拼，放进真的登录 shell 里跑，落在选的目录里。
    func testStartRunsInTheTypedDirectoryInARealShell() async throws {
        let connection = await openConnection()
        var made: [FakeTerminal] = []
        let code = CodeTabModel(hostName: "e2e", directory: home, directoryChooser: .typedPath) { directory in
            let terminal = FakeTerminal(directory: directory)
            made.append(terminal)
            return terminal
        }
        code.install(connection)
        XCTAssertTrue(code.newSessionDirectoryChoices.contains(ClaudeProjectPath.normalized(home) ?? home),
                      "候选里有主目录")

        let entry = AgentHistoryPathEntry(text: "~/\(scratchName)/it's a 新项目")
        let submitted = await entry.submit(using: connection)
        let chosen = try XCTUnwrap(submitted, "核对没过：\(String(describing: entry.problem))")
        code.chooseNewSessionDirectory(chosen)   // 同输入路径面板的「选择」
        XCTAssertEqual(code.newSessionDirectoryChoices.first, project, "选的目录排在候选第一个")
        XCTAssertNotNil(code.startNewSession(tool: .claude, in: try XCTUnwrap(code.newSessionDirectory)))
        let command = try XCTUnwrap(made.last?.command)
        XCTAssertEqual(made.last?.directory, project, "终端开在选的目录")

        // 假的 `claude`：把所在目录记下来。
        let record = scratch + "/bin/record.txt"
        try await files.write(scratch + "/bin/claude", data: Data("""
            #!/bin/sh
            pwd > \(Self.quoted(record))

            """.utf8))
        try await files.setPermissions(path: scratch + "/bin/claude", mode: 0o755)

        let ssh = SSHConnection(profile: profile, auth: auth, jumpHostAuth: nil,
                                hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: { _ in true })
        let session = TerminalSession()
        await session.connect(using: ssh)
        XCTAssertEqual(session.connectionState, .connected)
        session.sendHostBytes(Data("PATH=\(Self.quoted(scratch + "/bin")):$PATH\n".utf8))
        // 和窗口里一样不包子 shell。
        let run = session.startTrackedRun(command, inSubshell: false)
        await waitUntil("命令跑完") {
            if case .finished = session.trackedRun?.phase { return true }
            return false
        }
        XCTAssertEqual(session.trackedRun?.id, run.id)
        XCTAssertEqual(session.trackedRun?.phase, .finished(0),
                       "命令：\(command)\n屏幕：\n\(session.snapshotScreen(lines: 40, maxBytes: 8192).lines.joined(separator: "\n"))")
        let recorded = String(decoding: try await files.download(remotePath: record), as: UTF8.self)
        XCTAssertEqual(recorded.trimmingCharacters(in: .newlines), project)

        await ssh.close()
        session.dispose()
    }
}
