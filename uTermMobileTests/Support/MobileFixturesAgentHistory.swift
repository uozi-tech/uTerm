import Foundation
@testable import uTermMobile

/// 内存里的假数据源，`tool` 可指定：在用例和截图里看几种编码工具混排。内容全是手写的（仓库是公开的，
/// 这里绝不能放真实的对话、路径、账号、会话 ID）。照 Mac 测试里的 `AgentHistoryFakeSource` 写（两个测试 target 不共用源码）。
///
/// 项目放在 `/fake/<工具>/<记录目录名>`，会话文件是 `<项目>/<会话 ID>.jsonl`（只是个路径，不读文件）。
actor MobileFakeAgentSource: AgentHistorySource {
    struct Session {
        var id: String
        /// 记录目录的名字（Claude Code 是工作目录换出来的那个）。
        var projectID: String
        /// 数据源放在项目上的真实工作目录（Codex 这类直接有；Claude Code 没有，为 nil）。
        var projectDirectory: String?
        /// 会话信息里「该在哪个目录继续」。
        var resumeDirectory: String?
        var title: String?
        var modifiedAt: Date
        var size: UInt64 = 18 * 1024
        var branch: String? = "main"
        var items: [AgentTranscriptItem] = []
        /// 搜索时报的命中。
        var hits: [AgentHistorySearchHit] = []
    }

    nonisolated let tool: AgentHistoryTool
    nonisolated let supportsSearch: Bool
    private var sessionList: [Session]
    /// 列项目时抛的错（看「某种工具的记录读不出来」那一句）。
    private let projectsError: (any Error)?

    init(tool: AgentHistoryTool, sessions: [Session], supportsSearch: Bool = true, projectsError: (any Error)? = nil) {
        self.tool = tool
        sessionList = sessions
        self.supportsSearch = supportsSearch
        self.projectsError = projectsError
    }

    /// 主机上新写出一份记录（新会话起来之后）。
    func add(_ session: Session) { sessionList.append(session) }

    nonisolated func projectPath(_ id: String) -> String { "/fake/\(tool.rawValue)/\(id)" }
    nonisolated func sessionPath(_ session: Session) -> String { projectPath(session.projectID) + "/\(session.id).jsonl" }

    private func makeProject(_ id: String) -> AgentHistoryProject {
        let members = sessionList.filter { $0.projectID == id }
        return AgentHistoryProject(id: id, path: projectPath(id), modifiedAt: members.map(\.modifiedAt).max(),
                                   directory: members.first?.projectDirectory, tool: tool)
    }

    func projects() async throws -> [AgentHistoryProject] {
        if let projectsError { throw projectsError }
        var seen: Set<String> = []
        return sessionList.map(\.projectID).filter { seen.insert($0).inserted }.map(makeProject)
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    func project(containing directory: String, among projects: [AgentHistoryProject]) -> AgentHistoryProject? {
        for candidate in ClaudeProjectPath.lineage(of: directory) {
            if let hit = projects.first(where: { $0.directory == candidate }) { return hit }
        }
        return nil
    }

    private func file(_ session: Session) -> AgentHistorySessionFile {
        AgentHistorySessionFile(sessionID: session.id, project: makeProject(session.projectID), path: sessionPath(session),
                                size: session.size, modifiedAt: session.modifiedAt)
    }

    func sessions(in project: AgentHistoryProject) async throws -> [AgentHistorySessionFile] {
        sessionList.filter { $0.projectID == project.id }.map(file).sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func allSessions(in projects: [AgentHistoryProject]) async -> [AgentHistorySessionFile] {
        let ids = Set(projects.map(\.id))
        return sessionList.filter { ids.contains($0.projectID) }.map(file).sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func session(at path: String) -> Session? {
        sessionList.first { sessionPath($0) == path }
    }

    func metadata(for file: AgentHistorySessionFile) async throws -> AgentHistorySessionMetadata {
        guard let session = session(at: file.path) else { throw MobileFakeAgentError.missing }
        return AgentHistorySessionMetadata(title: session.title, isListed: true,
                                           lastDirectory: session.resumeDirectory, resumeDirectory: session.resumeDirectory,
                                           gitBranch: session.branch, lastActivity: session.modifiedAt)
    }

    nonisolated func transcript(for file: AgentHistorySessionFile) -> any AgentTranscriptPaging {
        MobileFakeAgentPager(source: self, path: file.path)
    }

    nonisolated func transcript(for file: AgentHistorySessionFile, around anchor: AgentTranscriptAnchor) -> any AgentTranscriptPaging {
        MobileFakeAgentPager(source: self, path: file.path)
    }

    func items(at path: String) -> [AgentTranscriptItem] { session(at: path)?.items ?? [] }

    func search(_ query: AgentHistorySearchQuery, in files: [AgentHistorySessionFile], limits: AgentHistorySearchLimits,
                // 测试 target 没开 Approachable Concurrency，协议里的类型（App 里默认 nonsending）要写明。
                onEvent: nonisolated(nonsending) @escaping @Sendable (AgentHistorySearchEvent) async -> Void) async throws {
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            await onEvent(.progress(searched: index + 1, total: files.count))
            guard let session = session(at: file.path), !session.hits.isEmpty else { continue }
            let metadata = try await metadata(for: file)
            await onEvent(.session(AgentHistorySearchSession(file: file, metadata: metadata, hits: session.hits,
                                                             hasMoreHits: false)))
        }
        await onEvent(.finished(truncated: false))
    }

    nonisolated func subagentTranscript(for subagent: AgentSubagentFile) -> any AgentTranscriptPaging {
        MobileFakeAgentPager(source: self, path: subagent.path)
    }

    func subagents(of target: AgentTranscriptTarget) async throws -> [AgentSubagentFile] { [] }

    func info(of subagent: AgentSubagentFile) async -> AgentSubagentInfo? { nil }

    nonisolated func resumeCommand(sessionID: String, directory: String) -> String? {
        guard directory.hasPrefix("/") else { return nil }
        return "cd -- '\(directory)' && \(tool.rawValue) resume \(sessionID)"
    }

    nonisolated func newSessionCommand(directory: String) -> String? {
        guard directory.hasPrefix("/") else { return nil }
        return "cd -- '\(directory)' && \(tool.rawValue)"
    }
}

nonisolated enum MobileFakeAgentError: Error, LocalizedError {
    case missing
    case unreadable

    var errorDescription: String? {
        switch self {
        case .missing: return "没有这份记录"
        case .unreadable: return "数据库被锁住了"
        }
    }
}

/// 一页就读完的假对话。
actor MobileFakeAgentPager: AgentTranscriptPaging {
    let source: MobileFakeAgentSource
    let path: String
    private var done = false

    init(source: MobileFakeAgentSource, path: String) {
        self.source = source
        self.path = path
    }

    func loadPrevious() async throws -> (items: [AgentTranscriptItem], reachedStart: Bool) {
        guard !done else { return ([], true) }
        done = true
        return (await source.items(at: path), true)
    }

    func loadNewer() async throws -> AgentTranscriptGrowth { .unchanged }
}

/// 几种工具混排的一台假主机：Claude Code、Codex、Cursor 三种，`shop-api` 下三种都有，另有 `infra`、`blog`。
@MainActor
enum MobileAgentHistoryFixture {
    static let shop = "/home/user/projects/shop-api"
    static let infra = "/home/user/projects/infra"
    static let blog = "/home/user/projects/blog"

    private typealias Session = MobileFakeAgentSource.Session

    /// `tools`：这台主机上有记录的工具；`cursorSearches`：Cursor 的记录能不能在主机上搜（假设不能，看结果上方那句说明）。
    /// `antigravityFails`：再带一种列不出来的 Antigravity（列表底下那句「读不出来」）。
    static func source(tools: [AgentHistoryTool] = [.claude, .codex, .cursor], cursorSearches: Bool = false,
                       antigravityFails: Bool = false, now: Date = Date()) -> any AgentHistorySource {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let claude = MobileFakeAgentSource(tool: .claude, sessions: [
            Session(id: "c-login", projectID: ClaudeProjectPath.encode(shop), resumeDirectory: shop,
                    title: "登录接口偶发 500", modifiedAt: ago(60 * 4), branch: "fix/login-timeout",
                    items: conversation(at: ago(60 * 4)),
                    hits: [hit("c-login.u2", before: "顺便看看", match: "订单", after: "列表的慢查询")]),
            Session(id: "c-page", projectID: ClaudeProjectPath.encode(shop), resumeDirectory: shop,
                    title: "给订单接口加分页", modifiedAt: ago(86_400 * 3 + 600), branch: "feat/paging",
                    hits: [hit("c-page.u", before: "", match: "订单", after: "列表接口加上分页参数")]),
            Session(id: "c-nginx", projectID: ClaudeProjectPath.encode(infra), resumeDirectory: infra,
                    title: "升级 nginx 到 1.27", modifiedAt: ago(86_400 + 3600 * 2)),
            Session(id: "c-blog", projectID: ClaudeProjectPath.encode(blog), resumeDirectory: blog,
                    title: "改首页的字体", modifiedAt: ago(86_400 * 12), branch: nil),
        ])
        let codex = MobileFakeAgentSource(tool: .codex, sessions: [
            Session(id: "x-tests", projectID: "2026-11-20", projectDirectory: shop, resumeDirectory: shop,
                    title: "订单服务测试与慢查询", modifiedAt: ago(3600 * 2),
                    items: codexConversation(at: ago(3600 * 2)),
                    hits: [hit("x-tests.u", before: "给", match: "订单", after: "服务补上集成测试")]),
            Session(id: "x-cert", projectID: "2026-11-15", projectDirectory: infra, resumeDirectory: infra,
                    title: "证书续期脚本", modifiedAt: ago(86_400 * 8), branch: nil),
        ])
        let cursor = MobileFakeAgentSource(tool: .cursor, sessions: [
            Session(id: "u-readme", projectID: "ws-1", projectDirectory: shop, resumeDirectory: shop,
                    title: "补 README 的部署一节", modifiedAt: ago(3600 * 7)),
        ], supportsSearch: cursorSearches)
        let all: [AgentHistoryTool: any AgentHistorySource] = [.claude: claude, .codex: codex, .cursor: cursor]
        var sources = tools.compactMap { all[$0] }
        if antigravityFails {
            sources.append(MobileFakeAgentSource(tool: .antigravity, sessions: [], projectsError: MobileFakeAgentError.unreadable))
        }
        return sources.count == 1 ? sources[0] : AgentHistoryCompositeSource(sources)
    }

    /// 接着假数据源的历史标签（还没开始读），建连接的参数同 App（四种工具、一直列全部项目）。
    /// `pinDefaults`：给了就能置顶（按这台主机记，存在这份一次性的偏好里）；不给不能置顶，也不碰标准偏好。
    static func tab(host: ServerProfile, source: any AgentHistorySource, directory: String? = shop,
                    pinDefaults: UserDefaults? = nil) -> ClaudeHistoryTab {
        ClaudeHistoryTab(host: host, connection: AgentHistoryConnection(
            preferredDirectory: directory, tools: AgentHistoryTool.allCases, followsCurrentProject: false,
            makeSource: { _, _ in source },
            pinHost: { [id = host.id] in pinDefaults == nil ? nil : .server(id) }, pinDefaults: pinDefaults ?? .standard,
            connect: { _ in MobileFakeClaudeTree(home: MobileClaudeFixture.home, files: []) }))
    }

    static func hit(_ id: String, before: String, match: String, after: String,
                    role: AgentTranscriptItem.Role = .user) -> AgentHistorySearchHit {
        AgentHistorySearchHit(itemID: id, role: role, snippet: AgentHistorySnippet(before: before, match: match, after: after),
                              timestamp: nil, anchor: AgentTranscriptAnchor(lineOffset: 0, lineLength: 1))
    }

    private static func conversation(at date: Date) -> [AgentTranscriptItem] {
        let output = "--- FAIL: TestLoginTimeout (2.01s)\n    handler_test.go:88: context deadline exceeded\nFAIL"
        let call = AgentToolCall(toolUseID: "t1", name: "Bash", summary: "go test ./internal/auth/... -run TestLogin",
                                 result: AgentToolResult(toolUseID: "t1", content: AgentClippedText(output, limit: 4000),
                                                         isError: true, imageCount: 0))
        return [
            AgentTranscriptItem(id: "c-login.u1", kind: .userText("登录接口偶尔返回 500，日志里是 `context deadline exceeded`。帮我找找原因。"),
                                timestamp: date.addingTimeInterval(-600)),
            AgentTranscriptItem(id: "c-login.a1", kind: .assistantText("先看一下登录的处理函数和连接池的设置。"),
                                timestamp: date.addingTimeInterval(-590)),
            AgentTranscriptItem(id: "c-login.t1", kind: .toolCall(call), timestamp: date.addingTimeInterval(-580)),
            AgentTranscriptItem(id: "c-login.a2", kind: .assistantText("""
                原因找到了：`Login` 每次请求都新建数据库连接，连接池上限只有 **5**，高峰时排队超过 2 秒就超时。

                1. 复用 `db.Pool`，不要在 handler 里 `Open`；
                2. 把 `MaxOpenConns` 调到 20。
                """), timestamp: date.addingTimeInterval(-500)),
            AgentTranscriptItem(id: "c-login.u2", kind: .userText("按第一条改吧，顺便看看订单列表的慢查询。"),
                                timestamp: date.addingTimeInterval(-120)),
            AgentTranscriptItem(id: "c-login.a3", kind: .assistantText("改好了，`TestLoginTimeout` 现在能过。订单列表慢是因为 `orders.created_at` 没有索引。"),
                                timestamp: date),
        ]
    }

    private static func codexConversation(at date: Date) -> [AgentTranscriptItem] {
        [
            AgentTranscriptItem(id: "x-tests.u", kind: .userText("给订单服务补上集成测试：下单、取消、退款各两条。"),
                                timestamp: date.addingTimeInterval(-300)),
            AgentTranscriptItem(id: "x-tests.c", kind: .command("go test ./internal/order/..."),
                                timestamp: date.addingTimeInterval(-200)),
            AgentTranscriptItem(id: "x-tests.a", kind: .assistantText("补了 6 个用例，全部通过。"), timestamp: date),
        ]
    }
}
