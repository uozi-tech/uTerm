import XCTest
@testable import uTerm

/// Code 标签页里跑着的会话的标题与侧栏不闪：用真的 `ClaudeHistorySource` 读内存里的假主机（`SQLiteTestHost`），
/// 记录照真实的 Claude Code 2.1.x 写法——标题行（`ai-title`、`last-prompt`）只在每轮提问时追加一次，
/// 一轮长的工具调用之后末尾几百 KB 里一行标题都没有，中间还夹着一行上 MB 的请求记录。
///
/// 实测（2026-11-25，本机 4–16 MB 的会话记录）：末尾 64 KB 里经常没有标题行，列表那一行的标题随着文件变长在
/// 「Claude 起的名字」「（无标题）xxxx」之间来回跳；新会话对上记录之后侧栏不再重列，标题停在对上那一刻的样子，
/// Claude Code 后来起的名字一直出不来。
@MainActor
final class CodeTabRunTitleTests: XCTestCase {
    private static let home = "/home/user"
    private static let directory = "/home/user/shop"
    private static var projectDirectory: String {
        ClaudeProjectPath.projectsRoot(home: home) + "/" + ClaudeProjectPath.encode(directory)
    }

    private final class FakeTerminal: CodeTabTerminal {
        let id = UUID()
        var codeCommandHasEnded = false
        func runCodeCommand(_ command: String) {}
        func dispose() {}
    }

    override func setUp() async throws {
        try await super.setUp()
        AgentHistoryListCache.shared.removeAll()
    }

    override func tearDown() async throws {
        AgentHistoryListCache.shared.removeAll()
        try await super.tearDown()
    }

    // MARK: 假记录

    private static func path(_ id: String) -> String { projectDirectory + "/\(id).jsonl" }

