import Foundation
import SwiftUI
import UPaneGroups
@testable import uTerm

/// Code 标签页：左边一直在的会话侧栏（置顶、分组；一组里混着几种工具时行上写工具名），右边看记录或者跑着的那个会话的终端。
/// 数据是内存里的假数据源（`AgentHistoryFakeSource`），Claude Code 与 Codex 混排，内容全是手写的；终端接假后端，喂写好的输出。
@MainActor
extension UICatalog {
    static var codeTab: [UICatalogEntry] {
        let src = "uTerm/Features/ClaudeHistory/Views/CodeTabView.swift"
        let page = "uTerm/Features/ClaudeHistory/Views/CodeTabNewSessionPage.swift"
        let local = "uTerm/Features/LocalShell/LocalShellWindow.swift"
        let size = CGSize(width: 1180, height: 740)
        let localSize = CGSize(width: 1100, height: 700)
        return [
            // 按项目分组：同一个目录下 Claude Code 与 Codex 的会话在一组里，行上第二行最前面写工具名；只有一种工具的组不写。
            // 另一个会话在这个标签页里跑着：就在它那一组里自己那一行上，标着它此刻的状态（没报过状态就不写），
            // 顶上没有单独一块。没有置顶：顶上不多出东西。
            UICatalogEntry("终端窗口/Code 标签页", source: src, symbol: "CodeTabView", size: size) { stage in
                try await codeTabRender(stage, .init(running: ["x-tests"], runStates: ["x-tests": "working"]))
            },
            // 选中的就是跑着的那个：右边是它的终端，顶上「终端 / 记录」。
            UICatalogEntry("终端窗口/Code 标签页_活终端", source: src, symbol: "CodeTabView", size: size,
                           live: true) { stage in
                try await codeTabRender(stage, .init(running: ["c-login", "x-tests"], showsRun: "c-login"))
            },
            // 鼠标悬在跑着的会话那几行上（各在自己那一组里）：右端一个 ×（结束会话，上下居中），盖在行上、不挤字。
            UICatalogEntry("终端窗口/Code 标签页_跑着的会话悬停", source: src, symbol: "AgentHistoryRowMoreButton", size: size,
                           live: true) { stage in
                try await codeTabRender(stage, .init(running: ["c-login", "x-tests"],
                                                     runStates: ["c-login": "idle", "x-tests": "working"],
                                                     showsRun: "c-login", hoversRuns: true))
            },
            // 看着一个仍在跑的会话的记录：记录标题行上「继续这个会话」换成「返回终端」。
            UICatalogEntry("终端窗口/Code 标签页_跑着的会话看记录", source: src, symbol: "AgentHistoryTranscriptStack",
                           size: size) { stage in
                try await codeTabRender(stage, .init(running: ["c-login"], showsRun: "c-login", showsRecord: true))
            },
            // 还没对上记录的新会话：列表最顶上一行「新会话」（带「运行中」），右边是它的终端。
            UICatalogEntry("终端窗口/Code 标签页_新会话", source: src, symbol: "CodeTabModel", size: size,
                           live: true) { stage in
                try await codeTabRender(stage, .init(selects: false, newSession: true))
            },
            // 新会话没说话就退出了（没有对话记录）：右边不跳走，终端留着最后的画面，顶上「会话已结束」与「重新开始」「关闭」；
            // 侧栏顶上那一行写「已结束」（没有记录，没有组可放）。另一个会话在跑：它在自己那一组里那一行上，不在顶上。
            UICatalogEntry("终端窗口/Code 标签页_会话已结束", source: src, symbol: "CodeTabEndedBanner", size: size,
                           live: true) { stage in
                try await codeTabRender(stage, .init(selects: false, running: ["x-tests"], runStates: ["x-tests": "working"],
                                                     newSession: true, newSessionEnded: true))
            },
            // 置顶了两个（一个 Codex、一个 Claude Code）：最上面一组「置顶」，原来那几组里不再出现；组里混着两种工具，写工具名。
            UICatalogEntry("终端窗口/Code 标签页_置顶", source: src, symbol: "AgentHistorySessionList", size: size) { stage in
                try await codeTabRender(stage, .init(fixtures: .init(pinned: ["x-502", "c-nginx"]), running: ["x-tests"]))
            },
            // 置顶了一个跑着的会话：它在「置顶」里（行上标着状态、右键 / 悬停是跑着的会话那几样），不在原来那一组、也不在顶上；
            // 另一个跑着的（右边是它的终端）在它自己那一组里。
            UICatalogEntry("终端窗口/Code 标签页_跑着的会话置顶", source: src, symbol: "AgentHistorySessionList",
                           size: size, live: true) { stage in
                try await codeTabRender(stage, .init(fixtures: .init(pinned: ["x-tests", "c-nginx"]),
                                                     running: ["x-tests", "c-login"],
                                                     runStates: ["x-tests": "idle", "c-login": "working"],
                                                     showsRun: "c-login"))
            },
            // 拖动中（拍成静态）：还没有置顶的会话时，列表顶上出一条「拖到这里置顶」，悬在上面时高亮。
            UICatalogEntry("终端窗口/Code 标签页_拖到置顶", source: src, symbol: "AgentHistoryPinDropStrip", size: size) { stage in
                try await codeTabRender(stage, .init(pinDrag: ("c-blog", .pin(index: 0))))
            },
            // 拖动中（拍成静态）：在「置顶」一组里把第一个往下拖，落点那里一条强调色的线，被拖的那一行变淡。
            UICatalogEntry("终端窗口/Code 标签页_置顶组内拖动", source: src, symbol: "AgentHistoryPinInsertionLine",
                           size: size) { stage in
                try await codeTabRender(stage, .init(fixtures: .init(pinned: ["c-page", "x-502", "c-nginx"]),
                                                     pinDrag: ("c-page", .pin(index: 2))))
            },
            UICatalogEntry("终端窗口/Code 标签页_按工具分组", source: src, symbol: "AgentHistorySessionList", size: size) { stage in
                try await codeTabRender(stage, .init(grouping: .tool))
            },
            // 这台主机上只有 Claude Code：不出工具标记、「工具」分组和「显示」。
            UICatalogEntry("终端窗口/Code 标签页_只有一种工具", source: src, symbol: "CodeTabView", size: size) { stage in
                try await codeTabRender(stage, .init(fixtures: .init(tools: [.claude])))
            },
            // 什么都没选：右边是「新会话」起始页（目录选择器、几种工具可选、开始）。
            UICatalogEntry("终端窗口/Code 标签页_新会话起始页", source: page, symbol: "CodeTabNewSessionPage",
                           size: size) { stage in
                try await codeTabRender(stage, .init(selects: false))
            },
            // 只有一种工具：不出工具选择，开始按钮上写明是哪种。
            UICatalogEntry("终端窗口/Code 标签页_新会话起始页_一种工具", source: page, symbol: "CodeTabNewSessionPage",
                           size: size) { stage in
                try await codeTabRender(stage, .init(fixtures: .init(tools: [.claude]), selects: false))
            },
            // 打开它的终端不知道目录（没有 OSC 7）：目录选择器上写「选择一个目录」，开始按钮灰着、下面说明。
            UICatalogEntry("终端窗口/Code 标签页_新会话起始页_没有目录", source: page, symbol: "CodeTabNewSessionPage",
                           size: size) { stage in
                try await codeTabRender(stage, .init(selects: false, directory: .some(nil)))
            },
            // SSH 主机上「选择文件夹…」：输入路径的小面板，核对不过的那一句。
            UICatalogEntry("终端窗口/Code 标签页_输入路径", source: page, symbol: "CodeTabPathSheet",
                           size: CGSize(width: 420, height: 170)) { stage in
                let s = try stage.session()
                let entry = AgentHistoryPathEntry(text: "~/shop-api/docs",
                                                  problem: .missing(UICatalogCodeMode.shop + "/docs"))
                return UICatalogRender(s.wrap(CodeTabPathSheet(entry: entry, connection: nil, onChoose: { _ in },
                                                               onCancel: {})))
            },
            UICatalogEntry("终端窗口/Code 标签页_输入路径_空", source: page, symbol: "CodeTabPathSheet",
                           size: CGSize(width: 420, height: 170)) { stage in
                let s = try stage.session()
                return UICatalogRender(s.wrap(CodeTabPathSheet(entry: AgentHistoryPathEntry(), connection: nil,
                                                               onChoose: { _ in }, onCancel: {})))
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
            UICatalogEntry("本机终端/Code 标签页_置顶", source: local, symbol: "LocalShellTerminalArea", size: localSize) { stage in
                try await localCodeTabRender(stage, .init(fixtures: .init(pinned: ["c-login", "c-dots"]), running: ["x-tests"]))
            },
            UICatalogEntry("本机终端/Code 标签页_新会话起始页", source: page, symbol: "CodeTabNewSessionPage",
                           size: localSize) { stage in
                try await localCodeTabRender(stage, .init(selects: false))
            },
            // 本机终端窗口的最小尺寸下的起始页（侧栏收成窄轨）。
            UICatalogEntry("本机终端/Code 标签页_新会话起始页_最小窗口", source: page, symbol: "CodeTabNewSessionPage",
                           size: CGSize(width: 560, height: 360)) { stage in
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
        /// 跑着的会话里的程序经 OSC 7501 报的状态（会话 ID → `working` / `idle` / `blocked`…）：侧栏那一行上写它。
        /// 不在这里的没报过，行上不写状态。
        var runStates: [String: String] = [:]
        /// 右边显示这个跑着的会话的终端。
        var showsRun: String?
        /// 起一个还没对上记录的新会话，右边显示它。
        var newSession = false
        /// 那个新会话里的程序退出了（没说话就退出、没有对话记录）：终端留着，顶上「会话已结束」。
        var newSessionEnded = false
        var sidebarHidden = false
        var overlay = false
        /// 跑着的那个会话切到「查看记录」。
        var showsRecord = false
        /// 顶上跑着的会话那几行摆成鼠标悬在上面的样子（右端的 ×）。
        var hoversRuns = false
        /// 摆成「正拖着这个会话（会话 ID）、落在这里」的样子。
        var pinDrag: (session: String, target: AgentHistoryPinDrop)?
        /// Code 标签页「新会话」的目录；nil = 照默认（项目 shop-api），`.some(nil)` = 不知道。
        var directory: String?? = nil
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
        let codeID = workspace.openCodeTab(serverID: server.id, hostName: server.name,
                                           directory: setup.directory ?? UICatalogCodeMode.shop)
        guard let code = workspace.terminalGroups.tab(codeID)?.payload.codeTab else { throw CancellationError() }
        var fixtures = setup.fixtures
        fixtures.pinDefaults = s.defaults
        let terminals = await prepare(code, setup, fixtures: fixtures, home: UICatalogCodeMode.sshRoot)
        let view = s.wrap(TerminalWindowView(windowID: TerminalWindowID(id: UUID(), serverID: server.id),
                                             catalogModel: workspace))
        return UICatalogRender(view, after: { _ in
            await feed(terminals)
            if setup.newSessionEnded { await endNewSession(code) }
        }, cleanup: {
            AgentHistoryPinDragModel.catalogPreset = nil
            AgentHistoryRowActionsCatalog.hover = .none
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
        fixtures.pinDefaults = s.defaults
        // 本机最近待过的目录换成假的（真的那份是这台 Mac 上的路径）。
        code.recentDirectories = { [UICatalogCodeMode.localHome + "/notes", UICatalogCodeMode.localHome + "/Downloads"] }
        let terminals = await prepare(code, setup, fixtures: fixtures, home: UICatalogCodeMode.localHome)
        let view = s.wrap(LocalShellWindowView(windowID: LocalShellWindowID(id: UUID()), catalogModel: model))
        return UICatalogRender(view, after: { _ in
            await feed(terminals)
        }, cleanup: {
            AgentHistoryPinDragModel.catalogPreset = nil
            AgentHistoryRowActionsCatalog.hover = .none
            model.disposeAll()
        })
    }

    /// 装上假数据的连接，起好跑着的会话（终端接假后端），选好右边显示什么。返回要喂输出的终端。
    private static func prepare(_ code: CodeTabModel, _ setup: CodeTabSetup,
                                fixtures: UICatalogCodeMode.Setup, home: String) async -> [(TerminalSession, String)] {
        var fixtures = fixtures
        fixtures.selects = setup.selects && setup.showsRun == nil && !setup.newSession
        let history = await UICatalogCodeMode.model(fixtures)
        code.install(AgentHistoryConnection(history: history, home: home))
        AgentHistoryPinDragModel.catalogPreset = setup.pinDrag.flatMap { drag in
            history.files.first { $0.sessionID == drag.session }.map { (AgentHistoryPinKey($0), drag.target) }
        }
        AgentHistoryRowActionsCatalog.hover = setup.hoversRuns ? .runs : .none
        code.sidebarHidden = setup.sidebarHidden
        code.sidebarOverlayShown = setup.overlay
        var terminals: [(TerminalSession, String)] = []
        let selected = history.selectedFile
        for id in setup.running {
            guard let file = history.files.first(where: { $0.sessionID == id }), let run = code.resume(file) else { continue }
            let report = setup.runStates[id].map { "\u{1b}]7501;state=\($0):app=claude-code\u{1b}\\" } ?? ""
            if let session = session(of: run.terminal) {
                terminals.append((session, UICatalogTerminalScripts.claude + report))
            }
        }
        if setup.newSession, let directory = code.newSessionDirectory,
           let run = code.startNewSession(tool: .claude, command: "claude", directory: directory) {
            if let session = session(of: run.terminal) { terminals.append((session, UICatalogTerminalScripts.claude)) }
        }
        // 继续会把右边换成那个会话：要看的不是它就选回去。
        if let id = setup.showsRun, let file = history.files.first(where: { $0.sessionID == id }) {
            history.select(file)
            if setup.showsRecord, let run = code.run(for: file.path) {
                code.showRecord(of: run.id)
                for _ in 0..<100 where history.transcript?.reachedStart != true {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
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

    /// 新会话里的程序退出了：结束标记到（同 shell 里打出来的那样），Code 标签页把它标成已结束。
    private static func endNewSession(_ code: CodeTabModel) async {
        guard let run = code.runs.last, let session = session(of: run.terminal) else { return }
        session.feedOutput(text: "\r\n\u{1B}[2m（Claude Code 已退出）\u{1B}[0m\r\n$ ")
        session.trackedRun?.phase = .finished(0)
        code.checkRuns()
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
        /// 置顶的会话（会话 ID，按这个顺序）。
        var pinned: [String] = []
        /// 置顶存在哪（画廊那一次的一次性设置）；nil = 这个列表不能置顶。
        var pinDefaults: UserDefaults?
    }

    nonisolated static let sshRoot = "/home/deploy"
    nonisolated static let localRoot = "/Users/demo/code"
    /// 本机的假主目录（`localRoot` 在它下面）。
    nonisolated static let localHome = "/Users/demo"
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
        // 侧栏底部的账号额度：Claude Code 经状态栏转接存下的 5 小时 / 每周。
        await claude.setStatusLine(AgentStatusLineSnapshot(rateLimits: AgentRateLimits(
            primary: .init(usedPercent: 16, windowMinutes: 300, resetsAt: Date().addingTimeInterval(3600 * 3)),
            secondary: .init(usedPercent: 86, windowMinutes: 7 * 24 * 60, resetsAt: Date().addingTimeInterval(86_400 * 2)),
            plan: nil), at: Date(), modelWindows: ["claude-opus-5-5": 1_000_000]))
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
        await history.prepareStatusLines()
        for _ in 0..<100 where history.hasMore || history.isListing {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if let defaults = setup.pinDefaults {
            let pins = AgentHistoryPins(host: .local, defaults: defaults)
            for id in setup.pinned {
                if let file = history.files.first(where: { $0.sessionID == id }) { pins.pin(AgentHistoryPinKey(file)) }
            }
            history.pins = pins
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
        let read = AgentToolCall(toolUseID: "t0", name: "Read", summary: "internal/auth/handler.go",
                                 result: AgentToolResult(toolUseID: "t0", content: AgentClippedText("func Login(w http.ResponseWriter, r *http.Request) {\n\tdb, err := sql.Open(\"postgres\", dsn)", limit: 4000),
                                                         isError: false, imageCount: 0))
        let grep = AgentToolCall(toolUseID: "t0b", name: "Grep", summary: "MaxOpenConns",
                                 result: AgentToolResult(toolUseID: "t0b", content: AgentClippedText("internal/db/pool.go:14:\tdb.SetMaxOpenConns(5)", limit: 4000),
                                                         isError: false, imageCount: 0))
        return [
            AgentTranscriptItem(id: "c-login.u1", kind: .userText("登录接口偶尔返回 500，日志里是 `context deadline exceeded`。帮我找找原因。"),
                                timestamp: date.addingTimeInterval(-600)),
            AgentTranscriptItem(id: "c-login.a1", kind: .assistantText("先看一下登录的处理函数和连接池的设置。"),
                                timestamp: date.addingTimeInterval(-590)),
            AgentTranscriptItem(id: "c-login.th", kind: .thinking(AgentClippedText("超时在高峰期才出现，先看连接是怎么建的，再看池子的上限。", limit: 4000)),
                                timestamp: date.addingTimeInterval(-588)),
            AgentTranscriptItem(id: "c-login.t0", kind: .toolCall(read), timestamp: date.addingTimeInterval(-586)),
            AgentTranscriptItem(id: "c-login.t0b", kind: .toolCall(grep), timestamp: date.addingTimeInterval(-584)),
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
            // 最后一次回答的用量：标题旁「上下文 …」（Claude Code 的记录不写窗口多大，只有 token 数）。
            AgentTranscriptItem(id: "c-login.a3u", kind: .usage(AgentTurnUsage(model: "claude-opus-5-5", contextTokens: 232_006,
                                                                               outputTokens: 1_208)),
                                timestamp: date),
        ]
    }
}
