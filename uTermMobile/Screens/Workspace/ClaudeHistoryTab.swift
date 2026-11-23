import UDesignKit
import SwiftUI
import SwiftData
import Observation
import UIKit

/// 「Code」标签页：左边一台主机（或一台配对过的 Mac）上编码工具（Claude Code、Codex、Cursor、Antigravity）在命令行里的
/// 会话列表，右边看记录（只读）或继续聊天。连接、列表、分组、翻页都在两端共用的 `AgentHistoryConnection` /
/// `AgentHistoryModel` / `AgentHistoryListing` 里，这里只是标签与画面。
///
/// 直连的主机上「继续这个会话」「＋新会话」就在这个标签页里起一个活终端（`runs`，见 `ClaudeHistoryTab+Runs`）；
/// 配对的 Mac 照旧经接管开终端标签页（接管会把那台 Mac 的终端都镜像成标签页，放进这里会重复）。
///
/// 列表与记录只在内存里：不落盘、不进 iCloud。标签页本身重启不恢复；里面跑着的直连会话按终端标签页记进归档
/// （`MobileTerminalTabArchive`），App 被系统结束后以普通终端标签页接回。一台主机（一台 Mac）至多一个，再开就带到前台。
@MainActor
@Observable
final class ClaudeHistoryTab: Identifiable {
    let id = UUID()
    /// 直连的主机；配对的 Mac 是不入库的临时主机（`RemoteMacClient.filesTabHost`），只用来显示名字。
    let host: ServerProfile
    let hostName: String
    /// 读的是这台配对过的 Mac（远控链路），不是 SSH 主机。
    let remoteMac: RemoteMacClient?
    let connection: AgentHistoryConnection
    /// 打开它的那个终端当时所在的目录（终端标签长按打开的）；「+」菜单开的没有终端，为 nil。
    /// 「＋」新会话开在这里；没有就说明原因（同 Mac 的独立历史窗口）。
    private(set) var directory: String?
    /// 还没定位成功的「展开这个目录那一组并滚过去」：列表列出那一组之后由列表清掉。放在标签上而不是视图的 `@State` 里：
    /// Plus / Max 横竖屏切换会换外壳、重建视图，请求不能跟着丢。
    var pendingReveal: AgentHistoryReveal?
    @ObservationIgnored private var revealGeneration = 0

    // 在标签页里跑着的会话（`ClaudeHistoryTab+Runs`）。扩展里存不了属性，放在这里。
    /// 哪些会话正跑着活终端、详情看哪个（状态机，不沾界面）。
    let runs = CodeRunBoard<TermTab>()
    /// 各个 run 的连接中页：连上（或失败后用户取消）就拿掉。详情里只盖这一块，不盖列表。
    var runCovers: [UUID: MConnectRequest] = [:]
    /// 新会话对上记录之后读到的标题（继续的会话标题在 `history.metadata` 里）。
    var runTitles: [UUID: String] = [:]
    /// 建 run 的终端（测试换成接假传输的）。
    @ObservationIgnored var runTerminalFactory: @MainActor (ServerProfile) -> TermTab = { TermTab(host: $0) }
    /// 每个 run 要打进去的命令与在途的打字任务（重试时作废旧的，免得打两遍）。
    @ObservationIgnored var runCommands: [UUID: String] = [:]
    @ObservationIgnored var runTyping: [UUID: Task<Void, Never>] = [:]
    /// 新会话还没对上记录时，隔一会儿去主机上看一眼。
    @ObservationIgnored var newSessionPoll: Task<Void, Never>?
    /// 建 run 连接用的容器与主机密钥裁决（第一次起 run 时由界面交进来，重试沿用）。
    @ObservationIgnored var runContainer: ModelContainer?
    @ObservationIgnored var runRelay: HostKeyChallengeRelay?

    init(host: ServerProfile, connection: AgentHistoryConnection, remoteMac: RemoteMacClient? = nil) {
        self.host = host
        self.hostName = host.name
        self.remoteMac = remoteMac
        self.connection = connection
        reveal(directory: connection.preferredDirectory)
    }

    /// 已保存的主机（经 SFTP，与同主机的终端共用一条 SSH 连接）。`directory` 是终端当前目录：列表按项目分组，定位到它那一组。
    /// 四种工具都读、一直列全部项目（同 Mac 的 Code 模式）。
    convenience init(server host: ServerProfile, directory: String?, container: ModelContainer) {
        self.init(host: host, connection: AgentHistoryConnection(
            preferredDirectory: directory, allowsCommands: { !host.sftpOnly }, tools: AgentHistoryTool.allCases,
            followsCurrentProject: false, connect: AgentHistoryAccess.server(host, container: container)))
    }

    /// 配对过的 Mac：读它上面的记录。远控协议里没有终端的当前目录，不定位。
    convenience init(pairedMac client: RemoteMacClient) {
        self.init(host: client.filesTabHost,
                  connection: AgentHistoryConnection(preferredDirectory: nil, tools: AgentHistoryTool.allCases,
                                                     followsCurrentProject: false,
                                                     connect: AgentHistoryAccess.pairedMac(client)),
                  remoteMac: client)
    }

    /// 能不能「继续这个会话」「＋新会话」：要在那台主机上开终端。仅 SFTP 的主机开不了；配对的 Mac 要认得「新建本机终端」。
    var canResume: Bool {
        if let remoteMac { return remoteMac.supportsLocalShell }
        return !host.sftpOnly
    }

    /// 从终端标签再来一次（标签已经开着）：记下终端现在的目录，列表定位到它那一组。不知道目录就什么都不做。
    func reveal(directory: String?) {
        guard let directory else { return }
        self.directory = directory
        revealGeneration += 1
        pendingReveal = AgentHistoryReveal(directory: directory, generation: revealGeneration)
    }

    /// 在这台主机上新开一个终端标签页，连上、行编辑器起来之后打进 `command`（「继续这个会话」「＋新会话」）。
    /// 直连主机走连接中页（同「新建终端」，主机密钥要确认也在那里）；配对的 Mac 先请它开一个本机终端（开在 `directory`），
    /// 再整台接管、把那个终端放到前台。开不成（那台 Mac 不能新建终端等）抛出来，由界面提示。
    func runInNewTerminal(_ command: String, directory: String, store: MobileStore) async throws {
        guard canResume else { return }
        if let remoteMac {
            let sessionID = try await remoteMac.openLocalShell(directory: directory)
            store.takeOver(remoteMac, focus: sessionID, typing: command)
        } else {
            store.requestConnect(host, kind: .terminal, allowDuplicate: true, typing: command)
        }
    }

