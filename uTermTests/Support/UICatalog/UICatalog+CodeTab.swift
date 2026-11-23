import Foundation
import SwiftUI
import UPaneGroups
@testable import uTerm

/// Code 标签页：左边一直在的会话侧栏（分组、工具标记、顶上「正在运行」），右边看记录或者跑着的那个会话的终端。
/// 数据是内存里的假数据源（`AgentHistoryFakeSource`），Claude Code 与 Codex 混排，内容全是手写的；终端接假后端，喂写好的输出。
@MainActor
extension UICatalog {
    static var codeTab: [UICatalogEntry] {
        let src = "uTerm/Features/ClaudeHistory/Views/CodeTabView.swift"
        let local = "uTerm/Features/LocalShell/LocalShellWindow.swift"
        let size = CGSize(width: 1180, height: 740)
        let localSize = CGSize(width: 1100, height: 700)
        return [
            // 按项目分组：同一个目录下 Claude Code 与 Codex 的会话在一组里，每一行前面是工具标记。
            // 另一个会话在这个标签页里跑着：侧栏顶上「正在运行」一组，列表里那一行标着「运行中」。
            UICatalogEntry("终端窗口/Code 标签页", source: src, symbol: "CodeTabView", size: size) { stage in
                try await codeTabRender(stage, .init(running: ["x-tests"]))
            },
            // 选中的就是跑着的那个：右边是它的终端，顶上「终端 / 记录」。
            UICatalogEntry("终端窗口/Code 标签页_活终端", source: src, symbol: "CodeTabView", size: size,
                           live: true) { stage in
                try await codeTabRender(stage, .init(running: ["c-login", "x-tests"], showsRun: "c-login"))
            },
            // 还没对上记录的新会话：「正在运行」里一行「新会话」，右边是它的终端。
            UICatalogEntry("终端窗口/Code 标签页_新会话", source: src, symbol: "CodeTabModel", size: size,
                           live: true) { stage in
                try await codeTabRender(stage, .init(selects: false, newSession: true))
            },
            UICatalogEntry("终端窗口/Code 标签页_按工具分组", source: src, symbol: "AgentHistorySessionList", size: size) { stage in
                try await codeTabRender(stage, .init(grouping: .tool))
            },
            // 这台主机上只有 Claude Code：不出工具标记、「工具」分组和「显示」。
            UICatalogEntry("终端窗口/Code 标签页_只有一种工具", source: src, symbol: "CodeTabView", size: size) { stage in
                try await codeTabRender(stage, .init(fixtures: .init(tools: [.claude])))
            },
            UICatalogEntry("终端窗口/Code 标签页_没选会话", source: src, symbol: "CodeTabView", size: size) { stage in
                try await codeTabRender(stage, .init(selects: false))
            },
            // 搜「订单」：Codex 那一种假设不能在主机上搜，结果上方说一句。
            UICatalogEntry("终端窗口/Code 标签页_搜索结果", source: src, symbol: "AgentHistorySearchResults", size: size) { stage in
                try await codeTabRender(stage, .init(fixtures: .init(search: "订单", codexSearches: false)))
            },
            UICatalogEntry("终端窗口/Code 标签页_最小窗口", source: src, symbol: "CodeTabView",
                           size: CGSize(width: 760, height: 480)) { stage in
                try await codeTabRender(stage, .init(running: ["x-tests"]))
            },
            UICatalogEntry("终端窗口/Code 标签页_侧栏收起", source: src, symbol: "CodeTabRail", size: size,
                           live: true) { stage in
                try await codeTabRender(stage, .init(running: ["c-login"], showsRun: "c-login", sidebarHidden: true))
            },
            // 本机终端窗口：列这台 Mac 上的记录，右边的终端是本机 shell。
            UICatalogEntry("本机终端/Code 标签页", source: local, symbol: "LocalShellTerminalArea", size: localSize) { stage in
                try await localCodeTabRender(stage, .init(running: ["x-tests"]))
            },
            UICatalogEntry("本机终端/Code 标签页_活终端", source: local, symbol: "LocalShellTerminalArea", size: localSize,
                           live: true) { stage in
                try await localCodeTabRender(stage, .init(running: ["c-login"], showsRun: "c-login"))
            },
            UICatalogEntry("本机终端/Code 标签页_没选会话", source: local, symbol: "LocalShellTerminalArea", size: localSize) { stage in
                try await localCodeTabRender(stage, .init(selects: false))
            },
            // 本机终端窗口的最小尺寸：侧栏收成一条窄轨（带着在跑的个数），点开盖在右边上面。
            UICatalogEntry("本机终端/Code 标签页_最小窗口", source: src, symbol: "CodeTabRail",
                           size: CGSize(width: 560, height: 360), live: true) { stage in
                try await localCodeTabRender(stage, .init(running: ["c-login"], showsRun: "c-login"))
            },
            UICatalogEntry("本机终端/Code 标签页_最小窗口_侧栏展开", source: src, symbol: "CodeTabBrowser",
                           size: CGSize(width: 560, height: 360), live: true) { stage in
                try await localCodeTabRender(stage, .init(running: ["c-login"], showsRun: "c-login", overlay: true))
            },
            // 独立的历史会话窗口（配对的 Mac 从标签页右键打开）：同一套列表与对话。
            UICatalogEntry("历史会话/多种工具", source: "uTerm/Features/ClaudeHistory/Views/ClaudeHistoryWindow.swift",
                           symbol: "ClaudeHistoryWindowView", size: CGSize(width: 1100, height: 720)) { stage in
                let s = try stage.session()
                let server = s.host("prod-web-01")
                let history = await UICatalogCodeMode.model(.init())
                let windowID = ClaudeHistoryWindowID(host: .server(server.id), directory: UICatalogCodeMode.shop)
                let window = ClaudeHistoryWindowModel(windowID: windowID, hostName: server.name, history: history)
                return UICatalogRender(s.wrap(ClaudeHistoryWindowView(windowID: windowID, catalogModel: window)))
            },
        ]
    }