    /// 一轮里 Claude Code 写的东西：用户的话、标题行（可选）、一串工具调用与结果（每行约 `lineBytes`，带 `entrypoint`）。
    private static func turn(prompt: String?, title: String?, toolLines: Int, lineBytes: Int = 2048,
                             cwd: String = directory) -> [String] {
        var lines: [String] = []
        if let prompt {
            lines.append(ClaudeFixture.userText(prompt, cwd: cwd))
            lines.append(ClaudeFixture.lastPrompt(prompt))
        }
        if let title { lines.append(ClaudeFixture.aiTitle(title)) }
        let padding = String(repeating: "x", count: lineBytes)
        for index in 0..<toolLines {
            lines.append(ClaudeFixture.assistant(ClaudeFixture.toolUse(id: "t\(index)", name: "Bash",
                                                                       input: #"{"command":"ls"}"#), cwd: cwd))
            lines.append(ClaudeFixture.user(content: #"[{"tool_use_id":"t\#(index)","type":"tool_result","content":"\#(padding)"}]"#,
                                            cwd: cwd))
        }
        return lines
    }

    /// 一行上 MB 的请求记录（真实文件里有 `api-request-shape`，近 1 MB 一行）。
    private static func hugeLine(_ bytes: Int = 1_000_000) -> String {
        #"{"type":"api-request-shape","sessionId":"s","shape":"\#(String(repeating: "y", count: bytes))"}"#
    }

    private func append(_ host: SQLiteTestHost, _ id: String, _ lines: [String], mtime: Date = Date()) async {
        var data = await host.data(Self.path(id)) ?? Data()
        data.append(ClaudeFixture.file(lines))
        await host.put(Self.path(id), data, mtime: mtime)
    }

    private func file(_ host: SQLiteTestHost, _ id: String) async -> AgentHistorySessionFile {
        let data = await host.data(Self.path(id)) ?? Data()
        let project = AgentHistoryProject(id: ClaudeProjectPath.encode(Self.directory), path: Self.projectDirectory,
                                          modifiedAt: nil)
        return AgentHistorySessionFile(sessionID: id, project: project, path: Self.path(id), size: UInt64(data.count),
                                       modifiedAt: Date())
    }

    // MARK: 数据源：标题不跟着末尾那一块跳

    /// 末尾 64 KB 里没有标题行（一轮长的工具调用、中间一行上 MB 的请求）：标题仍是 Claude Code 最近起的那个名字，
    /// 不退成「（无标题）」。
    func testLargeRecordKeepsItsAITitleWhenTheTailHasNone() async throws {
        let host = SQLiteTestHost(home: Self.home)
        await append(host, "big", Self.turn(prompt: "看看侧栏", title: "侧栏与 Desktop 的差异", toolLines: 20)
            + [Self.hugeLine()] + Self.turn(prompt: nil, title: nil, toolLines: 150))
        let source = ClaudeHistorySource(provider: host, home: Self.home)
        let metadata = try await source.metadata(for: await file(host, "big"))
        XCTAssertTrue(metadata.isListed)
        XCTAssertEqual(metadata.title, "侧栏与 Desktop 的差异", "末尾没有标题行时往前找最近的那一行")
    }

    /// 跑着的会话一直在写：每次重读（文件变长了）标题都稳定；有了新的名字就换成新的；往前找的那一段不重复读。
    func testTitleFollowsTheRecordAsItGrows() async throws {
        let host = SQLiteTestHost(home: Self.home)
        await append(host, "live", Self.turn(prompt: "第一问", title: "第一个名字", toolLines: 10))
        let source = ClaudeHistorySource(provider: host, home: Self.home)
        var metadata = try await source.metadata(for: await file(host, "live"))
        XCTAssertEqual(metadata.title, "第一个名字")

        for round in 0..<4 {
            await append(host, "live", Self.turn(prompt: nil, title: nil, toolLines: 60))
            await host.clearCounters()
            let grown = await file(host, "live")
            metadata = try await source.metadata(for: grown)
            XCTAssertEqual(metadata.title, "第一个名字", "第 \(round) 次变长：末尾没有标题行，标题不变")
            let read = await host.bytesRead
            XCTAssertLessThanOrEqual(read, 2 * 60 * 2 * 2200 + ClaudeHistorySource.tailBytes + 64 * 1024,
                                     "只往前找新写的那一段，不从头再找")
        }

        await append(host, "live", Self.turn(prompt: "第二问", title: "第二个名字", toolLines: 3))
        metadata = try await source.metadata(for: await file(host, "live"))
        XCTAssertEqual(metadata.title, "第二个名字", "Claude Code 起了新名字就换")
    }

    // MARK: 侧栏不闪

    /// 几个会话同时在写（同一个目录里别的终端也在跑 Claude Code），后台每次重列：显示的行一行不少、顺序之外标题都不变。
    func testBackgroundRefreshKeepsRowsAndTitlesWhileRecordsGrow() async throws {
        let host = SQLiteTestHost(home: Self.home)
        for (index, id) in ["a", "b", "c"].enumerated() {
            await append(host, id, Self.turn(prompt: "问 \(id)", title: "会话 \(id)", toolLines: 10),
                         mtime: Date().addingTimeInterval(-Double(100 * (index + 1))))
        }
        let source = ClaudeHistorySource(provider: host, home: Self.home)
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false)
        await history.start()
        await settle(history)
        func shown() -> [String: String] {
            Dictionary(uniqueKeysWithValues: history.visibleFiles.map {
                ($0.sessionID, AgentHistoryText.sessionTitle($0, metadata: history.metadata[$0.path]))
            })
        }
        let before = shown()
        XCTAssertEqual(before, ["a": "会话 a", "b": "会话 b", "c": "会话 c"])

        for round in 0..<5 {
            for id in ["a", "b", "c"] {
                await append(host, id, Self.turn(prompt: nil, title: nil, toolLines: 40) + (round == 2 ? [Self.hugeLine()] : []))
            }
            await history.reload(showsLoading: false)
            XCTAssertEqual(Set(history.visibleFiles.map(\.sessionID)), ["a", "b", "c"], "第 \(round) 次重列：行不消失")
            await settle(history)
            XCTAssertEqual(shown(), before, "第 \(round) 次重列：标题不跳")
        }
    }

    // MARK: 跑着的会话跟着 Claude Code 起的名字

    /// 「＋」新开的会话：记录在起来之后才写出来，同一个目录里别的会话也一直在写，中途工作目录换到了 worktree。
    /// 对上之后标题跟着 Claude Code 写的 `ai-title` 走（终端顶上那一条与侧栏那一行同一个来源），起了新名字也跟着换。
    func testNewSessionPicksUpItsRecordAndFollowsTheAITitle() async throws {
        let host = SQLiteTestHost(home: Self.home)
        await append(host, "other", Self.turn(prompt: "别的终端里的会话", title: "别的会话", toolLines: 5),
                     mtime: Date().addingTimeInterval(-600))
        let source = ClaudeHistorySource(provider: host, home: Self.home)
        let history = AgentHistoryModel(source: source, preferredDirectory: Self.directory, followsCurrentProject: false)
        await history.start()
        await settle(history)
        let code = CodeTabModel(hostName: "mac", directory: Self.directory) { _ in FakeTerminal() }
        code.timing = .init(check: .milliseconds(20), refresh: .milliseconds(60))
        code.install(AgentHistoryConnection(history: history))
        defer { code.close() }
        let run = try XCTUnwrap(code.startNewSession(tool: .claude, command: "claude", directory: Self.directory))
        XCTAssertEqual(code.title(of: run), AgentHistoryText.newSession)

        // 用户敲了第一句：记录写出来（还没有 AI 起的名字）。别的会话同时也在写。
        await append(host, "mine", Self.turn(prompt: "研究一下侧栏", title: nil, toolLines: 2))
        await append(host, "other", Self.turn(prompt: nil, title: nil, toolLines: 3))
        try await waitUntil("对上记录") { code.runs.first?.path == Self.path("mine") }
        XCTAssertTrue([AgentHistoryText.newSession, "研究一下侧栏"].contains(code.title(of: try XCTUnwrap(code.runs.first))),
                      "刚对上、记录的信息还没读到：仍叫「新会话」，不闪一下「（无标题）」")
        try await waitUntil("还没有 AI 起的名字：先用提问") {
            code.runs.first.map { code.title(of: $0) } == "研究一下侧栏"
        }

        // Claude Code 起了名字，之后一长串工具调用（末尾没有标题行），工作目录换到了 worktree。
        await append(host, "mine", [ClaudeFixture.aiTitle("Code 视图侧边栏与 Desktop 差异")]
                     + Self.turn(prompt: nil, title: nil, toolLines: 50, cwd: Self.directory + "/.claude/worktrees/fix"))
        try await waitUntil("标题换成 AI 起的名字") {
            code.runs.first.map { code.title(of: $0) } == "Code 视图侧边栏与 Desktop 差异"
        }
        let mine = try XCTUnwrap(history.files.first { $0.sessionID == "mine" })
        XCTAssertEqual(history.metadata[mine.path]?.title, "Code 视图侧边栏与 Desktop 差异", "侧栏那一行同一个标题")

        await append(host, "mine", Self.turn(prompt: "再看看闪烁", title: "侧栏闪烁", toolLines: 2))
        try await waitUntil("起了新名字也跟着换") { code.runs.first.map { code.title(of: $0) } == "侧栏闪烁" }
        XCTAssertEqual(code.runs.count, 1)
        XCTAssertEqual(code.runs.first?.path, Self.path("mine"), "别的会话一直在写也不认错")
    }

    /// 「继续」的会话：标题一开始是继续时那份记录的，之后 Claude Code 改了名字也跟着换。
    func testResumedSessionFollowsRenames() async throws {
        let host = SQLiteTestHost(home: Self.home)
        let id = "3f2c8f87-b3ad-43be-bd14-6498e9b4b618"
        await append(host, id, Self.turn(prompt: "输入延迟", title: "uTerm 与 iGhostTV 输入延迟对比", toolLines: 5),
                     mtime: Date().addingTimeInterval(-600))
        let source = ClaudeHistorySource(provider: host, home: Self.home)
        let history = AgentHistoryModel(source: source, preferredDirectory: Self.directory, followsCurrentProject: false)
        await history.start()
        await settle(history)
        let code = CodeTabModel(hostName: "mac", directory: Self.directory) { _ in FakeTerminal() }
        code.timing = .init(check: .milliseconds(20), refresh: .milliseconds(60))
        code.install(AgentHistoryConnection(history: history))
        defer { code.close() }
        let old = try XCTUnwrap(history.files.first { $0.sessionID == id })
        let run = try XCTUnwrap(code.resume(old))
        XCTAssertEqual(code.title(of: run), "uTerm 与 iGhostTV 输入延迟对比")

        await append(host, id, Self.turn(prompt: "换个方向", title: "输入延迟：换个测法", toolLines: 2))
        try await waitUntil("继续的会话也跟着新名字") { code.runs.first.map { code.title(of: $0) } == "输入延迟：换个测法" }
    }

    // MARK: 后台重列出岔子时标题不退回「（无标题）」

    /// 实测（2026-11-25，build 1500）：同一个 Code 标签页里接回了两个会话，退出其中一个之后，另一个侧栏那一行与终端顶上
    /// 都变成「（无标题）6d0608a6」，那一行也不再是列表里那份记录的样子（只写目录），之后一直这样。
    ///
    /// 退出会整个重列一次。那一趟正赶上辅助程序一时连不上（Claude Code 的项目目录列不出来、也取不到属性）：以前数据源
    /// 当成「没用过」、一份都不列，标题就只剩会话 ID，侧栏也只剩顶上跑着的那几行；之后每 10 秒的重读只认列表里有的项目，
    /// 永远补不回来。现在数据源报错（`AgentHistoryMissingPath`），这一种工具上一次列到的会话留着（见
    /// `AgentHistoryTransientFailureTests`）。这里用假主机复现同样的形状：标题在末尾 64 KB 之外、靠往前找；另有一种工具
    /// 的记录，所以那一趟照常列完。
    func testRunKeepsItsTitleWhenAReloadMissesItsRecordAndComesBack() async throws {
        let host = SQLiteTestHost(home: Self.home)
        let mine = "6d0608a6-76df-4181-a620-48e53965caba"
        let other = "3f2c8f87-b3ad-43be-bd14-6498e9b4b618"
        await append(host, mine, Self.turn(prompt: "研究侧栏", title: "Code 视图侧边栏与 Desktop 差异", toolLines: 20)
            + [Self.hugeLine()] + Self.turn(prompt: nil, title: nil, toolLines: 100), mtime: Date().addingTimeInterval(-30))
        await append(host, other, Self.turn(prompt: "统筹", title: "多 Agent 进度统筹", toolLines: 5),
                     mtime: Date().addingTimeInterval(-60))
        await append(host, "old", Self.turn(prompt: "旧的", title: "以前的会话", toolLines: 2),
                     mtime: Date().addingTimeInterval(-6000))
        let codex = AgentHistoryFakeSource(tool: .codex, sessions: [
            .init(id: "x1", projectID: "2026-11", projectDirectory: Self.directory, resumeDirectory: Self.directory,
                  title: "Codex 的会话", modifiedAt: Date().addingTimeInterval(-9000)),
        ])
        let source = AgentHistoryCompositeSource([ClaudeHistorySource(provider: host, home: Self.home), codex])
        let history = AgentHistoryModel(source: source, preferredDirectory: Self.directory, followsCurrentProject: false)
        let code = CodeTabModel(hostName: "mac", directory: Self.directory) { _ in FakeTerminal() }
        code.timing = .init(check: .milliseconds(20), refresh: .milliseconds(60))
        defer { code.close() }
        // App 重启后接回的两个会话（同实测：都是在 App 不在时就跑着的）。
        let mineTerminal = FakeTerminal(), otherTerminal = FakeTerminal()
        let started = Date().addingTimeInterval(-3600)
        code.restore(CodeTabRecord(id: UUID(), directory: Self.directory, runs: [
            CodeRunRecord(session: otherTerminal.id, tool: .claude, sessionID: other, directory: Self.directory, startedAt: started),
            CodeRunRecord(session: mineTerminal.id, tool: .claude, sessionID: mine, directory: Self.directory, startedAt: started),
        ], selectedRun: mineTerminal.id), terminals: [mineTerminal.id: mineTerminal, otherTerminal.id: otherTerminal])
        code.install(AgentHistoryConnection(history: history))
        await history.start()
        await settle(history)
        code.applyRestoredState()
        func run() throws -> CodeTabModel.Run { try XCTUnwrap(code.runs.first { $0.id == mineTerminal.id }) }
        XCTAssertEqual(code.title(of: try run()), "Code 视图侧边栏与 Desktop 差异")
        XCTAssertEqual(try run().path, Self.path(mine))

        // 辅助程序断了一下的时候，另一个会话退出了：收尾时整个重列，这一趟 Claude Code 的记录一份都列不出来。
        await host.setUnreachable([ClaudeProjectPath.projectsRoot(home: Self.home)])
        otherTerminal.codeCommandHasEnded = true
        try await waitUntil("退出的那个收尾、重列时 Claude Code 列不出来") {
            code.runs.count == 1 && history.toolFailures[.claude] != nil
        }
        XCTAssertTrue(history.visibleFiles.contains { $0.path == Self.path(mine) }, "列不出来不是「没有」：记录留在列表里")
        XCTAssertTrue(history.visibleFiles.contains { $0.sessionID == "old" }, "别的会话也都还在")
        XCTAssertEqual(code.title(of: try run()), "Code 视图侧边栏与 Desktop 差异",
                       "读过的标题还在：不退回「（无标题）6d0608a6」")

        // 连上了：照常，标题照旧。
        await host.setUnreachable([])
        try await waitUntil("记录补回列表") { history.visibleFiles.contains { $0.path == Self.path(mine) } }
        XCTAssertEqual(code.title(of: try run()), "Code 视图侧边栏与 Desktop 差异")
        XCTAssertEqual(history.metadata[Self.path(mine)]?.title, "Code 视图侧边栏与 Desktop 差异")
    }

    /// 跑着的会话的记录重读时读失败（辅助程序断了一下）：留着上次读到的标题，不换成「（无标题）」；连上后照常跟着记录走。
    func testFailedRereadKeepsTheTitleItHad() async throws {
        let host = SQLiteTestHost(home: Self.home)
        await append(host, "live", Self.turn(prompt: "第一问", title: "第一个名字", toolLines: 10))
        let history = AgentHistoryModel(source: ClaudeHistorySource(provider: host, home: Self.home),
                                        preferredDirectory: nil, followsCurrentProject: false)
        await history.start()
        await settle(history)
        XCTAssertEqual(history.metadata[Self.path("live")]?.title, "第一个名字")

        await append(host, "live", Self.turn(prompt: nil, title: nil, toolLines: 20))
        await host.setUnreachable([Self.path("live")])
        await host.clearCounters()
        await history.refreshProjects(containing: [Self.path("live")])
        // 等重读真的发出去、失败回来（读不到的那一下之后列表照常排完）。
        for _ in 0..<200 where await !host.reads.contains(where: { $0.path == Self.path("live") }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(history.metadata[Self.path("live")]?.title, "第一个名字", "重读失败：留着上次读到的")
        let row = try XCTUnwrap(history.files.first { $0.path == Self.path("live") })
        XCTAssertEqual(AgentHistoryText.sessionTitle(row, metadata: history.metadata[row.path]), "第一个名字")

        await host.setUnreachable([])
        await append(host, "live", Self.turn(prompt: "第二问", title: "第二个名字", toolLines: 2))
        await history.refreshProjects(containing: [Self.path("live")])
        try await waitUntil("连上后照常重读") { history.metadata[Self.path("live")]?.title == "第二个名字" }
    }

    // MARK: 工具

    private func settle(_ history: AgentHistoryModel) async {
        for _ in 0..<400 where history.hasMore || history.isListing {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("等「\(what)」超时", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
