import Foundation
import SwiftData
import XCTest
@testable import uTerm

/// 「Claude 历史会话」对着**真 sshd** 端到端跑：假记录写到主机的 `~/.claude/projects` 下，经真的 SFTP 列出来、
/// 读标题与来源、一页一页往前翻；再在真的登录 shell 里执行「继续这个会话」那条命令，看它落在哪个目录、带什么参数。
///
/// 需要外部 sshd，所以**默认跳过**。跑法（和 `PersistentSSHConnectionLiveTests` 用同一个镜像、同一组开关）：
///
/// ```
/// docker run -d --name uterm-claude-history-live -p 127.0.0.1:2297:22 uterm-holder-e2e-sshd
/// TEST_RUNNER_UTERM_LIVE_SSH_PORT=2297 TEST_RUNNER_UTERM_LIVE_SSH_USER=dev TEST_RUNNER_UTERM_LIVE_SSH_PASSWORD=dev \
///   xcodebuild test-without-building … -only-testing:uTermTests/ClaudeHistoryLiveSSHTests
/// ```
///
/// 记录内容全是编的。只动自己建的东西：每次在主目录下建一个带随机后缀的工作目录，对应的项目目录名因此也是
/// 独一份，结束时只删这两处——指到一台真用着 Claude Code 的主机上也不会碰它原有的记录。
/// 主机上不需要装 Claude Code：`claude` 是用例放进 `PATH` 最前面的一个假脚本，只把目录和参数记下来。
@MainActor
final class ClaudeHistoryLiveSSHTests: XCTestCase {
    private var profile: SSHConnection.ProfileSnapshot!
    private var auth: ResolvedAuth!
    private var container: ModelContainer!
    private var files: SFTPSession!
    private var home = ""
    /// 工作目录：带空格、单引号、中文，「继续这个会话」的引号要扛得住。
    private var workdir = ""
    private var scratch = ""
    private var projectPath = ""
    /// 派过子代理的会话放在另一个项目里（不扰动上面那个项目的列表断言）。
    private var agentsWorkdir = ""
    private var agentsProjectPath = ""
    private var agentsSubagentsDir: String { agentsProjectPath + "/" + Session.agents + "/subagents" }

    private enum Session {
        static let cli = "11111111-aaaa-4bbb-8ccc-000000000001"
        static let desktop = "11111111-aaaa-4bbb-8ccc-000000000002"
        static let mixed = "11111111-aaaa-4bbb-8ccc-000000000003"
        static let empty = "11111111-aaaa-4bbb-8ccc-000000000004"
        static let moved = "11111111-aaaa-4bbb-8ccc-000000000005"
        static let agents = "11111111-aaaa-4bbb-8ccc-000000000006"
    }