    struct CodeTabSetup {
        var fixtures = UICatalogCodeMode.Setup()
        var grouping: AgentHistoryGrouping = .project
        var selects = true
        /// 在这个标签页里跑着的会话（会话 ID）。
        var running: [String] = []
        /// 右边显示这个跑着的会话的终端。
        var showsRun: String?
        /// 起一个还没对上记录的新会话，右边显示它。
        var newSession = false
        var sidebarHidden = false
        var overlay = false
    }

    /// SSH 终端窗口：一个终端标签页 + 一个 Code 标签页（前台）。
    static func codeTabRender(_ stage: UICatalogStage, _ setup: CodeTabSetup) async throws -> UICatalogRender {
        let s = try stage.session()
        let server = s.host("prod-web-01")
        s.defaults.set(setup.grouping.rawValue, forKey: DefaultsKey.agentHistoryGrouping)
        let workspace = WorkspaceModel()
        workspace.bindDefaultServer(id: server.id, title: server.name)
        workspace.openServer(profileID: server.id, title: server.name)
        for pane in workspace.terminalPanes {
            pane.session.attentionSink = { _ in }
            await pane.session.connect(using: MockBackend())
        }
        let codeID = workspace.openCodeTab(serverID: server.id, hostName: server.name, directory: UICatalogCodeMode.shop)
        guard let code = workspace.terminalGroups.tab(codeID)?.payload.codeTab else { throw CancellationError() }
        let terminals = await prepare(code, setup, fixtures: setup.fixtures)
        let view = s.wrap(TerminalWindowView(windowID: TerminalWindowID(id: UUID(), serverID: server.id),
                                             catalogModel: workspace))
        return UICatalogRender(view, after: { _ in
            await feed(terminals)
        }, cleanup: {
            workspace.dispose()
        })
    }

