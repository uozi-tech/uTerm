import Foundation
import SwiftData
import XCTest
@testable import uTerm

/// Codex 的历史会话对着**真 sshd** 端到端跑：假记录（明文与压缩的）写到主机的 `~/.codex/sessions` 下，经真的 SFTP 与
/// `exec` 列出来、读信息、翻对话、搜索；再在真的登录 shell 里执行「继续这个会话」那条命令。
///
/// 需要外部 sshd，所以**默认跳过**，开关同 `ClaudeHistoryLiveSSHTests`：
///
/// ```
/// docker run -d --name uterm-codex-history-live -p 127.0.0.1:2298:22 uterm-holder-e2e-sshd
/// TEST_RUNNER_UTERM_LIVE_SSH_PORT=2298 TEST_RUNNER_UTERM_LIVE_SSH_USER=dev TEST_RUNNER_UTERM_LIVE_SSH_PASSWORD=dev \
///   xcodebuild test-without-building … -only-testing:uTermTests/CodexHistoryLiveSSHTests
/// ```
///
/// 记录内容全是编的。只动自己建的：`~/.codex/sessions/2099/12/<随机两位>/` 一个日期目录和主目录下一个带随机后缀的
/// 工作目录，结束时只删这两处。主机上不需要装 Codex：`codex` 是放进 `PATH` 最前面的假脚本，只把目录和参数记下来。
@MainActor
final class CodexHistoryLiveSSHTests: XCTestCase {
    private typealias F = CodexFixture
    private var profile: SSHConnection.ProfileSnapshot!
    private var auth: ResolvedAuth!
    private var container: ModelContainer!
    private var files: SFTPSession!
    private var home = ""
    private var workdir = ""
    private var scratch = ""
    private var dayDirectory = ""
    private let compressedID = CodexZstdFixture.threadID
    private let plainID = "019a0000-eeee-7eee-8eee-000000000001"
    private let desktopID = "019a0000-eeee-7eee-8eee-000000000002"

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_LIVE_SSH_PORT"], let port = Int(raw) else {
            throw XCTSkip("没设 UTERM_LIVE_SSH_PORT，跳过真 sshd 集成测试")
        }
        profile = SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port, jumpHost: nil)
        auth = .password(username: env["UTERM_LIVE_SSH_USER"] ?? "root", password: env["UTERM_LIVE_SSH_PASSWORD"] ?? "PASS")
        container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let connected = try await SSHClientFactory.connectShared(
            profile: profile, auth: auth, jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: { _ in true })
        files = try await SFTPSession(connected: connected)
        home = try await files.realPath(".")
        let suffix = UUID().uuidString.prefix(8).lowercased()
        scratch = home + "/uterm-codex-history-e2e-" + suffix
        workdir = scratch + "/it's a 项目"
        dayDirectory = home + "/.codex/sessions/2099/12/" + String(format: "%02d", Int.random(in: 10...99))
        _ = try await files.exec("mkdir -p \(Self.quoted(workdir)) \(Self.quoted(scratch + "/bin")) \(Self.quoted(dayDirectory))")
        try await seed()
    }

    override func tearDown() async throws {
        if let files {
            if !scratch.isEmpty { _ = try? await files.exec("rm -rf \(Self.quoted(scratch)) \(Self.quoted(dayDirectory))") }
            await files.close()
        }
        files = nil
        try await super.tearDown()
    }

    private static func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func recordPath(_ id: String, compressed: Bool = false) -> String {
        dayDirectory + "/rollout-2099-12-01T10-00-00-\(id).jsonl" + (compressed ? ".zst" : "")
    }

    private func seed() async throws {
        // 命令行起的大会话：几百轮，翻完要好几页。
        var lines = [F.meta(id: plainID, cwd: workdir), F.developer("x"), F.injected]
        let padding = String(repeating: "填充文字。", count: 400)
        for turn in 0..<300 {
            lines.append(F.user("问题 \(turn)", ordinal: turn * 3 + 1))
            lines.append(F.functionCall("exec_command", arguments: ["cmd": "echo \(turn)"], callID: "c\(turn)"))
            lines.append(F.functionOutput(callID: "c\(turn)", output: "结果 \(turn)"))
            lines.append(F.assistant("回答 \(turn) needleword\n\n" + padding, ordinal: turn * 3 + 2))
        }
        try await files.write(recordPath(plainID), data: F.file(lines))
        try await files.write(recordPath(desktopID), data: F.session(id: desktopID, cwd: workdir, originator: "Codex Desktop",
                                                                      prompt: "桌面版 needleword"))
        // 压缩的（目录是夹具里写死的 `/home/user/projects/archive`，自成一个项目）。
        try await files.write(recordPath(compressedID, compressed: true), data: CodexZstdFixture.small)
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("等「\(what)」超时") }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testListsReadsAndPagesOverRealSSH() async throws {
        let source = CodexHistorySource(provider: files)
        let projects = try await source.projects()
        let found = await source.project(containing: workdir, among: projects)
        let project = try XCTUnwrap(found)
        XCTAssertEqual(project.directory, workdir)
        XCTAssertTrue(projects.contains { $0.id == CodexZstdFixture.cwd })
        let canExecute = await source.canExecute
        let hasZstd = await source.hostHasZstd
        print("[codex-history-ssh] exec=\(String(describing: canExecute)) zstd=\(String(describing: hasZstd))")
        XCTAssertEqual(canExecute, true)

        let sessions = try await source.sessions(in: project)
        XCTAssertEqual(Set(sessions.map(\.sessionID)), [plainID, desktopID])
        let plain = try XCTUnwrap(sessions.first { $0.sessionID == plainID })
        let info = try await source.metadata(for: plain)
        XCTAssertEqual(info.title, "问题 0")
        XCTAssertTrue(info.isListed)
        let desktop = try XCTUnwrap(sessions.first { $0.sessionID == desktopID })
        let desktopInfo = try await source.metadata(for: desktop)
        XCTAssertFalse(desktopInfo.isListed)

        let pager = source.transcript(for: plain)
        var items: [AgentTranscriptItem] = []
        var reachedStart = false
        var pages = 0
        while !reachedStart {
            let page = try await pager.loadPrevious()
            items = page.items + items
            reachedStart = page.reachedStart
            pages += 1
        }
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(AgentTranscriptAssembler.attachResults(items).count, 900)

        // 压缩的：开头经 SFTP（主机上没有 zstd 时）或命令读出来，整份打开。
        let archive = try XCTUnwrap(projects.first { $0.id == CodexZstdFixture.cwd })
        let archived = try await source.sessions(in: archive)
        let compressed = try XCTUnwrap(archived.first)
        let compressedInfo = try await source.metadata(for: compressed)
        XCTAssertEqual(compressedInfo.title, "压缩记录里的第一句话 Zebra")
        let page = try await source.transcript(for: compressed).loadPrevious()
        XCTAssertTrue(page.reachedStart)
        XCTAssertEqual(page.items.last?.kind, .assistantText("压缩记录里的回答 Zebra done"))
    }

    func testSearchesOnTheHost() async throws {
        let source = CodexHistorySource(provider: files)
        let projects = try await source.projects()
        let all = await source.allSessions(in: projects)
        let found = SessionsSink()
        try await source.search(try AgentHistorySearchQuery.validate("NEEDLEWORD").get(), in: all, limits: .standard) { event in
            if case .session(let session) = event { found.append(session) }
        }
        XCTAssertEqual(found.sessions.map(\.file.sessionID), [plainID], "桌面版不出")
        XCTAssertEqual(found.sessions.first?.hits.count, AgentHistorySearchLimits.standard.hitsPerSession)
        let hit = try XCTUnwrap(found.sessions.first?.hits.first)
        let hitFile = try XCTUnwrap(found.sessions.first?.file)
        let page = try await source.transcript(for: hitFile, around: hit.anchor).loadPrevious()
        XCTAssertEqual(page.items.last?.id, hit.itemID)

        let coverage = await source.searchCoverage(of: all)
        let zebra = SessionsSink()
        try await source.search(try AgentHistorySearchQuery.validate("zebra").get(), in: all, limits: .standard) { event in
            if case .session(let session) = event { zebra.append(session) }
        }
        print("[codex-history-ssh] zebra sessions=\(zebra.sessions.count) unsearchable=\(coverage.unsearchable)")
        XCTAssertEqual(zebra.sessions.count, coverage.unsearchable == 0 ? 1 : 0)
    }

    func testResumeCommandRunsCodexInTheProjectDirectory() async throws {
        let source = CodexHistorySource(provider: files)
        let command = try XCTUnwrap(source.resumeCommand(sessionID: plainID, directory: workdir))
        let record = scratch + "/bin/record.txt"
        try await files.write(scratch + "/bin/codex", data: Data("""
            #!/bin/sh
            { pwd; printf '%s\\n' "$@"; } > \(Self.quoted(record))

            """.utf8))
        try await files.setPermissions(path: scratch + "/bin/codex", mode: 0o755)
        let connection = SSHConnection(
            profile: profile, auth: auth, jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: { _ in true })
        let session = TerminalSession()
        await session.connect(using: connection)
        XCTAssertEqual(session.connectionState, .connected)
        defer { session.dispose() }
        session.sendHostBytes(Data("PATH=\(Self.quoted(scratch + "/bin")):$PATH\n".utf8))
        session.startTrackedRun(command, inSubshell: false)
        await waitUntil("命令跑完") {
            if case .finished = session.trackedRun?.phase { return true }
            return false
        }
        XCTAssertEqual(session.trackedRun?.phase, .finished(0))
        let recorded = String(decoding: try await files.download(remotePath: record), as: UTF8.self)
        XCTAssertEqual(recorded.split(separator: "\n").map(String.init), [workdir, "resume", plainID])
    }
}

private final class SessionsSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AgentHistorySearchSession] = []
    var sessions: [AgentHistorySearchSession] { lock.withLock { stored } }
    func append(_ session: AgentHistorySearchSession) { lock.withLock { stored.append(session) } }
}