    func start() {
        Task { await connection.open() }
    }

    func close() {
        closeAllRuns()
        connection.close()
    }
}

/// 历史标签的主体：连接中 / 失败 / 会话列表与对话。
struct ClaudeHistorySessionBody: View {
    let tab: ClaudeHistoryTab
    /// 标签在前台、工作区没收起：打开着的对话才盯着文件末尾（实时跟随），露着的终端才算前台。
    var isActive = true
    /// 是聚焦格的前台（分屏时两格都在屏上，只有这一格的终端弹键盘）。
    var isFocused = true
    /// 用户点了这片终端（分屏时据此把焦点切到它所在的格）。
    var onInteract: (() -> Void)? = nil
    /// 配对的 Mac 上「继续这个会话」「＋」新会话：在那台 Mac 上开终端标签页跑这条命令（直连的主机就在这个标签页里跑）。
    var onRun: (_ command: String, _ directory: String) -> Void

    @Environment(\.modelContext) private var context
    /// 可选：只挂列表的用例里没有注入。没有就退回 `onRun`。
    @Environment(HostKeyChallengeRelay.self) private var relay: HostKeyChallengeRelay?
    @Environment(MobileWorkspace.self) private var workspace: MobileWorkspace?

    var body: some View {
        Group {
            switch tab.connection.phase {
            case .connecting:
                ClaudeHistoryProgress(text: String(localized: "正在连接…"))
            case .failed(let message):
                ClaudeHistoryState(icon: "warn", title: String(localized: "无法读取历史会话"), message: message,
                                   actionTitle: String(localized: "重试")) {
                    Task { await tab.connection.open() }
                }
            case .ready(let history):
                ClaudeHistoryBrowser(
                    history: history, canResume: tab.canResume, isActive: isActive,
                    newSession: tab.canResume
                        ? AgentHistoryNewSession(directory: tab.directory) { tool, command, directory in
                            startNew(tool, command: command, directory: directory)
                        }
                        : nil,
                    reveal: Binding(get: { tab.pendingReveal }, set: { tab.pendingReveal = $0 }),
                    code: CodeTabRuns(tab: tab, isFocused: isFocused, onInteract: onInteract,
                                      onMoveToTab: workspace.map { workspace in { id in
                                          _ = tab.moveRunToTab(id, in: workspace)
                                      } })) { file in
                    resume(file, in: history)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(M.surface, ignoresSafeAreaEdges: .mSessionBody)
    }

    /// 直连主机：就在这个标签页里起终端；配对的 Mac（或者没注入主机密钥裁决的用例）：交给 `onRun` 开终端标签页。
    private func resume(_ file: AgentHistorySessionFile, in history: AgentHistoryModel) {
        guard let plan = history.resumeCommand(for: file) else { return }
        if tab.runsInPlace, let relay {
            tab.resumeInPlace(file, command: plan.command, directory: plan.directory,
                              container: context.container, relay: relay)
        } else {
            onRun(plan.command, plan.directory)
        }
    }

    private func startNew(_ tool: AgentHistoryTool, command: String, directory: String) {
        if tab.runsInPlace, let relay {
            tab.startNewInPlace(tool: tool, command: command, directory: directory,
                                container: context.container, relay: relay)
        } else {
            onRun(command, directory)
        }
    }
}

/// Code 标签页交给列表与详情的东西：在标签页里跑着的会话，和它们的终端怎么挂。只挂列表与记录（不在 Code 标签页里）时为 nil。
struct CodeTabRuns {
    let tab: ClaudeHistoryTab
    var isFocused = true
    var onInteract: (() -> Void)? = nil
    /// 「移到新标签页」；nil = 不出这一项（没有工作区可放）。
    var onMoveToTab: ((UUID) -> Void)? = nil

    var board: CodeRunBoard<TermTab> { tab.runs }
}

/// 列表与详情。宽的格子（iPad、展开的 Duo 横屏）左边列表一直在、右边是详情；窄的先是列表，点一条进到详情，左上角返回列表。
/// 详情是一份记录（只读），或者在 Code 标签页里继续着的会话的活终端（「终端 / 记录」切换）。
/// 对话里点进子代理的记录再一层层往里进，左上角一层层返回。
///
/// 列表与详情一直挂着、只按格子宽窄摆位置（看不见的移到屏外）：终端是 `UIViewRepresentable`，换一个父视图重建的话
/// SwiftUI 之后不再更新它的尺寸（分屏那次踩过），所以宽窄之间不能用 `if` 换两套视图树。
///
/// 只认 `AgentHistoryModel` 与几个回调（`code` 可以不给），不管自己被放在哪里。
struct ClaudeHistoryBrowser: View {
    let history: AgentHistoryModel
    let canResume: Bool
    var isActive = true
    /// 「＋」新会话；nil = 不出这个按钮（这台主机开不了终端）。
    var newSession: AgentHistoryNewSession? = nil
    /// 要列表定位到的目录（定位成功后由列表清掉）。
    var reveal: Binding<AgentHistoryReveal?> = .constant(nil)
    /// 在 Code 标签页里跑着的会话。
    var code: CodeTabRuns? = nil
    let onResume: (AgentHistorySessionFile) -> Void

    @Environment(\.scenePhase) private var scenePhase

    /// 宽过这么多才左右并排：列表 300pt，详情至少还要 400pt 才读得下去。
    nonisolated static let sideBySideMinWidth: CGFloat = 700
    private static let listWidth: CGFloat = 300

    /// 窄屏上详情这一层露着：看着一份记录，或者看着一个跑着的会话。
    private var detailActive: Bool { history.transcript != nil || code?.board.focused != nil }
    /// 详情露着的是终端（而不是记录）。
    private var terminalShown: Bool { code?.board.focused?.showsTerminal ?? false }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= Self.sideBySideMinWidth
            let showsList = wide || !detailActive
            let showsDetail = wide || detailActive
            let detailX: CGFloat = wide ? Self.listWidth + 1 : 0
            ZStack(alignment: .topLeading) {
                ClaudeHistoryList(history: history, newSession: newSession, reveal: reveal, code: code)
                    .frame(width: wide ? Self.listWidth : geo.size.width, height: geo.size.height)
                    .offset(x: showsList ? 0 : -100_000)
                    .allowsHitTesting(showsList)
                    .accessibilityHidden(!showsList)
                Rectangle().fill(M.divider)
                    .frame(width: 1, height: geo.size.height)
                    .offset(x: wide ? Self.listWidth : -100_000)
                detail(showsBack: !wide, visible: showsDetail)
                    .frame(width: max(geo.size.width - detailX, 0), height: geo.size.height)
                    .offset(x: showsDetail ? detailX : -100_000)
                    .allowsHitTesting(showsDetail)
                    .accessibilityHidden(!showsDetail)
            }
        }
        // 实时跟随只在看得见时查：标签不在前台、工作区收起、App 进了后台就停（省电），回来马上查一次。
        .onChange(of: isActive && scenePhase != .background, initial: true) { _, visible in
            history.setTranscriptVisible(visible)
        }
        .onDisappear { history.setTranscriptVisible(false) }
    }

    /// 详情：记录（或「选择一个会话」）在下面，跑着的会话的终端各自一层盖在上面，只露出看着的那一个。
    private func detail(showsBack: Bool, visible: Bool) -> some View {
        ZStack {
            record(showsBack: showsBack)
                .opacity(terminalShown ? 0 : 1)
                .allowsHitTesting(!terminalShown)
                .accessibilityHidden(terminalShown)
            if let code {
                ForEach(code.board.runs) { run in
                    let shown = visible && code.board.focusedID == run.id && run.showsTerminal
                    CodeRunPane(code: code, run: run, shown: shown, isActive: isActive && shown,
                                showsBack: showsBack)
                }
            }
        }
    }

    @ViewBuilder private func record(showsBack: Bool) -> some View {
        if let transcript = history.transcript {
            // 主对话与点进去的一层层子代理记录都挂着，只露出最里面那层：返回时滚动位置、展开的块都还在。
            let levels = [transcript] + history.subagentStack
            let top = levels.last?.path
            ZStack {
                ForEach(levels, id: \.path) { level in
                    let isTop = level.path == top
                    ClaudeTranscriptView(transcript: level,
                                         metadata: history.metadata[level.file.path],
                                         canResume: canResume && history.resumeCommand(for: level.file) != nil,
                                         onBack: back(for: level, showsBack: showsBack),
                                         onResume: { onResume(level.file) },
                                         onOpenSubagent: { history.openSubagent($0) },
                                         onJumpToLatest: { history.jumpToLatest() },
                                         onBackToTerminal: level.subagent == nil ? backToTerminal(for: level.file) : nil)
                        .opacity(isTop ? 1 : 0)
                        .allowsHitTesting(isTop)
                        .accessibilityHidden(!isTop)
                }
            }
            // 换了一份对话（含「跳到最新」）就是新的视图。
            .id(ObjectIdentifier(transcript))
        } else {
            ClaudeHistoryState(icon: "clock", title: String(localized: "选择一个会话"),
                               message: AgentHistoryText.selectSessionDetail(tools: listedTools))
        }
    }

    /// 这份记录正跑着（在 Code 标签页里继续着）：记录顶上「继续这个会话」换成「返回终端」，一键回去。
    private func backToTerminal(for file: AgentHistorySessionFile) -> (() -> Void)? {
        guard let code, let run = code.board.run(forSession: file.path), run.isRunning else { return nil }
        return { code.tab.setShowsTerminal(run.id, true) }
    }

    /// 说明里点名的工具：这台主机上有记录的；一种都没有时是读了的那几种。同 Mac。
    private var listedTools: [AgentHistoryTool] {
        history.availableTools.isEmpty ? history.configuredTools : history.availableTools
    }

    /// 子代理的记录回上一层；主对话在窄屏回列表，宽屏没有返回。
    private func back(for level: AgentTranscriptModel, showsBack: Bool) -> (() -> Void)? {
        if level.subagent != nil { return { history.closeSubagent() } }
        guard showsBack else { return nil }
        if let code { return { code.tab.backToList() } }
        return { history.select(nil) }
    }
}

// MARK: - 会话列表

/// 会话列表：顶上「分组与显示」菜单、「＋」新会话、刷新，下面搜索框；再下面按分组列（组可以折起来），搜索时换成搜索结果。
/// 分组方式与「只看哪几种工具」和 Mac 同一对偏好键、同一套编解码（`AgentHistoryListPreferences`）。
private struct ClaudeHistoryList: View {
    let history: AgentHistoryModel
    let newSession: AgentHistoryNewSession?
    @Binding var reveal: AgentHistoryReveal?
    /// Code 标签页里跑着的会话：列表顶上「正在运行」，行上标「运行中」，点一行按它走（见 `ClaudeHistoryTab.select`）。
    var code: CodeTabRuns? = nil