    /// 本机终端窗口：一个 shell 标签 + 一个 Code 标签页（前台）。
    static func localCodeTabRender(_ stage: UICatalogStage, _ setup: CodeTabSetup) async throws -> UICatalogRender {
        let s = try stage.session()
        s.defaults.set(setup.grouping.rawValue, forKey: DefaultsKey.agentHistoryGrouping)
        let model = LocalShellWindowModel(startShell: { _ in })
        model.addTab(directory: UICatalogCodeMode.localShop)
        for pane in model.panes {
            pane.session.attentionSink = { _ in }
            await pane.session.connect(using: MockBackend())
        }
        let codeID = model.openCodeTab(directory: UICatalogCodeMode.localShop)
        guard let code = model.groups.tab(codeID)?.payload.codeTab else { throw CancellationError() }
        var fixtures = setup.fixtures
        fixtures.root = UICatalogCodeMode.localRoot
        let terminals = await prepare(code, setup, fixtures: fixtures)
        let view = s.wrap(LocalShellWindowView(windowID: LocalShellWindowID(id: UUID()), catalogModel: model))
        return UICatalogRender(view, after: { _ in
            await feed(terminals)
        }, cleanup: {
            model.disposeAll()
        })
    }

    /// 装上假数据的连接，起好跑着的会话（终端接假后端），选好右边显示什么。返回要喂输出的终端。
    private static func prepare(_ code: CodeTabModel, _ setup: CodeTabSetup,
                                fixtures: UICatalogCodeMode.Setup) async -> [(TerminalSession, String)] {
        var fixtures = fixtures
        fixtures.selects = setup.selects && setup.showsRun == nil && !setup.newSession
        let history = await UICatalogCodeMode.model(fixtures)
        code.install(AgentHistoryConnection(history: history))
        code.sidebarHidden = setup.sidebarHidden
        code.sidebarOverlayShown = setup.overlay
        var terminals: [(TerminalSession, String)] = []
        let selected = history.selectedFile
        for id in setup.running {
            guard let file = history.files.first(where: { $0.sessionID == id }), let run = code.resume(file) else { continue }
            if let session = session(of: run.terminal) { terminals.append((session, UICatalogTerminalScripts.claude)) }
        }
        if setup.newSession, let directory = code.newSessionDirectory,
           let run = code.startNewSession(tool: .claude, command: "claude", directory: directory) {
            if let session = session(of: run.terminal) { terminals.append((session, UICatalogTerminalScripts.claude)) }
        }
        // 继续会把右边换成那个会话：要看的不是它就选回去。
        if let id = setup.showsRun, let file = history.files.first(where: { $0.sessionID == id }) {
            history.select(file)
        } else if !setup.newSession {
            history.select(selected)
            for _ in 0..<100 where selected != nil && history.transcript?.reachedStart != true {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        for (session, _) in terminals {
            session.attentionSink = { _ in }
            await session.connect(using: MockBackend())
        }
        return terminals
    }

    private static func session(of terminal: any CodeTabTerminal) -> TerminalSession? {
        (terminal as? PaneModel)?.session ?? (terminal as? LocalShellPane)?.session
    }

    /// 尺寸停稳之后再喂：影子终端按真实列数排版。
    private static func feed(_ terminals: [(TerminalSession, String)]) async {
        try? await Task.sleep(for: .milliseconds(400))
        for (session, script) in terminals { session.feedOutput(text: script) }
        try? await Task.sleep(for: .milliseconds(300))
    }
}

@MainActor
enum UICatalogCodeMode {
    struct Setup {
        var grouping: AgentHistoryGrouping = .project
        var tools: [AgentHistoryTool] = [.claude, .codex]
        var selects = true
        var search: String?
        var codexSearches = true
        /// 记录里的项目都在这个目录下（SSH 主机是 `/home/deploy`，本机是一个假的用户目录）。
        var root = UICatalogCodeMode.sshRoot
    }

    nonisolated static let sshRoot = "/home/deploy"
    nonisolated static let localRoot = "/Users/demo/code"
    static var shop: String { sshRoot + "/shop-api" }
    static var localShop: String { localRoot + "/shop-api" }

    private typealias Session = AgentHistoryFakeSource.Session

    static func model(_ setup: Setup) async -> AgentHistoryModel {
        let shop = setup.root + "/shop-api", infra = setup.root + "/infra"
        let blog = setup.root + "/blog", dotfiles = setup.root + "/dotfiles"
        let now = UICatalogFixtures.now
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let claude = AgentHistoryFakeSource(tool: .claude, sessions: [
            Session(id: "c-login", projectID: ClaudeProjectPath.encode(shop), resumeDirectory: shop,
                    title: "登录接口偶发 500", modifiedAt: ago(60 * 4), branch: "fix/login-timeout",
                    items: conversation(at: ago(60 * 4)),
                    hits: [AgentHistoryFakeSource.hit("c-login.u2", before: "顺便看看", match: "订单", after: "列表的慢查询")]),
            Session(id: "c-page", projectID: ClaudeProjectPath.encode(shop), resumeDirectory: shop,
                    title: "给订单接口加分页", modifiedAt: ago(86_400 * 3 + 600), branch: "feat/paging",
                    hits: [AgentHistoryFakeSource.hit("c-page.u", before: "", match: "订单", after: "列表接口加上分页参数"),
                           AgentHistoryFakeSource.hit("c-page.a", before: "已经给", match: "订单", after: "列表加了 page 与 size",
                                                      role: .assistant)]),
            Session(id: "c-nginx", projectID: ClaudeProjectPath.encode(infra), resumeDirectory: infra,
                    title: "升级 nginx 到 1.27", modifiedAt: ago(86_400 + 3600 * 2), branch: "main"),
            Session(id: "c-blog", projectID: ClaudeProjectPath.encode(blog), resumeDirectory: blog,
                    title: "改首页的字体", modifiedAt: ago(86_400 * 12), branch: nil),
            Session(id: "c-dots", projectID: ClaudeProjectPath.encode(dotfiles), resumeDirectory: dotfiles,
                    title: "整理 zsh 配置", modifiedAt: ago(86_400 * 45), branch: "main"),
        ])
        let codex = AgentHistoryFakeSource(tool: .codex, sessions: [
            Session(id: "x-tests", projectID: "2026-11-20", projectDirectory: shop, resumeDirectory: shop,
                    title: "订单服务测试与慢查询", modifiedAt: ago(3600 * 2), branch: "main",
                    hits: [AgentHistoryFakeSource.hit("x-tests.u", before: "给", match: "订单", after: "服务补上集成测试")]),
            Session(id: "x-502", projectID: "2026-11-18", projectDirectory: shop, resumeDirectory: shop,
                    title: "排查 502", modifiedAt: ago(86_400 * 5), branch: "main"),
            Session(id: "x-cert", projectID: "2026-11-15", projectDirectory: infra, resumeDirectory: infra,
                    title: "证书续期脚本", modifiedAt: ago(86_400 * 8), branch: nil),
        ], supportsSearch: setup.codexSearches)
        let sources: [any AgentHistorySource] = setup.tools.compactMap { tool in
            switch tool {
            case .claude: return claude
            case .codex: return codex
            default: return nil
            }
        }
        let source: any AgentHistorySource = sources.count == 1 ? sources[0] : AgentHistoryCompositeSource(sources)
        let history = AgentHistoryModel(source: source, preferredDirectory: shop, followsCurrentProject: false)
        await history.start()
        for _ in 0..<100 where history.hasMore || history.isListing {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if let query = setup.search {
            history.searchText = query
            history.submitSearch()
            for _ in 0..<200 where history.search?.isRunning == true {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        if setup.selects, let first = history.visibleFiles.first {
            history.select(first)
            for _ in 0..<100 where history.transcript?.reachedStart != true {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        return history
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
}
