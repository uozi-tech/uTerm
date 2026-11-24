import XCTest
@testable import uTerm

/// Code 标签页新开会话前选目录：候选目录（排序、去重、上限、主目录、当前目录在前）、主目录缩写、上一次用的工具、
/// 手输路径的展开与核对（经假的文件通道），以及 `CodeTabModel` 的起始页（「＋」→ 起始页、选目录写回、在选的目录里起、
/// 起始页上点记录、目录不知道的标签页选了目录就能起）。数据全是手写的假数据，终端是假的。
@MainActor
final class CodeTabNewSessionTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session
    private typealias Places = AgentHistoryNewSessionPlaces

    private static let home = "/home/deploy"
    private static let shop = "/home/deploy/shop-api"
    private static let infra = "/home/deploy/infra"
    private static let blog = "/home/deploy/blog"

    private final class FakeTerminal: CodeTabTerminal {
        let id = UUID()
        let directory: String
        private(set) var command: String?
        var codeCommandHasEnded = false
        init(directory: String) { self.directory = directory }
        func runCodeCommand(_ command: String) { self.command = command }
        func dispose() {}
    }

    private var made: [FakeTerminal] = []

    private func session(_ id: String, in directory: String, ago seconds: TimeInterval,
                         tool: AgentHistoryTool = .claude) -> Session {
        Session(id: id, projectID: tool == .claude ? ClaudeProjectPath.encode(directory) : "p-\(id)",
                projectDirectory: tool == .claude ? nil : directory, resumeDirectory: directory, title: id,
                modifiedAt: Date().addingTimeInterval(-seconds))
    }

    private func history(_ sessions: [Session], tools: [AgentHistoryTool] = [.claude]) async -> AgentHistoryModel {
        let sources: [any AgentHistorySource] = tools.map { tool in
            AgentHistoryFakeSource(tool: tool, sessions: sessions.filter { $0.projectID.hasPrefix("p-") == (tool != .claude) })
        }
        let source: any AgentHistorySource = sources.count == 1 ? sources[0] : AgentHistoryCompositeSource(sources)
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(10)) }
        return history
    }

    private func code(directory: String?, history: AgentHistoryModel, provider: (any SFTPProviding)? = nil,
                      recent: [String] = []) -> CodeTabModel {
        let code = CodeTabModel(hostName: "prod-web-01", directory: directory, recentDirectories: { recent }) {
            [unowned self] directory in
            let terminal = FakeTerminal(directory: directory)
            made.append(terminal)
            return terminal
        }
        code.install(AgentHistoryConnection(history: history, provider: provider, home: Self.home))
        return code
    }

    // MARK: 候选目录

    func testCandidatesPutTheCurrentDirectoryFirstThenProjectsByRecencyThenRecentThenHome() async {
        let history = await history([
            session("old", in: Self.blog, ago: 86_400 * 9),
            session("new", in: Self.infra, ago: 60),
            session("mid", in: Self.shop, ago: 3600),
            session("again", in: Self.blog, ago: 30),   // 同一个项目最近一次更新的那份决定它的位置
        ])
        let list = Places.candidates(current: Self.shop, files: history.files, metadata: history.metadata,
                                     recent: ["/Users/demo/notes", Self.infra + "/"], home: Self.home)
        XCTAssertEqual(list, [Self.shop, Self.blog, Self.infra, "/Users/demo/notes", Self.home],
                       "当前目录在前；项目按最近一次更新；重复的（含末尾的 /）只留一次；主目录最后")
    }

    func testCandidatesKeepHomeWithinTheLimitAndSkipRecordsWithoutADirectory() async {
        var sessions = (0..<14).map { session("s\($0)", in: "/srv/p\($0)", ago: TimeInterval($0) * 60) }
        // 读不到目录的记录（Claude 的项目名换不回路径、记录里也没有 cwd）不算。
        sessions.append(Session(id: "nodir", projectID: "-weird-name", title: "x", modifiedAt: Date()))
        let history = await history(sessions)
        let list = Places.candidates(current: nil, files: history.files, metadata: history.metadata, home: Self.home)
        XCTAssertEqual(list.count, Places.limit)
        XCTAssertEqual(list.last, Self.home, "名额满了也留主目录")
        XCTAssertEqual(list.first, "/srv/p0")
        XCTAssertFalse(list.contains { $0.contains("weird") })

        let homeAlready = Places.candidates(current: Self.home, files: [], metadata: [:], home: Self.home + "/")
        XCTAssertEqual(homeAlready, [Self.home], "主目录只出一次")
        XCTAssertEqual(Places.candidates(current: "relative/x", files: [], metadata: [:], home: nil), [],
                       "不是绝对路径的不收；不知道主目录就没有那一项")
    }

    func testDisplayPathAndPreferredTool() {
        XCTAssertEqual(Places.displayPath(Self.shop, home: Self.home), "~/shop-api")
        XCTAssertEqual(Places.displayPath(Self.home, home: Self.home + "/"), "~")
        XCTAssertEqual(Places.displayPath("/home/deployer", home: Self.home), "/home/deployer", "前缀相同不算在主目录里")
        XCTAssertEqual(Places.displayPath(Self.shop, home: nil), Self.shop)

        XCTAssertEqual(Places.preferredTool(stored: "codex", among: [.claude, .codex]), .codex, "上一次用的")
        XCTAssertEqual(Places.preferredTool(stored: "cursor", among: [.claude, .codex]), .claude, "上一次的开不了：第一种")
        XCTAssertEqual(Places.preferredTool(stored: nil, among: [.codex]), .codex)
        XCTAssertNil(Places.preferredTool(stored: "claude", among: []))
    }

    // MARK: 手输路径

    func testTypedPathExpandsHomeAndChecksItOnTheHost() async {
        typealias Input = AgentHistoryDirectoryInput
        XCTAssertEqual(Input.resolve("  ~/shop-api/ ", home: Self.home), .success(Self.shop))
        XCTAssertEqual(Input.resolve("~", home: Self.home), .success(Self.home))
        XCTAssertEqual(Input.resolve("/srv/./a/../b", home: nil), .success("/srv/b"))
        XCTAssertEqual(Input.resolve("", home: Self.home), .failure(.empty))
        XCTAssertEqual(Input.resolve("shop-api", home: Self.home), .failure(.notAbsolute))
        XCTAssertEqual(Input.resolve("~root/x", home: Self.home), .failure(.notAbsolute), "别人的主目录不认")
        XCTAssertEqual(Input.resolve("~/x", home: nil), .failure(.unknownHome))

        let sftp = MockSFTP()
        await sftp.setFile(Self.shop, data: Data(), mtime: Date())
        await sftp.setStatPermissions(Self.shop, 0o040755)
        await sftp.setFile(Self.shop + "/README.md", data: Data("x".utf8), mtime: Date())
        await sftp.setStatPermissions(Self.shop + "/README.md", 0o100644)
        let ok = await Input.check("~/shop-api", home: Self.home, provider: sftp)
        XCTAssertEqual(ok, .success(Self.shop), "存在、是目录")
        let file = await Input.check("~/shop-api/README.md", home: Self.home, provider: sftp)
        XCTAssertEqual(file, .failure(.notDirectory(Self.shop + "/README.md")))
        let missing = await Input.check("/srv/nope", home: Self.home, provider: sftp)
        XCTAssertEqual(missing, .failure(.missing("/srv/nope")))
        // 还不知道主目录：先问主机（假通道的主目录是 /home/user）。
        await sftp.setFile("/home/user/app", data: Data(), mtime: Date())
        await sftp.setStatPermissions("/home/user/app", 0o040700)
        let asked = await Input.check("~/app", home: nil, provider: sftp)
        XCTAssertEqual(asked, .success("/home/user/app"))
    }

    func testPathEntryKeepsTheProblemUntilTheTextChanges() async {
        let history = await history([])
        let sftp = MockSFTP()
        await sftp.setFile(Self.infra, data: Data(), mtime: Date())
        await sftp.setStatPermissions(Self.infra, 0o040755)
        let connection = AgentHistoryConnection(history: history, provider: sftp, home: Self.home)
        let entry = AgentHistoryPathEntry(text: "~/nope")
        let failed = await entry.submit(using: connection)
        XCTAssertNil(failed, "不存在：面板不关")
        XCTAssertEqual(entry.problem, .missing(Self.home + "/nope"))
        XCTAssertEqual(entry.message, AgentHistoryText.directoryProblem(.missing(Self.home + "/nope")))
        entry.text = "~/infra"
        XCTAssertNil(entry.problem, "改了字就不再显示上一次的说明")
        let path = await entry.submit(using: connection)
        XCTAssertEqual(path, Self.infra)
    }

    // MARK: CodeTabModel 的起始页

    func testPlusShowsTheStartPageAndClickingARecordStillOpensIt() async throws {
        let history = await history([session("a", in: Self.shop, ago: 60)])
        let code = code(directory: Self.shop, history: history)
        XCTAssertEqual(code.detail, .empty, "刚打开：起始页")

        let a = try XCTUnwrap(history.files.first)
        history.select(a)
        XCTAssertEqual(code.detail, .transcript)
        code.sidebarOverlayShown = true
        code.showNewSessionPage()
        XCTAssertEqual(code.detail, .empty, "「＋」：清掉列表的选中，右边换成起始页")
        XCTAssertNil(history.selectedFile)
        XCTAssertFalse(code.sidebarOverlayShown, "窄的时候盖着的侧栏收回去")
        XCTAssertTrue(made.isEmpty, "「＋」不直接起会话")

        history.select(a)
        code.historySelectionChanged()
        XCTAssertEqual(code.detail, .transcript, "起始页开着时点列表里的一行照常看那份记录")

        // 跑着一个会话时点「＋」：会话照跑，右边换成起始页。
        let run = try XCTUnwrap(code.resume(a))
        XCTAssertEqual(code.detail, .terminal(run.id))
        code.showNewSessionPage()
        XCTAssertEqual(code.detail, .empty)
        XCTAssertEqual(code.runs.count, 1)
        code.selectRun(run.id)
        XCTAssertEqual(code.detail, .terminal(run.id), "点回去还是它的终端")
    }

    func testChoosingADirectoryWritesItBackAndStartsThere() async throws {
        let history = await history([session("a", in: Self.shop, ago: 60), session("b", in: Self.infra, ago: 600)])
        let code = code(directory: Self.shop, history: history, recent: ["/Users/demo/notes"])
        XCTAssertEqual(code.newSessionDirectoryChoices, [Self.shop, Self.infra, "/Users/demo/notes", Self.home])

        code.chooseNewSessionDirectory(Self.infra + "/")
        XCTAssertEqual(code.newSessionDirectory, Self.infra, "写回（规整过）")
        XCTAssertEqual(code.record(id: UUID()).directory, Self.infra, "随布局存着")
        XCTAssertEqual(code.newSessionDirectoryChoices.first, Self.infra, "选的排第一")

        let run = try XCTUnwrap(code.startNewSession(tool: .claude, in: Self.infra))
        XCTAssertEqual(made.last?.directory, Self.infra, "在选的目录里起")
        XCTAssertEqual(made.last?.command, "cd -- '\(Self.infra)' && claude")
        XCTAssertEqual(code.detail, .terminal(run.id), "之后同原来的新会话：右边换成它的终端")
        XCTAssertEqual(code.unlistedRuns(shown: Set(history.files.map(\.path))).map(\.id), [run.id],
                       "侧栏顶上出「新会话」那一行")

        XCTAssertNil(code.startNewSession(tool: .codex, in: Self.infra), "这台主机上没有这种工具：起不了")
    }

    func testTabWithoutADirectoryCanStartOnceOneIsChosen() async throws {
        let history = await history([session("a", in: Self.shop, ago: 60)])
        let code = code(directory: nil, history: history)
        XCTAssertEqual(history.newSessionTools(directory: code.newSessionDirectory), [], "目录不知道：开始不了")
        XCTAssertEqual(AgentHistoryText.newSessionBlockedReason(directory: nil, tools: []),
                       AgentHistoryText.newSessionBlockedReason(directory: nil, tools: [.claude]), "说明是「先选一个目录」")
        XCTAssertEqual(code.newSessionDirectoryChoices, [Self.shop, Self.home], "没有当前目录：记录的项目、主目录")

        code.chooseNewSessionDirectory(Self.home)
        XCTAssertEqual(history.newSessionTools(directory: code.newSessionDirectory), [.claude])
        XCTAssertNil(AgentHistoryText.newSessionBlockedReason(directory: Self.home, tools: [.claude]))
        XCTAssertNotNil(code.startNewSession(tool: .claude, in: Self.home))
        XCTAssertEqual(made.last?.directory, Self.home)
    }

    func testStartTitleNamesTheOnlyTool() {
        XCTAssertEqual(AgentHistoryText.newSessionStartTitle(tool: .codex, toolCount: 1),
                       String(localized: "用 \(AgentHistoryTool.codex.displayName) 开始"))
        XCTAssertEqual(AgentHistoryText.newSessionStartTitle(tool: .codex, toolCount: 2), String(localized: "开始"))
        XCTAssertEqual(AgentHistoryText.newSessionStartTitle(tool: nil, toolCount: 0), String(localized: "开始"))
    }

    func testLocalShellWindowCodeTabPicksFoldersLocallyAndSSHTypesPaths() throws {
        let model = LocalShellWindowModel(startShell: { _ in })
        let local = try XCTUnwrap(model.groups.tab(model.openCodeTab(directory: "/Users/demo"))?.payload.codeTab)
        XCTAssertEqual(local.directoryChooser, .localFolder)
        let workspace = WorkspaceModel()
        let codeID = workspace.openCodeTab(serverID: UUID(), hostName: "h", directory: nil)
        XCTAssertEqual(workspace.terminalGroups.tab(codeID)?.payload.codeTab?.directoryChooser, .typedPath)
        model.disposeAll()
        workspace.dispose()
    }
}