    @AppStorage(DefaultsKey.agentHistoryGrouping) private var groupingRaw = AgentHistoryGrouping.default.rawValue
    @AppStorage(DefaultsKey.agentHistoryShownTools) private var shownToolsRaw = ""

    private var grouping: AgentHistoryGrouping {
        AgentHistoryListPreferences.effectiveGrouping(groupingRaw, isMultiTool: history.isMultiTool)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            Rectangle().fill(M.divider).frame(height: 1)
            // 一眼看到有几个在跑：列表顶上一组「正在运行」（新会话还没有记录，也在这里）。搜索时也留着。
            if let code, !code.board.runs.isEmpty {
                CodeRunningSection(code: code)
                Rectangle().fill(M.divider).frame(height: 1)
            }
            // 搜索结果盖在列表上，列表一直挂着：清空搜索后选中的会话、滚动位置都还在。
            ZStack {
                content
                    .opacity(history.search == nil ? 1 : 0)
                    .allowsHitTesting(history.search == nil)
                    .accessibilityHidden(history.search != nil)
                if let search = history.search {
                    ClaudeHistorySearchResults(history: history, search: search) { file in
                        // 点开的那份正跑着：看它的记录（停在命中那里），终端还在，切回去就是。
                        guard let code, let run = code.board.run(forSession: file.path) else { return }
                        code.board.focus(run.id)
                        code.board.setShowsTerminal(run.id, false)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { history.setShownTools(AgentHistoryListPreferences.decodeTools(shownToolsRaw)) }
        .onChange(of: shownToolsRaw) { _, raw in history.setShownTools(AgentHistoryListPreferences.decodeTools(raw)) }
    }

    private var searchBar: some View {
        @Bindable var history = history
        return VStack(alignment: .leading, spacing: 4) {
            MSearchField(text: $history.searchText, placeholder: AgentHistoryText.searchPlaceholder)
                .submitLabel(.search)
                .onSubmit { history.submitSearch() }
            if let problem = history.searchProblem {
                Text(AgentHistoryText.searchProblem(problem))
                    .font(M.sans(12.5)).foregroundStyle(M.warning)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    /// 左边是「分组与显示」菜单（字是当前的分组方式，一眼看得出按什么分的），右边「＋」。刷新不单占一个按钮：
    /// 列表下拉刷新，菜单里也有一项（同 Mac 把刷新并进了菜单）。
    /// 放在搜索框上面一行而不是和它挤一行：窄的格子（Duo 分屏 330pt）里搜索框还要留得下提示字。
    private var header: some View {
        HStack(spacing: 2) {
            optionsMenu
            Spacer(minLength: 0)
            if let newSession { newSessionButton(newSession) }
        }
        .padding(.trailing, 4)
    }

    /// 刷新、分组方式、只看哪几种工具（不止一种工具时才有）、恢复默认。同 Mac。
    private var optionsMenu: some View {
        MMenu {
            Button { Task { await history.reload() } } label: {
                Label(String(localized: "刷新"), systemImage: "arrow.clockwise")
            }
            Section {
                Picker(selection: Binding(get: { grouping }, set: { groupingRaw = $0.rawValue })) {
                    ForEach(AgentHistoryListPreferences.groupingChoices(isMultiTool: history.isMultiTool)) { choice in
                        Text(AgentHistoryText.groupingName(choice)).tag(choice)
                    }
                } label: {
                    Text("分组方式", comment: "历史会话列表菜单：按什么分组")
                }
                .pickerStyle(.inline)
            } header: {
                Text("分组方式", comment: "历史会话列表菜单：按什么分组")
            }
            if history.isMultiTool {
                Section(String(localized: "显示", comment: "历史会话列表菜单：只看哪几种编码工具")) {
                    let effective = history.effectiveTools
                    ForEach(history.availableTools) { tool in
                        Toggle(tool.displayName, isOn: Binding(
                            get: { effective.contains(tool) },
                            set: { _ in
                                let next = AgentHistoryListing.toggling(tool, shown: history.shownTools,
                                                                        available: history.availableTools)
                                shownToolsRaw = AgentHistoryListPreferences.encodeTools(next)
                            }))
                        // 不许一种都不勾：只剩它时它点不掉。
                        .disabled(effective == [tool])
                    }
                }
            }
            Section {
                Button(String(localized: "恢复默认")) {
                    groupingRaw = AgentHistoryGrouping.default.rawValue
                    shownToolsRaw = ""
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(M.text2)
                Text(AgentHistoryText.groupingName(grouping))
                    .font(M.sans(14, weight: .semibold)).foregroundStyle(M.text)
                    .lineLimit(1)
                // 只看了其中几种：标签上带个数，免得以为别的工具没有记录。
                if history.isMultiTool, history.effectiveTools.count < history.availableTools.count {
                    Text(verbatim: "\(history.effectiveTools.count)/\(history.availableTools.count)")
                        .font(M.mono(11.5, weight: .medium)).foregroundStyle(M.text3)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(M.text3)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: M.minTarget)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("分组与显示"))
        .accessibilityValue(Text(AgentHistoryText.groupingName(grouping)))
    }

    /// 「＋」：一律是菜单——能开的工具在里面选；开不了（不知道目录、这台主机上的工具都不能新开）时菜单里说明原因，
    /// 手机上没有悬停提示，灰掉的按钮说不清为什么。
    private func newSessionButton(_ newSession: AgentHistoryNewSession) -> some View {
        let tools = history.newSessionTools(directory: newSession.directory)
        return MMenu {
            if let directory = newSession.directory, !tools.isEmpty {
                Section(AgentHistoryText.newSessionTitle(directory: directory)) {
                    ForEach(tools) { tool in
                        Button(tool.displayName) {
                            guard let command = history.newSessionCommand(tool: tool, directory: directory) else { return }
                            newSession.start(tool, command, directory)
                        }
                    }
                }
            } else {
                Text(newSession.directory == nil
                     ? AgentHistoryText.newSessionHelp(directory: nil)
                     : String(localized: "这台主机上的编码工具都不能在终端里新开会话"))
            }
        } label: {
            MIcon(name: "plus", size: 15, color: M.text2, weight: .semibold)
                .frame(width: M.minTarget, height: M.minTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(AgentHistoryText.newSession))
    }

    @ViewBuilder private var content: some View {
        switch history.phase {
        case .loading:
            ClaudeHistoryProgress(text: String(localized: "正在读取会话列表…"))
        case .empty:
            ClaudeHistoryState(icon: "clock", title: String(localized: "没有历史会话"),
                               message: AgentHistoryText.noHistoryDetail(tools: history.configuredTools))
        case .failed(let message):
            ClaudeHistoryState(icon: "warn", title: String(localized: "无法读取会话列表"), message: message,
                               actionTitle: String(localized: "重试")) {
                Task { await history.reload() }
            }
        case .ready:
            let files = history.visibleFiles
            // 还在列目录，或者读过的那几份都不用列、后面还有没读的：接着等，别急着说「没有」。
            if files.isEmpty && (history.isListing || history.hasMore) {
                ClaudeHistoryProgress(text: String(localized: "正在读取会话列表…"))
            } else if files.isEmpty {
                ClaudeHistoryState(icon: "clock", title: String(localized: "没有命令行会话"),
                                   message: AgentHistoryText.emptyListDetail(hidden: history.hiddenCount))
            } else {
                list(files)
            }
        }
    }

    private func list(_ files: [AgentHistorySessionFile]) -> some View {
        let groups = AgentHistoryListing.groups(files, by: grouping, metadata: history.metadata,
                                                date: { history.liveActivity(of: $0) ?? $0.modifiedAt })
        let showsTool = history.isMultiTool
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups) { group in
                        let collapsed = history.collapsedGroups.contains(group.id)
                        if group.kind != .all {
                            ClaudeHistoryGroupHeader(group: group, collapsed: collapsed) { toggle(group.id) }
                                .id(group.id)
                        }
                        if !collapsed {
                            ForEach(group.files) { file in
                                Button {
                                    if let code { code.tab.select(file) } else { history.select(file) }
                                } label: {
                                    ClaudeHistoryRow(history: history, file: file, metadata: history.metadata[file.path],
                                                     showsProject: grouping != .project, showsTool: showsTool,
                                                     isRunning: code?.tab.isRunning(file) ?? false,
                                                     isSelected: history.selectedFile?.path == file.path)
                                }
                                .buttonStyle(MPressStyle())
                            }
                        }
                    }
                    footer(files)
                }
                .padding(8)
            }
            .mKeepsScrollContentInSafeArea()
            // 下拉刷新：重新列项目与会话（读过的信息按缓存复用）。
            // 下拉刷新：列表不换成「正在读取…」（那样内容会消失一下、转圈跟着闪），安静地重列。
            .refreshable { await history.reload(showsLoading: false) }
            .onChange(of: reveal, initial: true) { _, _ in tryReveal(groups, proxy: proxy) }
            .onChange(of: groups.map(\.id)) { _, _ in tryReveal(groups, proxy: proxy) }
        }
    }

    /// 定位到终端当前目录那一组：展开它并滚过去。还没列到它就等列表变了再试；不按项目分组时不动（同 Mac）。
    private func tryReveal(_ groups: [AgentHistoryGroup], proxy: ScrollViewProxy) {
        guard let request = reveal, grouping == .project,
              let id = AgentHistoryListing.groupID(containing: request.directory, in: groups) else { return }
        reveal = nil
        history.collapsedGroups.remove(id)
        Task { @MainActor in proxy.scrollTo(id, anchor: .top) }
    }

    private func toggle(_ id: String) {
        if history.collapsedGroups.contains(id) {
            history.collapsedGroups.remove(id)
        } else {
            history.collapsedGroups.insert(id)
        }
    }

    @ViewBuilder private func footer(_ files: [AgentHistorySessionFile]) -> some View {
        if history.hasMore {
            // 滚到底露出来就再读一批（同 Mac：行数变了它就是一个新视图，格子高、读完一批还露着时也会接着读；
            // 上一批没读够时 `loadMore` 自己不起作用，不会一露出来就一路读下去）。
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在读取…").font(M.sans(12.5)).foregroundStyle(M.text4)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .id(files.count)
            .onAppear { history.loadMore() }
        } else if history.hiddenCount > 0 {
            Text(AgentHistoryText.hiddenNote(history.hiddenCount))
                .font(M.sans(12.5)).foregroundStyle(M.text4)
                .padding(.horizontal, 12).padding(.vertical, 10)
        }
        // 某种工具的记录读不出来：别的照常列着，底下说一句。
        ForEach(AgentHistoryTool.allCases.filter { history.toolFailures[$0] != nil }) { tool in
            ClaudeHistoryWarningNote(text: AgentHistoryText.toolFailure(tool, message: history.toolFailures[tool] ?? ""))
        }
    }
}

/// 组标题：折叠箭头、标题、会话数。点一下折起 / 展开。项目组的标题是目录名（不翻译），完整路径给读屏。
private struct ClaudeHistoryGroupHeader: View {
    let group: AgentHistoryGroup
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(M.text4)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 14)
                if case .tool(let tool) = group.kind {
                    AgentHistoryToolBadge(tool: tool, size: 16)
                }
                Text(AgentHistoryText.groupTitle(group))
                    .font(M.sans(13.5, weight: .semibold)).foregroundStyle(M.text2)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(verbatim: "\(group.files.count)")
                    .font(M.mono(12)).foregroundStyle(M.text4)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle())
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AgentHistoryText.groupAccessibility(group, collapsed: collapsed)))
        .accessibilityHint(Text(verbatim: AgentHistoryText.groupHelp(group) ?? ""))
        .accessibilityAddTraits(.isButton)
    }
}

/// 列表、搜索结果里的一句警示（某种工具读不出来、搜索出错）。
private struct ClaudeHistoryWarningNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            MIcon(name: "warn", size: 12, color: M.warning, weight: .semibold)
            Text(verbatim: text)
                .font(M.sans(12.5)).foregroundStyle(M.text2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 搜索结果

/// 同 Mac：按会话分组（最近的在前），每组下面是命中的摘要行；点一条打开那份对话并停在那里（窄屏进到对话，返回回到结果）。
private struct ClaudeHistorySearchResults: View {
    let history: AgentHistoryModel
    let search: AgentHistoryModel.Search
    /// 点开了一条命中（那份记录已经选上）。
    var onOpened: (AgentHistorySessionFile) -> Void = { _ in }

    var body: some View {
        if search.sessions.isEmpty, !search.isRunning {
            VStack(spacing: 0) {
                excludedNote
                unsearchedNote
                emptyState
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    status
                    excludedNote
                    unsearchedNote
                    ForEach(search.sessions) { session in
                        group(session)
                    }
                    footer
                }
                .padding(8)
            }
            .mKeepsScrollContentInSafeArea()
        }
    }

    /// 有的工具的会话没参与搜索（记录的格式没法在主机上搜）：结果上方说一句。全都不能搜时失败页已经说了，不重复。同 Mac。
    @ViewBuilder private var excludedNote: some View {
        let excluded = history.searchExcludedTools
        if !excluded.isEmpty, search.phase != .failed(AgentHistoryText.searchUnsupported(excluded)) {
            note(AgentHistoryText.searchUnsupported(excluded))
        }
    }

    /// 压缩过的记录没搜（主机上没有解压的工具）：也说一句，免得以为搜全了。
    @ViewBuilder private var unsearchedNote: some View {
        if search.unsearched > 0 { note(AgentHistoryText.searchSkippedCompressed(search.unsearched)) }
    }

    @ViewBuilder private var emptyState: some View {
        switch search.phase {
        case .failed(let message):
            ClaudeHistoryState(icon: "warn", title: String(localized: "无法搜索"), message: message,
                               actionTitle: String(localized: "重试")) { history.submitSearch() }
        case .stopped:
            ClaudeHistoryState(icon: "search", title: AgentHistoryText.searchStopped(search),
                               message: AgentHistoryText.searchNoResultsDetail,
                               actionTitle: String(localized: "重试")) { history.submitSearch() }
        default:
            ClaudeHistoryState(icon: "search", title: AgentHistoryText.searchNoResults(search.query),
                               message: AgentHistoryText.searchNoResultsDetail)
        }
    }

    @ViewBuilder private var status: some View {
        if search.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(AgentHistoryText.searchProgress(search))
                    .font(M.sans(12.5)).foregroundStyle(M.text3)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(AgentHistoryText.stopSearch) { history.stopSearch() }
                    .font(M.sans(13.5, weight: .medium))
                    .frame(minHeight: M.minTarget)
            }
            .padding(.horizontal, 6)
        }
    }

    @ViewBuilder private var footer: some View {
        if search.truncated {
            note(AgentHistoryText.searchTruncated(search.hitCount))
        } else if search.phase == .stopped {
            note(AgentHistoryText.searchStopped(search))
        } else if case .failed(let message) = search.phase {
            ClaudeHistoryWarningNote(text: message)
        }
    }

    private func note(_ text: String) -> some View {
        // text3 而不是 text4：「哪种工具不参与搜索」这类说明要读得清（text4 压在浅色底上太淡）。
        Text(text).font(M.sans(12.5)).foregroundStyle(M.text3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func group(_ session: AgentHistorySearchSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if history.isMultiTool { AgentHistoryToolBadge(tool: session.file.tool, size: 17) }
                    Text(AgentHistoryText.sessionTitle(session.file, metadata: session.metadata))
                        .font(M.sans(15, weight: .semibold)).foregroundStyle(M.text)
                        .lineLimit(1)
                }
                AgentSessionTimeText(history: history, file: session.file) { activity in
                    AgentHistoryText.searchSessionDetail(session, showsProject: history.scope == .all, activity: activity)
                }
                .font(M.sans(12.5)).foregroundStyle(M.text3)
                .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.bottom, 2)
            ForEach(session.hits) { hit in
                Button {
                    history.openHit(hit, in: session)
                    onOpened(session.file)
                } label: {
                    ClaudeHistorySearchHitRow(hit: hit, tool: session.file.tool, isSelected: isOpen(hit, in: session))
                }
                .buttonStyle(MPressStyle())
            }
            if session.hasMoreHits {
                note(AgentHistoryText.sessionMoreHits(session.hits.count))
            }
        }
    }

    private func isOpen(_ hit: AgentHistorySearchHit, in session: AgentHistorySearchSession) -> Bool {
        history.selectedFile?.path == session.file.path && history.transcript?.highlightedItemID == hit.itemID
    }
}

