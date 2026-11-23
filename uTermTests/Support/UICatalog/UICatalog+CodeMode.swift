import Foundation
import SwiftUI
@testable import uTerm

/// 终端窗口的「Code」模式：左边一直在的历史会话列表（可分组），右边选中会话的对话。
/// 数据是内存里的假数据源（`AgentHistoryFakeSource`），Claude Code 与 Codex 混排，内容全是手写的。
@MainActor
extension UICatalog {
    static var codeMode: [UICatalogEntry] {
        let src = "uTerm/Features/ClaudeHistory/Views/CodeModeView.swift"
        let size = CGSize(width: 1180, height: 740)
        return [
            // 按项目分组：同一个目录下 Claude Code 与 Codex 的会话在一组里，每一行前面是工具标记。
            UICatalogEntry("终端窗口/Code 模式", source: src, symbol: "CodeModeView", size: size) { stage in
                try await codeModeRender(stage, .init())
            },
            UICatalogEntry("终端窗口/Code 模式_按工具分组", source: src, symbol: "AgentHistorySessionList", size: size) { stage in
                try await codeModeRender(stage, .init(grouping: .tool))
            },
            UICatalogEntry("终端窗口/Code 模式_按日期分组", source: src, symbol: "AgentHistorySessionList", size: size) { stage in
                try await codeModeRender(stage, .init(grouping: .date))
            },
            // 这台主机上只有 Claude Code：不出工具标记、「工具」分组和「显示」。
            UICatalogEntry("终端窗口/Code 模式_只有一种工具", source: src, symbol: "CodeModeView", size: size) { stage in
                try await codeModeRender(stage, .init(tools: [.claude]))
            },
            UICatalogEntry("终端窗口/Code 模式_没选会话", source: src, symbol: "CodeModeView", size: size) { stage in
                try await codeModeRender(stage, .init(selects: false))
            },
            // 搜「订单」：Codex 那一种假设不能在主机上搜，结果上方说一句。
            UICatalogEntry("终端窗口/Code 模式_搜索结果", source: src, symbol: "AgentHistorySearchResults", size: size) { stage in
                try await codeModeRender(stage, .init(search: "订单", codexSearches: false))
            },
            UICatalogEntry("终端窗口/Code 模式_最小窗口", source: src, symbol: "CodeModeView",
                           size: CGSize(width: 760, height: 480)) { stage in
                try await codeModeRender(stage, .init())
            },
            UICatalogEntry("终端窗口/Code 模式_没有终端标签页", source: src, symbol: "CodeModeView", size: size) { stage in
                try await codeModeRender(stage, .init(opensTab: false))
            },
            // 独立的历史会话窗口（工作区、本机终端、配对的 Mac 从标签页右键打开）：同一个列表组件。
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

    static func codeModeRender(_ stage: UICatalogStage, _ setup: UICatalogCodeMode.Setup) async throws -> UICatalogRender {
        let s = try stage.session()
        let server = s.host("prod-web-01")
        s.defaults.set(setup.grouping.rawValue, forKey: DefaultsKey.agentHistoryGrouping)
        let workspace = WorkspaceModel()
        workspace.bindDefaultServer(id: server.id, title: server.name)
        if setup.opensTab {
            workspace.openServer(profileID: server.id, title: server.name)
            for pane in workspace.terminalGroups.allTabs.map(\.payload) {
                pane.session.attentionSink = { _ in }
                await pane.session.connect(using: MockBackend())
            }
        }
        let code = CodeModeModel()
        let history = await UICatalogCodeMode.model(setup)
        code.install(AgentHistoryConnection(history: history), for: server.id)
        let view = s.wrap(TerminalWindowView(windowID: TerminalWindowID(id: UUID(), serverID: server.id),
                                             catalogModel: workspace, catalogMode: .code, catalogCode: code))
        return UICatalogRender(view, after: { _ in
            try? await Task.sleep(for: .milliseconds(300))
        }, cleanup: {
            workspace.dispose()
        })
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
        var opensTab = true
    }

    static let shop = "/home/deploy/shop-api"
    private static let infra = "/home/deploy/infra"
    private static let blog = "/home/deploy/blog"
    private static let dotfiles = "/home/deploy/dotfiles"

    private typealias Session = AgentHistoryFakeSource.Session

    static func model(_ setup: Setup) async -> AgentHistoryModel {
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