    /// 大的那份记录有几轮对话；每轮一问、一答带一次工具调用、一条工具结果。
    private static let turns = 600

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
        // 和窗口同一条路：共享连接上开 SFTP（`SFTPSession.make` 解出凭据之后做的就是这两步）。
        let connected = try await SSHClientFactory.connectShared(
            profile: profile, auth: auth, jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: { _ in true })
        files = try await SFTPSession(connected: connected)
        home = try await files.realPath(".")
        scratch = home + "/uterm-claude-history-e2e-" + UUID().uuidString.prefix(8).lowercased()
        workdir = scratch + "/it's a 项目"
        projectPath = ClaudeProjectPath.projectsRoot(home: home) + "/" + ClaudeProjectPath.encode(workdir)
        agentsWorkdir = scratch + "/agents"
        agentsProjectPath = ClaudeProjectPath.projectsRoot(home: home) + "/" + ClaudeProjectPath.encode(agentsWorkdir)
        _ = try await files.exec("mkdir -p \(Self.quoted(workdir + "/sub dir")) \(Self.quoted(projectPath)) \(Self.quoted(scratch + "/bin"))"
                                 + " \(Self.quoted(agentsWorkdir)) \(Self.quoted(agentsSubagentsDir + "/workflows"))")
        try await seed()
        try await seedSubagents()
    }

    override func tearDown() async throws {
        if let files {
            if !scratch.isEmpty {
                _ = try? await files.exec("rm -rf \(Self.quoted(scratch)) \(Self.quoted(projectPath)) \(Self.quoted(agentsProjectPath))")
            }
            await files.close()
        }
        files = nil
        try await super.tearDown()
    }

    // MARK: - 夹具

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func sessionPath(_ id: String) -> String { projectPath + "/" + id + ".jsonl" }

    private func seed() async throws {
        // 命令行起的大会话：约 3 MB，翻完要十几页。
        var lines: [String] = []
        let padding = String(repeating: "填充文字。", count: 800)
        for turn in 0..<Self.turns {
            let toolID = "toolu_\(turn)"
            lines.append(ClaudeFixture.userText("问题 \(turn)", uuid: "u-\(turn)", cwd: workdir))
            lines.append(ClaudeFixture.noise(turn))
            lines.append(ClaudeFixture.assistant(
                ClaudeFixture.textBlock("回答 \(turn)\n\n" + padding) + ","
                    + ClaudeFixture.toolUse(id: toolID, name: "Bash", input: #"{"command":"echo \#(turn)"}"#),
                uuid: "a-\(turn)", cwd: workdir))
            lines.append(ClaudeFixture.user(
                content: #"[{"tool_use_id":"\#(toolID)","type":"tool_result","content":"结果 \#(turn)","is_error":false}]"#,
                uuid: "r-\(turn)", cwd: workdir))
        }
        lines.append(ClaudeFixture.aiTitle("大会话的标题"))
        lines.append(ClaudeFixture.lastPrompt("问题 \(Self.turns - 1)"))
        try await files.write(sessionPath(Session.cli), data: ClaudeFixture.file(lines))

        try await files.write(sessionPath(Session.desktop), data: ClaudeFixture.file([
            ClaudeFixture.userText("桌面版里问的", entrypoint: "claude-desktop", cwd: workdir),
            ClaudeFixture.assistant(ClaudeFixture.textBlock("桌面版里答的"), entrypoint: "claude-desktop", cwd: workdir),
            ClaudeFixture.customTitle("桌面版的会话"),
        ]))
        try await files.write(sessionPath(Session.mixed), data: ClaudeFixture.file([
            ClaudeFixture.userText("桌面版里开的头", entrypoint: "claude-desktop", cwd: workdir),
            ClaudeFixture.assistant(ClaudeFixture.textBlock("好的"), entrypoint: "claude-desktop", cwd: workdir),
            ClaudeFixture.userText("回到命令行接着聊", uuid: "u-2", cwd: workdir),
            ClaudeFixture.assistant(ClaudeFixture.textBlock("接着聊"), uuid: "a-2", cwd: workdir),
        ]))
        // 只打过斜杠命令、没有对话。
        try await files.write(sessionPath(Session.empty), data: ClaudeFixture.file([
            ClaudeFixture.noise(1),
            ClaudeFixture.userText("<command-name>/exit</command-name>\n<command-message>exit</command-message>\n<command-args></command-args>",
                                   cwd: workdir),
            ClaudeFixture.userText("<local-command-stdout>Goodbye!</local-command-stdout>", uuid: "u-2", cwd: workdir),
        ]))
        // 在项目目录里起的，后来 `cd` 进了子目录：继续时仍然回项目目录（按子目录找不到这份记录）。
        try await files.write(sessionPath(Session.moved), data: ClaudeFixture.file([
            ClaudeFixture.userText("在项目目录里起的", cwd: workdir),
            ClaudeFixture.assistant(ClaudeFixture.textBlock("好"), cwd: workdir),
            ClaudeFixture.userText("后来进了子目录", uuid: "u-2", cwd: workdir + "/sub dir"),
            ClaudeFixture.assistant(ClaudeFixture.textBlock("好"), uuid: "a-2", cwd: workdir + "/sub dir"),
            ClaudeFixture.aiTitle("挪过目录的会话"),
        ]))
    }

    /// 派了两个子代理的会话：第一个的结果里报了 ID（没有 meta），第二个还在跑（只有 meta）；第二个又派了一个。
    /// 目录里还有不相干的东西（`*.prefix.json`、`workflows/`）。
    private func seedSubagents() async throws {
        let dir = agentsSubagentsDir
        try await files.write(agentsProjectPath + "/" + Session.agents + ".jsonl", data: ClaudeFixture.file([
            ClaudeFixture.userText("分两路去查", cwd: agentsWorkdir),
            ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_live_1", description: "第一路"), cwd: agentsWorkdir),
            ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_live_2", description: "第二路", type: "Explore"),
                                    uuid: "a-2", cwd: agentsWorkdir),
            ClaudeFixture.spawnResult(id: "toolu_live_1", agentID: "live1"),
            ClaudeFixture.aiTitle("派了子代理的会话"),
        ]))
        try await files.write(dir + "/agent-live1.jsonl", data: ClaudeFixture.file([
            ClaudeFixture.sidechainUser("第一路的任务", agentID: "live1"),
            ClaudeFixture.sidechainAssistant(ClaudeFixture.textBlock("第一路查完了"), agentID: "live1"),
        ]))
        try await files.write(dir + "/agent-live2.jsonl", data: ClaudeFixture.file([
            ClaudeFixture.sidechainUser("第二路的任务", agentID: "live2"),
            ClaudeFixture.sidechainAssistant(ClaudeFixture.spawn(id: "toolu_live_3", description: "第二路的第二层"),
                                             agentID: "live2"),
        ]))
        try await files.write(dir + "/agent-live2.meta.json",
                              data: ClaudeFixture.subagentMeta(toolUseID: "toolu_live_2", type: "Explore", description: "第二路"))
        try await files.write(dir + "/agent-live3.jsonl", data: ClaudeFixture.file([
            ClaudeFixture.sidechainUser("第二层的任务", agentID: "live3"),
            ClaudeFixture.sidechainAssistant(ClaudeFixture.textBlock("第二层查完了"), agentID: "live3"),
        ]))
        try await files.write(dir + "/agent-live3.meta.json",
                              data: ClaudeFixture.subagentMeta(toolUseID: "toolu_live_3", description: "第二路的第二层", depth: 2))
        try await files.write(dir + "/agent-live2.prefix.json", data: Data("{}".utf8))
    }

    private func file(_ id: String, among files: [AgentHistorySessionFile],
                      file: StaticString = #filePath, line: UInt = #line) throws -> AgentHistorySessionFile {
        try XCTUnwrap(files.first { $0.sessionID == id }, "列表里没有 \(id)", file: file, line: line)
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

    // MARK: - 列表、来源、标题

    func testListsOnlyCLISessionsOfTheTerminalsProject() async throws {
        let source = ClaudeHistorySource(provider: files)
        // 终端在子目录里：对上的是上一级那个项目。
        let model = AgentHistoryModel(source: source, preferredDirectory: workdir + "/sub dir")
        await model.start()

        XCTAssertEqual(model.phase, .ready)
        guard case .project(let project) = model.scope else { return XCTFail("没有落在当前项目上：\(model.scope)") }
        XCTAssertEqual(project.path, projectPath)
        XCTAssertEqual(project.directory, workdir)
        XCTAssertEqual(Set(model.files.map(\.sessionID)),
                       [Session.cli, Session.desktop, Session.mixed, Session.empty, Session.moved])

        // 不用谁去催：列出来之后自己把第一批读了。
        await waitUntil("五份记录的信息都读到") { !model.hasMore }
        XCTAssertEqual(model.metadata.count, 5)

        XCTAssertEqual(Set(model.visibleFiles.map(\.sessionID)), [Session.cli, Session.mixed, Session.moved])
        XCTAssertEqual(model.hiddenCount, 2)

        let big = try file(Session.cli, among: model.files)
        XCTAssertGreaterThan(big.size, 2 * 1024 * 1024, "大会话要大到翻好几页")
        XCTAssertEqual(model.metadata[big.path]?.title, "大会话的标题")
        XCTAssertEqual(model.metadata[big.path]?.gitBranch, "main")
        XCTAssertEqual(model.metadata[try file(Session.mixed, among: model.files).path]?.title, "回到命令行接着聊")
        XCTAssertEqual(model.metadata[try file(Session.desktop, among: model.files).path]?.isListed, false)
        XCTAssertEqual(model.metadata[try file(Session.empty, among: model.files).path]?.isListed, false)

        let moved = try file(Session.moved, among: model.files)
        XCTAssertEqual(model.metadata[moved.path]?.lastDirectory, workdir + "/sub dir")
        XCTAssertEqual(model.metadata[moved.path]?.resumeDirectory, workdir)

        // 「全部项目」里也有它们（主机上别的项目照样列着，不去数）。
        await model.setScope(.all)
        XCTAssertTrue(Set(model.files.map(\.sessionID)).isSuperset(of: [Session.cli, Session.mixed, Session.moved]))
    }

    /// 标题与来源只读末尾一小块：3 MB 的记录读信息不该比读一页对话慢多少。
    func testMetadataOfALargeSessionReadsQuickly() async throws {
        let source = ClaudeHistorySource(provider: files)
        let projects = try await source.projects()
        let project = try XCTUnwrap(projects.first { $0.path == projectPath })
        let big = try file(Session.cli, among: try await source.sessions(in: project))

        let started = ContinuousClock.now
        let info = try await source.metadata(for: big)
        let elapsed = ContinuousClock.now - started
        XCTAssertTrue(info.isListed)
        XCTAssertLessThan(elapsed, .seconds(2), "读一份记录的标题用了 \(elapsed)")
        print("[claude-history-live] metadata of \(big.size) bytes: \(elapsed)")
    }

    // MARK: - 对话

    func testPagesBackwardsThroughALargeTranscript() async throws {
        let source = ClaudeHistorySource(provider: files)
        let model = AgentHistoryModel(source: source, preferredDirectory: workdir)
        await model.start()
        let big = try file(Session.cli, among: model.files)

        let started = ContinuousClock.now
        model.select(big)
        let transcript = try XCTUnwrap(model.transcript)
        await waitUntil("第一页") { !transcript.items.isEmpty }
        let firstPage = ContinuousClock.now - started
        XCTAssertFalse(transcript.reachedStart, "3 MB 的记录不该一页读完")
        // 第一页是最后那几轮。
        XCTAssertEqual(transcript.items.last?.role, .assistant)
        XCTAssertTrue(transcript.items.contains { $0.kind == .userText("问题 \(Self.turns - 1)") })

        var pages = 1
        while !transcript.reachedStart {
            XCTAssertNil(transcript.errorMessage)
            await transcript.loadEarlier()
            pages += 1
            guard pages < 400 else { return XCTFail("翻了 400 页还没到头") }
        }
        let total = ContinuousClock.now - started
        print("[claude-history-live] first page \(firstPage), \(pages) pages in \(total)")

        // 一条不少、顺序不乱。
        let questions = transcript.items.compactMap { item -> String? in
            if case .userText(let text) = item.kind { return text }
            return nil
        }
        XCTAssertEqual(questions, (0..<Self.turns).map { "问题 \($0)" })
        // 工具结果都挂回了自己的调用上，包括调用和结果落在两页里的。
        var calls = 0
        for item in transcript.items {
            switch item.kind {
            case .toolCall(let call):
                XCTAssertEqual(call.result?.content.text, "结果 \(calls)", "第 \(calls) 次调用的结果")
                calls += 1
            case .toolResult:
                XCTFail("有工具结果没挂到调用上：\(item.id)")
            default:
                break
            }
        }
        XCTAssertEqual(calls, Self.turns)
        XCTAssertEqual(Set(transcript.items.map(\.id)).count, transcript.items.count, "条目的 ID 有重复")
        XCTAssertGreaterThan(pages, 3)
        XCTAssertLessThan(firstPage, .seconds(3), "第一页用了 \(firstPage)")
    }

    // MARK: - 子代理

    /// 经真的 SFTP 列 `subagents/`、读 meta，点进子代理、再点进它派的子代理，一层层返回。
    func testOpensSubagentTranscriptsOverSFTP() async throws {
        let model = AgentHistoryModel(source: ClaudeHistorySource(provider: files), preferredDirectory: agentsWorkdir)
        await model.start()
        await waitUntil("记录的信息") { !model.hasMore }
        model.select(try file(Session.agents, among: model.files))
        let main = try XCTUnwrap(model.transcript)
        await waitUntil("两个子代理都对上") { main.reachedStart && main.subagentLinks.count == 2 }
        XCTAssertEqual(main.subagentLinks["toolu_live_1"]?.file.agentID, "live1", "靠结果里的 agentId")
        XCTAssertEqual(main.subagentLinks["toolu_live_2"]?.file.agentID, "live2", "靠 meta")
        XCTAssertEqual(main.subagentLinks["toolu_live_2"]?.agentType, "Explore")

        let started = ContinuousClock.now
        model.openSubagent(try XCTUnwrap(main.subagentLinks["toolu_live_2"]))
        let second = try XCTUnwrap(model.displayedTranscript)
        await waitUntil("第二路的记录与它派的子代理") { second.reachedStart && second.subagentLinks["toolu_live_3"] != nil }
        print("[claude-history-live] subagent open + nested link in \(ContinuousClock.now - started)")
        XCTAssertEqual(second.items.first?.kind, .userText("第二路的任务"))

        model.openSubagent(try XCTUnwrap(second.subagentLinks["toolu_live_3"]))
        let third = try XCTUnwrap(model.displayedTranscript)
        await waitUntil("第二层的记录") { third.reachedStart }
        XCTAssertEqual(third.items.map(\.kind), [.userText("第二层的任务"), .assistantText("第二层查完了")])
        model.closeSubagent()
        model.closeSubagent()
        XCTAssertTrue(model.displayedTranscript === main)
    }

    // MARK: - 实时跟随

    /// 打开着的记录在主机上被追加（`printf … >>`，和 Claude Code 写记录一样是追加）：一两个轮询周期（每 2 秒）内接上来；
    /// 先写半行、再补完，半行不显示；新来的工具结果挂回前面的调用。
    func testFollowsAppendsOnTheHost() async throws {
        let path = agentsProjectPath + "/" + Session.agents + ".jsonl"
        let model = AgentHistoryModel(source: ClaudeHistorySource(provider: files), preferredDirectory: agentsWorkdir)
        await model.start()
        await waitUntil("记录的信息") { !model.hasMore }
        model.select(try file(Session.agents, among: model.files))
        let transcript = try XCTUnwrap(model.transcript)
        await waitUntil("第一页") { transcript.reachedStart }
        let before = transcript.items.count
        model.setTranscriptVisible(true)
        defer { model.setTranscriptVisible(false) }

        func append(_ text: String) async throws {
            _ = try await files.exec("printf '%s' \(Self.quoted(text)) >> \(Self.quoted(path))")
        }
        let call = ClaudeFixture.assistant(
            ClaudeFixture.toolUse(id: "toolu_follow", name: "Bash", input: #"{"command":"uptime"}"#), uuid: "f-1",
            cwd: agentsWorkdir)
        var started = ContinuousClock.now
        try await append(call + "\n")
        await waitUntil("追加的调用接上来", timeout: .seconds(6)) { transcript.items.count == before + 1 }
        let first = ContinuousClock.now - started
        XCTAssertTrue(transcript.isUpdating)

        let result = ClaudeFixture.toolResult(id: "toolu_follow", text: "up 3 days")
        let answer = ClaudeFixture.assistant(ClaudeFixture.textBlock("主机已经跑了 3 天"), uuid: "f-2", cwd: agentsWorkdir)
        let half = answer.index(answer.startIndex, offsetBy: answer.count / 2)
        try await append(result + "\n" + String(answer[..<half]))
        await waitUntil("结果挂回调用", timeout: .seconds(6)) {
            guard case .toolCall(let done) = transcript.items.last?.kind else { return false }
            return done.result?.content.text == "up 3 days"
        }
        try await Task.sleep(for: .seconds(2.5))
        XCTAssertEqual(transcript.items.count, before + 1, "半行不该显示")

        started = ContinuousClock.now
        try await append(String(answer[half...]) + "\n")
        await waitUntil("补完的那一行", timeout: .seconds(6)) { transcript.items.count == before + 2 }
        let second = ContinuousClock.now - started
        XCTAssertEqual(transcript.items.last?.kind, .assistantText("主机已经跑了 3 天"))
        XCTAssertEqual(Set(transcript.items.map(\.id)).count, transcript.items.count, "条目的 ID 有重复")
        print("[claude-history-live] follow: appended line shown in \(first), finished half line in \(second)")
    }

    // MARK: - 继续这个会话

    /// 真的登录 shell 里执行那条命令：落在项目目录里（路径带空格、单引号、中文），参数是 `--resume <ID>`。
    func testResumeCommandRunsClaudeInTheProjectDirectory() async throws {
        let source = ClaudeHistorySource(provider: files)
        let model = AgentHistoryModel(source: source, preferredDirectory: workdir + "/sub dir")
        await model.start()
        await waitUntil("记录的信息") { !model.hasMore }
        let moved = try file(Session.moved, among: model.files)
        let plan = try XCTUnwrap(model.resumeCommand(for: moved))
        XCTAssertEqual(plan.directory, workdir)

        // 假的 `claude`：把所在目录和参数一行一个记下来。
        let record = scratch + "/bin/record.txt"
        try await files.write(scratch + "/bin/claude", data: Data("""
            #!/bin/sh
            { pwd; printf '%s\\n' "$@"; } > \(Self.quoted(record))

            """.utf8))
        try await files.setPermissions(path: scratch + "/bin/claude", mode: 0o755)

        let connection = SSHConnection(
            profile: profile, auth: auth, jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: { _ in true })
        let session = TerminalSession()
        await session.connect(using: connection)
        XCTAssertEqual(session.connectionState, .connected)
        session.sendHostBytes(Data("PATH=\(Self.quoted(scratch + "/bin")):$PATH\n".utf8))

        // 和窗口里一样不包子 shell：退出 Claude Code 之后 shell 要留在项目目录里。
        let run = session.startTrackedRun(plan.command, inSubshell: false)
        await waitUntil("命令跑完") {
            if case .finished = session.trackedRun?.phase { return true }
            return false
        }
        XCTAssertEqual(session.trackedRun?.id, run.id)
        XCTAssertEqual(session.trackedRun?.phase, .finished(0),
                       "屏幕：\n\(session.snapshotScreen(lines: 40, maxBytes: 8192).lines.joined(separator: "\n"))")

        let recorded = String(decoding: try await files.download(remotePath: record), as: UTF8.self)
        XCTAssertEqual(recorded.split(separator: "\n").map(String.init), [workdir, "--resume", Session.moved])

        // 「退出」之后 shell 还在项目目录里（新标签是从主目录起的）。
        let after = scratch + "/bin/after.txt"
        session.sendHostBytes(Data(" pwd > \(Self.quoted(after))\n".utf8))
        var where_ = ""
        let deadline = ContinuousClock.now + .seconds(10)
        while where_.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            where_ = (try? await files.download(remotePath: after)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        XCTAssertEqual(where_.trimmingCharacters(in: .newlines), workdir)

        await connection.close()
        session.dispose()
    }

    // MARK: - 主机密钥

    /// 历史窗口不弹主机密钥的确认：指纹没确认过就连不上，确认过（终端连过）就直接通。
    func testUnknownHostKeyIsRejectedWithoutPrompting() async throws {
        let fresh = try ModelContainer(
            for: ServerProfile.self, KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        // 不走共享连接：池里已经有 `setUp` 开的那条，拿到它就不会再核指纹。
        let unknown = ClaudeHistoryHostKeyGate()
        do {
            let client = try await SSHClientFactory.connect(
                profile: profile, auth: auth, jumpHostAuth: nil,
                hostKeyVerifier: HostKeyVerifier(modelContainer: fresh), hostKeyApprover: unknown.approver)
            await client.close()
            XCTFail("没确认过的指纹不该连上")
        } catch {
            XCTAssertTrue(unknown.wasChallenged)
            // 提示的是「回终端里去确认」，不是底层那句「用户拒绝了」——这里没人问过用户。
            XCTAssertNotEqual(unknown.failureMessage(for: error), FriendlyError.describe(error))
            XCTAssertFalse(unknown.failureMessage(for: error).isEmpty)
        }

        // 同一个库里指纹已经确认过（`setUp` 那次）：不问也能连上。
        let known = ClaudeHistoryHostKeyGate()
        let client = try await SSHClientFactory.connect(
            profile: profile, auth: auth, jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: known.approver)
        await client.close()
        XCTAssertFalse(known.wasChallenged)
        // 别的失败照原样报。
        struct Other: LocalizedError { var errorDescription: String? { "别的错" } }
        XCTAssertEqual(known.failureMessage(for: Other()), FriendlyError.describe(Other()))
    }
}