private struct ClaudeHistorySearchHitRow: View {
    let hit: AgentHistorySearchHit
    /// 回答的一方叫什么（Codex 的回答不标「Claude」）。
    let tool: AgentHistoryTool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AgentHistoryText.roleLabel(hit.role, tool: tool))
                    .font(M.sans(11.5, weight: .semibold)).foregroundStyle(M.text4)
                Text(AgentHistorySnippetText.attributed(hit.snippet, match: M.accent))
                    .font(M.sans(14)).foregroundStyle(M.text2)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MIcon(name: "chev", size: 12, color: M.text4, weight: .semibold)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: M.minTarget)
        .background(RoundedRectangle(cornerRadius: MRadius.md, style: .continuous)
            .fill(isSelected ? M.rowSelected : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct ClaudeHistoryRow: View {
    let history: AgentHistoryModel
    let file: AgentHistorySessionFile
    let metadata: AgentHistorySessionMetadata?
    let showsProject: Bool
    /// 不止一种工具时行首带工具标记（共享的 `AgentHistoryToolMark`）。
    var showsTool = false
    /// 在 Code 标签页里继续着：第二行前面一个绿点「运行中」。
    var isRunning = false
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if showsTool {
                AgentHistoryToolBadge(tool: file.tool, size: 18)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(AgentHistoryText.sessionTitle(file, metadata: metadata))
                    .font(M.sans(15, weight: .medium)).foregroundStyle(M.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if isRunning { CodeRunningMark() }
                    AgentSessionTimeText(history: history, file: file) { activity in
                        AgentHistoryText.sessionSubtitle(file, metadata: metadata, showsProject: showsProject, activity: activity)
                    }
                    .font(M.sans(12.5)).foregroundStyle(M.text3)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MIcon(name: "chev", size: 12, color: M.text4, weight: .semibold)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: MRadius.md, style: .continuous)
            .fill(isSelected ? M.rowSelected : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - 对话

private struct ClaudeTranscriptView: View {
    let transcript: AgentTranscriptModel
    let metadata: AgentHistorySessionMetadata?
    let canResume: Bool
    /// 窄屏：回到列表；子代理的记录：回上一层。宽屏的主对话没有（列表一直在左边）。
    let onBack: (() -> Void)?
    let onResume: () -> Void
    let onOpenSubagent: (AgentSubagentLink) -> Void
    /// 从搜索命中处打开的：换回从末尾打开。
    var onJumpToLatest: () -> Void = {}
    /// 这份记录正在 Code 标签页里继续着：「继续这个会话」换成「返回终端」。
    var onBackToTerminal: (() -> Void)? = nil

    @State private var expanded: Set<String> = []
    @State private var pendingAnchor: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(M.divider).frame(height: 1)
            if transcript.opensAtHit, !transcript.reachedEnd {
                hitBanner
                Rectangle().fill(M.divider).frame(height: 1)
            }
            messages
        }
    }

    /// 从命中处打开、后面还没读到末尾：顶上说一句，给「跳到最新」。同 Mac。
    private var hitBanner: some View {
        HStack(spacing: 8) {
            Text(AgentHistoryText.openedAtHit)
                .font(M.sans(12.5)).foregroundStyle(M.text2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            MBtn(title: AgentHistoryText.jumpToLatest, icon: "download", kind: .secondary, height: 32,
                 action: onJumpToLatest)
                .fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(M.fillFaint)
    }

    /// 放得下就一行（返回 · 标题 · 拷贝 · 继续）；窄的格子（Duo 分屏 330pt、iPhone 竖屏）标题一行、按钮另起一行，
    /// 不然标题只剩两三个字。
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                backButton
                titleBlock
                actions
            }
            // 子代理的记录只有拷贝一个按钮，窄的格子里也放得下一行。
            .frame(minWidth: transcript.subagent == nil ? 460 : 0, minHeight: 52)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    backButton
                    titleBlock
                }
                .frame(minHeight: 48)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    actions
                }
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder private var backButton: some View {
        if let onBack {
            Button(action: onBack) {
                MIcon(name: "back", size: 17, color: M.text2, weight: .semibold)
                    .frame(width: M.minTarget, height: M.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel(Text(transcript.subagent == nil ? String(localized: "返回会话列表")
                                                                 : AgentHistoryText.backToParent))
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(transcript.subagent.map(AgentHistoryText.subagentTitle) ?? AgentHistoryText.transcriptTitle(metadata))
                    .font(M.sans(14.5, weight: .semibold)).foregroundStyle(M.text)
                    .lineLimit(1)
                if transcript.isUpdating { ClaudeUpdatingBadge() }
            }
            AgentTranscriptDetailText(transcript: transcript, metadata: metadata)
                .font(M.sans(11.5)).foregroundStyle(M.text3)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.leading, onBack == nil ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            MMenu {
                if transcript.subagent == nil {
                    Button { UIPasteboard.general.string = transcript.file.sessionID } label: {
                        Label("拷贝会话 ID", systemImage: "number")
                    }
                }
                Button { UIPasteboard.general.string = transcript.plainText } label: {
                    Label("拷贝已加载的对话", systemImage: "doc.on.doc")
                }
            } label: {
                MIcon(name: "copy", size: 15, color: M.text2)
                    .frame(width: 40, height: M.minTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("拷贝"))
            // 子代理的记录只读：不能单独继续。
            if let onBackToTerminal {
                MBtn(title: String(localized: "返回终端"), icon: "term", kind: .tinted, height: 34, action: onBackToTerminal)
                    .fixedSize()
                    .padding(.trailing, 10)
            } else if transcript.subagent == nil {
                MBtn(title: String(localized: "继续这个会话"), icon: "run", kind: .tinted, height: 34,
                     disabled: !canResume, action: onResume)
                    .fixedSize()
                    .padding(.trailing, 10)
            } else {
                Spacer().frame(width: 4)
            }
        }
    }

    private var messages: some View {
        let items = transcript.items
        let runStarts = AgentTranscriptRuns.starts(items)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    top
                    ForEach(items) { item in
                        ClaudeTranscriptRow(item: item, showsRole: runStarts.contains(item.id), inSubagent: transcript.subagent != nil,
                                            tool: transcript.file.tool,
                                            subagent: subagentLink(item), onOpenSubagent: onOpenSubagent,
                                            isHighlighted: item.id == transcript.highlightedItemID,
                                            expanded: $expanded)
                            .id(item.id)
                    }
                    bottom
                    if items.isEmpty, transcript.reachedStart, transcript.errorMessage == nil {
                        Text("这个会话里没有可显示的消息。")
                            .font(M.sans(13)).foregroundStyle(M.text3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                    // 跟到底时滚到这里。底部留白由它和上面的间距承担（同原来的 14pt），锚点下面不再垫 padding。
                    Color.clear.frame(height: 2).id(Self.bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }
            .mKeepsScrollContentInSafeArea()
            // 打开时停在最后一条（从末尾读起）；内容不满一屏时从顶上排起——只写 `.bottom` 的话短对话会贴着底、上面空一大片。
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .onChange(of: transcript.prependGeneration) { old, _ in
                // 往前加了一页：留在原来最上面那条，不跳到别处。第一页不用（默认停在底部）。
                guard old > 0, let anchor = pendingAnchor else { return }
                proxy.scrollTo(anchor, anchor: .top)
            }
            .onChange(of: transcript.focusGeneration) { _, _ in
                // 搜索命中的那一条：滚到中间（等这一轮布局完）。
                guard let id = transcript.highlightedItemID else { return }
                Task { @MainActor in proxy.scrollTo(id, anchor: .center) }
            }
            .modifier(AgentTranscriptTailFollow(transcript: transcript, proxy: proxy, bottomID: Self.bottomID))
            .overlay(alignment: .bottom) {
                if transcript.hasNewBelow {
                    ClaudeNewMessagesPill {
                        transcript.setFollowsTail(true)
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
        }
    }

    private static let bottomID = "claude-transcript-bottom"

    @ViewBuilder private var top: some View {
        if let error = transcript.errorMessage {
            VStack(spacing: 8) {
                Text(verbatim: error).font(M.sans(13)).foregroundStyle(M.warning)
                    .multilineTextAlignment(.center)
                MBtn(title: String(localized: "重试"), icon: "refresh", kind: .secondary, height: 34) { loadEarlier() }
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
        } else if transcript.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 8)
        } else if !transcript.reachedStart {
            MBtn(title: String(localized: "加载更早的消息"), icon: "upload", kind: .secondary, height: 34) { loadEarlier() }
                .fixedSize()
                .frame(maxWidth: .infinity)
        }
    }

    /// 从命中处打开的：后面还有，「加载更晚的消息」（滚到底也会读，见 `AgentTranscriptTailFollow`）。
    @ViewBuilder private var bottom: some View {
        if !transcript.reachedEnd {
            VStack(spacing: 8) {
                if let error = transcript.laterErrorMessage {
                    Text(verbatim: error).font(M.sans(13)).foregroundStyle(M.warning)
                        .multilineTextAlignment(.center)
                }
                if transcript.isLoadingLater {
                    ProgressView().padding(.vertical, 8)
                } else {
                    MBtn(title: AgentHistoryText.loadLater, icon: "download", kind: .secondary, height: 34) {
                        Task { await transcript.loadLater() }
                    }
                    .fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func loadEarlier() {
        pendingAnchor = transcript.firstItemID
        // 要往前看：不再跟着末尾走。
        transcript.setFollowsTail(false)
        Task { await transcript.loadEarlier() }
    }

    private func subagentLink(_ item: AgentTranscriptItem) -> AgentSubagentLink? {
        guard case .toolCall(let call) = item.kind else { return nil }
        return transcript.subagentLink(for: call)
    }
}

private struct ClaudeTranscriptRow: View {
    let item: AgentTranscriptItem
    let showsRole: Bool
    /// 子代理的记录：「用户」那一侧标成「任务」。
    var inSubagent = false
    /// 回答的一方叫什么（Claude Code 照旧叫「Claude」，别的工具用产品名）。
    var tool: AgentHistoryTool = .claude
    /// 这次调用派出的子代理（找得到记录的才有）。
    let subagent: AgentSubagentLink?
    let onOpenSubagent: (AgentSubagentLink) -> Void
    /// 搜索命中的那一条：整条带底色和左边一道线（画在边界外，不挤动排版）。同 Mac。
    var isHighlighted = false
    @Binding var expanded: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if showsRole {
                Text(AgentHistoryText.roleLabel(item.role, inSubagent: inSubagent, tool: tool))
                    .font(M.sans(12, weight: .semibold)).foregroundStyle(M.text3)
                    .padding(.top, 6)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: MRadius.md, style: .continuous)
                    .fill(M.accent.opacity(0.12))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5).fill(M.accent).frame(width: 3)
                    }
                    .padding(.horizontal, -8)
                    .padding(.vertical, -5)
            }
        }
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .userText(let text):
            MStreamingMarkdown(text: text, isStreaming: false)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: MRadius.md, style: .continuous).fill(M.fillFaint))
                .modifier(CopyMenu(text: item.plainText))
        case .assistantText(let text):
            MStreamingMarkdown(text: text, isStreaming: false)
                .textSelection(.enabled)
        case .command(let command):
            Text(verbatim: command)
                .font(M.mono(13, weight: .medium)).foregroundStyle(M.text)
                .textSelection(.enabled)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: MRadius.sm, style: .continuous).fill(M.fillFaint))
        case .commandOutput(let output):
            ClaudeClippedBlock(id: item.id, label: String(localized: "输出"), text: output, isError: false,
                               expanded: $expanded)
        case .notice(let text):
            Label { Text(verbatim: text) } icon: { Image(systemName: "bell") }
                .font(M.sans(12.5)).foregroundStyle(M.text3)
                .lineLimit(3)
        case .thinking(let text):
            DisclosureGroup(isExpanded: binding("\(item.id).thinking")) {
                Text(verbatim: text.text + (text.isClipped ? "\n…" : ""))
                    .font(M.sans(13)).italic().foregroundStyle(M.text3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            } label: {
                Label(String(localized: "思考"), systemImage: "brain")
                    .font(M.sans(12.5, weight: .medium)).foregroundStyle(M.text3)
            }
            .tint(M.text3)
        case .toolCall(let call):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11)).foregroundStyle(M.text3)
                    Text(verbatim: call.name)
                        .font(M.mono(12.5, weight: .semibold)).foregroundStyle(M.text2)
                    Text(verbatim: call.summary)
                        .font(M.mono(12.5)).foregroundStyle(M.text3)
                        .lineLimit(1).truncationMode(.tail)
                }
                if let subagent {
                    ClaudeSubagentEntry(link: subagent) { onOpenSubagent(subagent) }
                        .padding(.leading, 18)
                }
                if let result = call.result {
                    ClaudeClippedBlock(id: item.id, label: AgentHistoryText.resultLabel(result), text: result.content,
                                       isError: result.isError, expanded: $expanded)
                        .padding(.leading, 18)
                }
            }
        case .toolResult(let result):
            ClaudeClippedBlock(id: item.id, label: AgentHistoryText.resultLabel(result), text: result.content,
                               isError: result.isError, expanded: $expanded)
        case .image:
            Label(String(localized: "图片（不显示）"), systemImage: "photo")
                .font(M.sans(12.5)).foregroundStyle(M.text3)
        case .compactSummary(let summary):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Rectangle().fill(M.divider).frame(height: 1)
                    Text("上下文已压缩")
                        .font(M.sans(12, weight: .medium)).foregroundStyle(M.text3)
                        .fixedSize()
                    Rectangle().fill(M.divider).frame(height: 1)
                }
                ClaudeClippedBlock(id: item.id, label: String(localized: "压缩摘要"), text: summary, isError: false,
                                   expanded: $expanded)
            }
            .padding(.vertical, 6)
        case .oversized(let bytes):
            Label(AgentHistoryText.oversized(bytes), systemImage: "exclamationmark.circle")
                .font(M.sans(12.5)).foregroundStyle(M.text3)
        }
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }
}

/// 派子代理的调用下面的入口：点进去看那个子代理自己的记录。同 Mac。
private struct ClaudeSubagentEntry: View {
    let link: AgentSubagentLink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(M.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AgentHistoryText.subagentEntry)
                        .font(M.sans(13.5, weight: .medium)).foregroundStyle(M.accent)
                    let detail = AgentHistoryText.subagentEntryDetail(link)
                    if !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(M.sans(11.5)).foregroundStyle(M.text3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                MIcon(name: "chev", size: 11, color: M.text4, weight: .semibold)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: M.minTarget)
            .background(RoundedRectangle(cornerRadius: MRadius.md, style: .continuous).fill(M.fillFaint))
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// 标题旁的「正在更新」：这份对话最近还在变（会话开着）。同 Mac。
private struct ClaudeUpdatingBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(M.success).frame(width: 6, height: 6)
            Text(AgentHistoryText.updating)
                .font(M.sans(11, weight: .medium)).foregroundStyle(M.success)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(M.success.opacity(0.12)))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// 往上翻着时末尾来了新内容：底部的「有新消息」，点了跳到底。同 Mac。
private struct ClaudeNewMessagesPill: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down").font(.system(size: 12, weight: .semibold))
                Text(AgentHistoryText.newMessages).font(M.sans(13.5, weight: .medium))
            }
            .foregroundStyle(M.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            // 浮层的底色（浅色下是白的），同 Mac。
            .background(Capsule().fill(M.overlay))
            .overlay(Capsule().strokeBorder(M.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 5, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(MPressStyle())
    }
}

/// 长按拷贝一段消息的文字（文字选择在手机上不好拖到整段）。
private struct CopyMenu: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content.mContextMenu(preview: RoundedRectangle(cornerRadius: MRadius.md, style: .continuous)) {
            Button { UIPasteboard.general.string = text } label: {
                Label("拷贝文字", systemImage: "doc.on.doc")
            }
        }
    }
}

/// 折叠的长文字（工具结果、命令输出、压缩摘要）：默认收起；展开先给前几行，再点才给全部（仍有上限）。同 Mac。
private struct ClaudeClippedBlock: View {
    let id: String
    let label: String
    let text: AgentClippedText
    let isError: Bool
    @Binding var expanded: Set<String>

    private var openKey: String { "\(id).open" }
    private var fullKey: String { "\(id).full" }

    var body: some View {
        DisclosureGroup(isExpanded: binding(openKey)) {
            VStack(alignment: .leading, spacing: 6) {
                let showsAll = expanded.contains(fullKey)
                let preview = text.preview(lines: AgentTranscriptLimits.previewLines,
                                           characters: AgentTranscriptLimits.previewCharacters)
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: showsAll ? text.text : preview)
                        .font(M.mono(12)).foregroundStyle(isError ? M.danger : M.text2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: MRadius.sm, style: .continuous).fill(M.fillFaint))
                if !showsAll, preview.count < text.text.count {
                    Button(AgentHistoryText.showAll(text.text.count)) { expanded.insert(fullKey) }
                        .font(M.sans(12.5))
                }
                if text.isClipped, showsAll || preview.count >= text.text.count {
                    Text(AgentHistoryText.clippedNote(text))
                        .font(M.sans(12)).foregroundStyle(M.text4)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(label)
                .font(M.sans(12.5, weight: .medium)).foregroundStyle(isError ? M.danger : M.text3)
        }
        .tint(M.text3)
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(key) },
                set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } })
    }
}

// MARK: - 状态

private struct ClaudeHistoryProgress: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(text).font(M.sans(13.5)).foregroundStyle(M.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClaudeHistoryState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            MIcon(name: icon, size: 30, color: M.text4, weight: .light)
                .frame(width: 64, height: 64)
                .background(M.fillFaint)
                .clipShape(Circle())
            Text(title).font(M.sans(16, weight: .semibold)).foregroundStyle(M.text)
            Text(message).font(M.sans(13.5)).foregroundStyle(M.text3)
                .multilineTextAlignment(.center).lineSpacing(2)
                .frame(maxWidth: 320)
            if let actionTitle, let action {
                MBtn(title: actionTitle, icon: "refresh", kind: .tinted, height: 40, action: action)
                    .fixedSize()
                    .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
