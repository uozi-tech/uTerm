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
/// 配对的 Mac 认得 `codeTabAction` 时请它在它自己的 Code 标签页里开，再经镜像出现在这里（`ClaudeHistoryTab+MacActions`）；
/// 老 Mac 照旧经接管开终端标签页（接管会把那台 Mac 的终端都镜像成标签页，放进这里会重复）。
/// 直连主机的 Code 标签页还可以镜像接管着的那台 Mac 上这台主机的 Code 标签页（`mirrorClient`）：镜像过来的会话和这边起的
/// 放在一起，Mac 认得 `code-tab-hosts` 时「继续」「＋」请 Mac 做，否则照旧在这边起。
///
/// 列表与记录只在内存里：不落盘、不进 iCloud。直连主机的 Code 标签页连同里面跑着的会话记进归档
/// （`MobileTerminalTabArchive`，只记是哪台主机、哪些会话、看着哪一个），App 被系统结束后照原样开回来、会话接回它里面
/// （`restoreRuns`）；配对的 Mac 的不记（归档只管直连主机）。一台主机（一台 Mac）至多一个，再开就带到前台。
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
    /// 「＋」弹出的新会话面板（选目录、选工具）。开着时不为 nil。放在标签上：横竖屏切换换外壳时面板不跟着丢。
    var newSessionDraft: CodeNewSessionDraft?

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
    /// 每个 run 起的时候的命令（不带后面接的 `; exit`）：「重新开始」照原样再起一次。重新打开后接回的没有（按记录现算）。
    @ObservationIgnored var runStartCommands: [UUID: String] = [:]
    /// 对新会话记录时在主机上看到的记录（列表里可能还没有），按路径。
    @ObservationIgnored var matchedFiles: [String: AgentHistorySessionFile] = [:]
    @ObservationIgnored var runTyping: [UUID: Task<Void, Never>] = [:]
    /// 有会话在跑时隔一会儿去主机上看一眼（新会话认记录、跑着的会话的标题，见 `pollNewSessionsIfNeeded`）。
    @ObservationIgnored var newSessionPoll: Task<Void, Never>?
    /// 建 run 连接用的容器与主机密钥裁决（第一次起 run 时由界面交进来，重试沿用）。
    @ObservationIgnored var runContainer: ModelContainer?
    @ObservationIgnored var runRelay: HostKeyChallengeRelay?
    /// App 重新打开后要还原的「详情看的是哪一个」：列表读出来之后还原（`applyRestoredState`），用户先点了别的就作废。
    var restoredSelection: CodeRestoredSelection?
    /// 镜像着接管的那台 Mac 上的哪个 Code 标签页（`ClaudeHistoryTab+Mirror`）；nil = 没在镜像。
    var mirroredMacTabID: UUID?
    /// 是接管时为了镜像才开出来的：Mac 上那个 Code 标签页没了就跟着关。用户自己开的（「＋」、终端标签长按）不关。
    var opensForMirror = false
    /// 镜像着哪台 Mac 的 Code 标签页（`ClaudeHistoryTab+Mirror`）。配对的 Mac 的标签页就是 `remoteMac`；直连主机的标签页
    /// 镜像那台 Mac 上这台主机的 Code 标签页时是那台 Mac（记录照旧经这边自己的 SSH 读，见 `remoteMac`），不镜像时为 nil。
    @ObservationIgnored weak var mirrorClient: RemoteMacClient?
    /// 接管时在后台开出来、还没露出来过：等第一次露出来再连（`startIfDeferred`），接管时不去连一台用户不一定看的主机。
    @ObservationIgnored var startsWhenShown = false
    /// 镜像着的会话上点了「结束会话」：请那台 Mac 结束它（`RemoteMacClient.closeSessionOnMac`，消息 8）。测试换成记下来的。
    @ObservationIgnored var endOnMac: @MainActor (UUID) -> Void = { _ in }
    /// 请那台 Mac 在它的 Code 标签页里做一件事（`RemoteMacClient.performCodeTabAction`，消息 64），返回做完之后的会话 id。
    /// 测试换成假的（`ClaudeHistoryTab+MacActions`）。
    @ObservationIgnored var macCodeTabAction: @MainActor (RemoteCodeTabAction) async throws -> UUID = { _ in
        throw RemoteProtocolError.closed
    }
    /// 那台 Mac 认不认得 `codeTabAction`（`RemoteMacClient.supportsCodeTabActions`，握手时定）。测试换成固定的。
    @ObservationIgnored var macSupportsCodeTabActions: @MainActor () -> Bool = { false }
    /// 那台 Mac 能不能在 SSH 主机的 Code 标签页里做事（`RemoteMacClient.supportsCodeTabHosts`）。测试换成固定的。
    @ObservationIgnored var macSupportsCodeTabHosts: @MainActor () -> Bool = { false }
    /// 有一个请 Mac 做的事还没回复：这时再点不再发（`ClaudeHistoryTab+MacActions`）。
    var macActionInFlight = false
    /// 请 Mac 做完了、回复里的那个会话还没出现在这里（Mac 推来的 Code 标签页晚于回复到）：出现时选上它。
    var pendingMacFocus: UUID?
    @ObservationIgnored var pendingMacFocusExpiry: Task<Void, Never>?

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
            followsCurrentProject: false, pinHost: { [id = host.id] in .server(id) },
            connect: AgentHistoryAccess.server(host, container: container)))
    }

    /// 配对过的 Mac：读它上面的记录。远控协议里没有终端的当前目录，不定位。
    convenience init(pairedMac client: RemoteMacClient) {
        self.init(host: client.filesTabHost,
                  connection: AgentHistoryConnection(preferredDirectory: nil, tools: AgentHistoryTool.allCases,
                                                     followsCurrentProject: false,
                                                     // 握手后才知道那台 Mac 的设备 ID（同 Mac 那头按它记置顶）。
                                                     pinHost: { client.macDeviceID.map(AgentHistoryPinHost.pairedMac) },
                                                     connect: AgentHistoryAccess.pairedMac(client)),
                  remoteMac: client)
        attachMirror(client)
    }

    /// 镜像起这台 Mac 的 Code 标签页：「结束会话」、请 Mac 做的事都发给它。配对的 Mac 开标签页时就接上；直连主机的标签页
    /// 由工作区在第一次接上那台 Mac 上这台主机的 Code 标签页时接上（`MobileWorkspace.follow`）。
    func attachMirror(_ client: RemoteMacClient) {
        mirrorClient = client
        endOnMac = { [weak client] session in client?.closeSessionOnMac(session) }
        macCodeTabAction = { [weak client] action in
            guard let client else { throw RemoteProtocolError.closed }
            return try await client.performCodeTabAction(action)
        }
        macSupportsCodeTabActions = { [weak client] in client?.supportsCodeTabActions ?? false }
        macSupportsCodeTabHosts = { [weak client] in client?.supportsCodeTabHosts ?? false }
    }

    /// 能不能「继续这个会话」「＋新会话」：要在那台主机上开终端。仅 SFTP 的主机开不了；配对的 Mac 要认得「新建本机终端」。
    var canResume: Bool {
        if let remoteMac { return remoteMac.supportsLocalShell || runsOnMacCodeTab }
        return !host.sftpOnly
    }

    /// 从终端标签再来一次（标签已经开着）：记下终端现在的目录，列表定位到它那一组。不知道目录就什么都不做。
    func reveal(directory: String?) {
        guard let directory else { return }
        self.directory = directory
        revealGeneration += 1
        pendingReveal = AgentHistoryReveal(directory: directory, generation: revealGeneration)
    }

    /// 「＋」：弹出新会话面板。候选目录现算（`AgentHistoryNewSessionPlaces.candidates`：这个标签页的目录、记录的项目目录、
    /// 主目录）；配对的 Mac 再问它最近的工作区（老 Mac 不认就没有），问回来补进去。
    func presentNewSession() {
        let draft = CodeNewSessionDraft(directory: directory, choices: newSessionChoices(recent: []),
                                        home: connection.homeDirectory)
        newSessionDraft = draft
        guard let remoteMac, remoteMac.supportsLocalShell else { return }
        Task { [weak self, weak draft] in
            guard let workspaces = await remoteMac.localWorkspaces(), let self, let draft,
                  self.newSessionDraft === draft else { return }
            draft.home = draft.home ?? workspaces.home
            draft.choices = self.newSessionChoices(recent: workspaces.directories, home: draft.home)
        }
    }

    func newSessionChoices(recent: [String], home: String? = nil) -> [String] {
        AgentHistoryNewSessionPlaces.candidates(current: directory, files: connection.history?.files ?? [],
                                                metadata: connection.history?.metadata ?? [:], recent: recent,
                                                home: home ?? connection.homeDirectory)
    }

    /// 面板里选好、点了「开始」：之后「＋」默认开在这个目录（写回 `directory`，随归档存着）。不改列表的定位。
    func chooseNewSessionDirectory(_ directory: String) {
        self.directory = ClaudeProjectPath.normalized(directory) ?? directory
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

    /// 接管时在后台开出来的（`startsWhenShown`）第一次露出来：这时才连。
    func startIfDeferred() {
        guard startsWhenShown else { return }
        startsWhenShown = false
        start()
    }

    func start() {
        startsWhenShown = false
        Task {
            await connection.open()
            applyRestoredState()
        }
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
    /// 请 Mac 在它的 Code 标签页里做的事没做成（`ClaudeHistoryTab+MacActions`）：由工作区屏提示。
    var onFailure: ((CodeActionFailure) -> Void)? = nil
    /// 配对的 Mac 上「继续这个会话」「＋」新会话：在那台 Mac 上开终端标签页跑这条命令（直连的主机就在这个标签页里跑）。
    /// Mac 认得 `codeTabAction` 时不走这里，请它在它的 Code 标签页里开。
    var onRun: (_ command: String, _ directory: String) -> Void

    @Environment(\.modelContext) private var context
    /// 可选：只挂列表的用例里没有注入。没有就退回 `onRun`。
    @Environment(HostKeyChallengeRelay.self) private var relay: HostKeyChallengeRelay?
    @Environment(MobileWorkspace.self) private var workspace: MobileWorkspace?
    @Environment(MobileStore.self) private var store: MobileStore?

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
                    // 「＋」不直接开：弹出新会话面板选目录、选工具（见 `CodeNewSessionPanel`）。
                    newSession: tab.canResume ? AgentHistoryNewSession(presenting: { tab.presentNewSession() }) : nil,
                    reveal: Binding(get: { tab.pendingReveal }, set: { tab.pendingReveal = $0 }),
                    code: codeRuns) { file in
                    resume(file, in: history)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(M.surface, ignoresSafeAreaEdges: .mSessionBody)
        // 接管时在后台开出来的直连主机标签页：第一次露出来才连那台主机。
        .onChange(of: isActive, initial: true) { _, active in if active { tab.startIfDeferred() } }
        .mBottomPanel(item: Binding(get: { tab.newSessionDraft }, set: { tab.newSessionDraft = $0 })) { draft in
            if let history = tab.connection.history {
                CodeNewSessionPanel(draft: draft, history: history, connection: tab.connection, hostName: tab.hostName) {
                    tool, directory in
                    startNewSession(tool, in: directory, history: history)
                }
            }
        }
    }

    /// 交给列表与详情的跑着的会话。「移到新标签页」：镜像那台 Mac 的请 Mac 挪（`moveMirroredRunToTab`），其余就地挪。
    private var codeRuns: CodeTabRuns {
        let runs = CodeTabRuns(tab: tab, isFocused: isFocused, onInteract: onInteract, onFailure: onFailure)
        guard let workspace else { return runs }
        var withMove = runs
        withMove.onMoveToTab = { [weak workspace] id in
            guard let workspace else { return }
            if tab.runs.run(id: id)?.isMirrored == true {
                runs.perform(failureTitle: String(localized: "无法移到新标签页")) {
                    try await tab.moveMirroredRunToTab(id, in: workspace)
                }
            } else {
                _ = tab.moveRunToTab(id, in: workspace)
            }
        }
        return withMove
    }

    /// 面板里点了「开始」：收起面板，在选的目录里起选的工具（直连主机在这个标签页里，配对的 Mac 在它的 Code 标签页里
    /// 或者开终端标签页）。
    private func startNewSession(_ tool: AgentHistoryTool, in directory: String, history: AgentHistoryModel) {
        guard let command = history.newSessionCommand(tool: tool, directory: directory) else { return }
        tab.chooseNewSessionDirectory(directory)
        tab.newSessionDraft = nil
        startNew(tool, command: command, directory: directory)
    }

    /// 直连主机：就在这个标签页里起终端；配对的 Mac 认得 `codeTabAction` 就请它在它的 Code 标签页里开
    /// （`ClaudeHistoryTab+MacActions`），否则（或者没注入主机密钥裁决的用例）交给 `onRun` 开终端标签页。
    private func resume(_ file: AgentHistorySessionFile, in history: AgentHistoryModel) {
        // 这份记录正在那台 Mac 的 Code 标签页里跑着（镜像过来的）：回到它的终端，不在 Mac 上再开一个。
        if tab.focusRunningMirror(for: file) { return }
        guard let plan = history.resumeCommand(for: file) else { return }
        if tab.runsOnMacCodeTab {
            let (workspace, store) = (workspace, store)
            CodeTabRuns(tab: tab, onFailure: onFailure).perform(failureTitle: String(localized: "无法继续这个会话")) {
                try await tab.resumeOnMac(file, directory: plan.directory, workspace: workspace, store: store)
            }
        } else if tab.runsInPlace, let relay {
            tab.resumeInPlace(file, command: plan.command, directory: plan.directory,
                              container: context.container, relay: relay)
        } else {
            onRun(plan.command, plan.directory)
        }
    }

    private func startNew(_ tool: AgentHistoryTool, command: String, directory: String) {
        if tab.runsOnMacCodeTab {
            let (workspace, store) = (workspace, store)
            CodeTabRuns(tab: tab, onFailure: onFailure).perform(failureTitle: String(localized: "无法继续这个会话")) {
                try await tab.startOnMac(tool: tool, directory: directory, workspace: workspace, store: store)
            }
        } else if tab.runsInPlace, let relay {
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
    /// 请 Mac 做的事没做成（`ClaudeHistoryTab+MacActions`）。
    var onFailure: ((CodeActionFailure) -> Void)? = nil

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
                ClaudeHistoryList(history: history, newSession: newSession, reveal: reveal, code: code,
                                  onResume: canResume ? onResume : nil)
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
                                         onBackToTerminal: level.subagent == nil ? backToTerminal(for: level.file) : nil,
                                         continuation: level.subagent == nil ? history.continuationLink(of: level.file) : nil,
                                         onOpenPart: { history.select($0) })
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
    /// Code 标签页里跑着的会话：不另起一块，就在它那份记录平常的那一行上（置顶了在「置顶」，否则在它那一组），
    /// 行上标它此刻的状态，点一下回到它的终端；列表里没有行的（还没对上记录的新会话）放在列表最顶上。
    /// 规则同 Mac（`AgentHistoryRunPlacement`）。
    var code: CodeTabRuns? = nil
    /// 继续一个会话（长按菜单里那一项）；nil = 这台主机继续不了，不出。
    var onResume: ((AgentHistorySessionFile) -> Void)? = nil

    @AppStorage(DefaultsKey.agentHistoryGrouping) private var groupingRaw = AgentHistoryGrouping.default.rawValue
    @AppStorage(DefaultsKey.agentHistoryShownTools) private var shownToolsRaw = ""
    /// 看着的那个跑着的会话那份记录还没露出来（它那一组收着、还没列到）：列表变了再试，见 `tryRevealRun`。
    @State private var pendingRunReveal: String?
    /// 点了「删除会话…」、等确认的那一份。
    @State private var pendingDelete: AgentHistorySessionFile?
    /// 删不掉时的原因。
    @State private var deleteFailure: String?

    private var grouping: AgentHistoryGrouping {
        AgentHistoryListPreferences.effectiveGrouping(groupingRaw, isMultiTool: history.isMultiTool)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶上那一行下面不画横线（同 Mac 的 Code 标签页）。
            header
            searchBar
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
        .onChange(of: history.pins?.keys) { _, _ in history.readPinnedMetadata() }
        .alert(AgentHistoryText.deleteConfirmTitle, isPresented: Binding(get: { pendingDelete != nil },
                                                                        set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { file in
            Button(AgentHistoryText.deleteConfirmButton, role: .destructive) { delete(file) }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: { file in
            Text(AgentHistoryText.deleteConfirmMessage(title: AgentHistoryText.sessionTitle(file, metadata: history.metadata[file.path])))
        }
        .alert(AgentHistoryText.deleteFailedTitle, isPresented: Binding(get: { deleteFailure != nil },
                                                                       set: { if !$0 { deleteFailure = nil } })) {
            Button(String(localized: "好")) {}
        } message: {
            Text(verbatim: deleteFailure ?? "")
        }
    }

    private func delete(_ file: AgentHistorySessionFile) {
        Task {
            do {
                try await history.delete(file)
            } catch {
                deleteFailure = FriendlyError.describe(error)
            }
        }
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
                // 只管分组方式与「显示」，不清置顶。
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

    /// 「＋」：Code 标签页里弹出新会话面板（在那里选目录、选工具）；只挂列表的地方照旧是菜单——能开的工具在里面选，
    /// 开不了（不知道目录、这台主机上的工具都不能新开）时菜单里说明原因，手机上没有悬停提示，灰掉的按钮说不清为什么。
    @ViewBuilder private func newSessionButton(_ newSession: AgentHistoryNewSession) -> some View {
        if let present = newSession.present {
            Button(action: present) {
                MIcon(name: "plus", size: 15, color: M.text2, weight: .semibold)
                    .frame(width: M.minTarget, height: M.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel(Text(AgentHistoryText.newSession))
        } else {
            newSessionMenu(newSession)
        }
    }

    private func newSessionMenu(_ newSession: AgentHistoryNewSession) -> some View {
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
            let pinned = history.pinnedFiles
            // 还在列目录，或者读过的那几份都不用列、后面还有没读的：接着等，别急着说「没有」。
            let hasRuns = !(code?.board.runs.isEmpty ?? true)
            if files.isEmpty && pinned.isEmpty && !hasRuns && (history.isListing || history.hasMore) {
                ClaudeHistoryProgress(text: String(localized: "正在读取会话列表…"))
            } else if files.isEmpty && pinned.isEmpty && (code?.board.runs.isEmpty ?? true) {
                ClaudeHistoryState(icon: "clock", title: String(localized: "没有命令行会话"),
                                   message: AgentHistoryText.emptyListDetail(hidden: history.hiddenCount))
            } else {
                list(files, pinned: pinned)
            }
        }
    }

    private func list(_ files: [AgentHistorySessionFile], pinned: [AgentHistorySessionFile]) -> some View {
        let groups = AgentHistoryListing.groups(files, by: grouping, metadata: history.metadata, pinned: pinned,
                                                date: { history.liveActivity(of: $0) ?? $0.modifiedAt })
        // 跑着的会话（含已结束、留着画面的）不另起一块：有记录的在那一行上（置顶或它那一组）；还没有记录行的（刚开的
        // 新会话）在它那一组的最上面，哪一组都对不上的才在最顶上（同 Mac）。
        let placement = AgentHistoryRunPlacement(runs: code?.board.runs ?? [], path: \.sessionPath, directory: \.directory,
                                                 tool: \.tool, groups: groups)
        let focusedRunPath = code?.board.focused?.sessionPath
        // 看着的新会话放在哪一组（它那一组收着就打开）。
        let focusedID = code?.board.focusedID
        let focusedLeadingGroup = placement.groupID(ofLeading: { $0.id == focusedID })
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let code {
                        ForEach(placement.top) { run in
                            unlistedRunRow(run, code: code, showsTool: history.isMultiTool)
                        }
                    }
                    ForEach(groups) { group in
                        let collapsed = history.collapsedGroups.contains(group.id)
                        if AgentHistoryListing.showsHeader(group, in: groups) {
                            ClaudeHistoryGroupHeader(group: group, collapsed: collapsed,
                                                     runs: collapsed ? placement.runs(in: group).map {
                                                         CodeRunStatus.of(isEnded: !$0.isRunning, report: $0.terminal.programReport)
                                                     } : []) {
                                toggle(group.id)
                            }
                            .id(group.id)
                        }
                        if !collapsed {
                            let showsTool = group.mixesTools
                            if let code {
                                ForEach(placement.leading(in: group)) { run in
                                    unlistedRunRow(run, code: code,
                                                   showsTool: showsTool || group.files.contains { $0.tool != run.tool })
                                }
                            }
                            ForEach(group.files) { file in
                                row(file, in: group, showsTool: showsTool, run: placement.inList[file.path])
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
            // 看着一个跑着的会话（新会话刚对上记录、重新打开后还原……）：它那一组收着就打开。
            .onChange(of: focusedRunPath, initial: true) { _, path in
                pendingRunReveal = path
                tryRevealRun(groups, proxy: proxy)
            }
            .onChange(of: focusedLeadingGroup, initial: true) { _, id in
                if let id { history.collapsedGroups.remove(id) }
            }
            .onChange(of: groups.map(\.id)) { _, _ in
                tryReveal(groups, proxy: proxy)
                tryRevealRun(groups, proxy: proxy)
            }
        }
    }

    /// 跑着、列表里没有它记录行的会话那一行（列表最顶上，或者它那一组的最上面）。
    private func unlistedRunRow(_ run: CodeRunBoard<TermTab>.Run, code: CodeTabRuns, showsTool: Bool) -> some View {
        Button { code.tab.focusRun(run.id) } label: {
            CodeUnlistedRunRow(code: code, run: run, showsTool: showsTool,
                               selected: code.board.focusedID == run.id && run.showsTerminal)
        }
        .buttonStyle(MPressStyle())
        .modifier(ClaudeHistoryRowMenu(pins: nil, file: nil, isRunning: run.isRunning) {
            code.tab.endRun(run.id)
        })
    }

    /// 一行会话：点一下看它；长按菜单「置顶」/「取消置顶」（iOS 不做拖动排序：会和滚动、标签拖动抢手势），在跑的还有「结束会话」。
    /// `run`：这份记录正在 Code 标签页里跑着——行上写它此刻的状态，点一下回到它的终端（同最顶上那几行）。
    private func row(_ file: AgentHistorySessionFile, in group: AgentHistoryGroup, showsTool: Bool,
                     run: CodeRunBoard<TermTab>.Run?) -> some View {
        let showsItsTerminal = run.map { code?.board.focusedID == $0.id && $0.showsTerminal } ?? false
        return Button {
            if let code, let run {
                code.tab.focusRun(run.id)
            } else if let code {
                code.tab.select(file)
            } else {
                history.select(file)
            }
        } label: {
            ClaudeHistoryRow(history: history, file: file, metadata: history.metadata[file.path],
                             showsProject: grouping != .project || group.kind == .pinned, showsTool: showsTool,
                             run: run, isSelected: showsItsTerminal || history.selectedFile?.path == file.path)
        }
        .buttonStyle(MPressStyle())
        .modifier(ClaudeHistoryRowMenu(pins: history.pins, file: file, isRunning: run?.isRunning == true,
                                       canDelete: history.canDelete(file), onResume: onResume,
                                       onDelete: { pendingDelete = $0 }) {
            if let code, let run { code.tab.endRun(run.id) }
        })
    }

    /// 看着的那个跑着的会话那一行在一个收着的组里：打开那一组、滚到它（不收着就不动）。那份记录还没列到的，等列表变了再试。
    private func tryRevealRun(_ groups: [AgentHistoryGroup], proxy: ScrollViewProxy) {
        guard let path = pendingRunReveal, let id = AgentHistoryListing.groupID(ofRecord: path, in: groups) else { return }
        pendingRunReveal = nil
        guard history.collapsedGroups.contains(id) else { return }
        history.collapsedGroups.remove(id)
        // 行的 id 就是记录的路径（`AgentHistorySessionFile.id`）。
        Task { @MainActor in proxy.scrollTo(path) }
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

/// 行的长按菜单（项目与顺序见共享的 `AgentHistorySessionMenuItem`，同 Mac 的右键菜单）：有记录的「继续这个会话」
/// 「置顶」/「取消置顶」「拷贝会话 ID」「删除会话…」，在 Code 标签页里跑着的「置顶」「结束会话」。一项都没有时没有菜单。
struct ClaudeHistoryRowMenu: ViewModifier {
    typealias Item = AgentHistorySessionMenuItem

    /// nil = 这个列表不能置顶（没有主机标识）。
    let pins: AgentHistoryPins?
    /// nil = 没有记录的行（列表最顶上还没对上记录的新会话），不能置顶。
    let file: AgentHistorySessionFile?
    /// 在 Code 标签页里跑着（已结束的那一行上有「回到记录」「关闭」，不再出「结束会话」）。
    let isRunning: Bool
    /// 能不能删这一份（它那种工具的数据源能删）。
    var canDelete = false
    /// 继续这个会话；nil = 不出这一项。
    var onResume: ((AgentHistorySessionFile) -> Void)? = nil
    /// 点了「删除会话…」：交给列表去确认。
    var onDelete: (AgentHistorySessionFile) -> Void = { _ in }
    let onEnd: () -> Void

    func body(content: Content) -> some View {
        let pinned = file.map { pins?.isPinned($0) ?? false } ?? false
        let items = Item.items(hasRecord: file != nil, canResume: onResume != nil, canPin: pins != nil && file != nil,
                               isPinned: pinned, isRunning: isRunning, canDelete: canDelete)
        if items.isEmpty {
            content
        } else {
            content.mContextMenu(preview: RoundedRectangle(cornerRadius: MRadius.md, style: .continuous)) {
                ForEach(items, id: \.self) { item in
                    if item.isDestructive, items.count > 1 { Divider() }
                    button(item)
                }
            }
        }
    }

    @ViewBuilder private func button(_ item: Item) -> some View {
        switch item {
        case .resume:
            Button {
                if let file { onResume?(file) }
            } label: {
                Label(AgentHistoryText.resumeSession, systemImage: "play")
            }
        case .pin(let isPinned):
            Button {
                if let pins, let file { withAnimation(.easeOut(duration: 0.2)) { pins.toggle(file) } }
            } label: {
                Label(AgentHistoryText.pinAction(isPinned: isPinned), systemImage: isPinned ? "pin.slash" : "pin")
            }
        case .copySessionID:
            Button {
                if let file { UIPasteboard.general.string = file.sessionID }
            } label: {
                Label(AgentHistoryText.copySessionID, systemImage: "doc.on.doc")
            }
        case .delete:
            Button(role: .destructive) {
                if let file { onDelete(file) }
            } label: {
                Label(AgentHistoryText.deleteSession, systemImage: "trash")
            }
        case .endSession:
            Button(role: .destructive, action: onEnd) {
                Label(AgentHistoryText.endSession, systemImage: "xmark.circle")
            }
        }
    }
}

/// 组标题：折叠箭头、标题、会话数。点一下折起 / 展开。项目组的标题是目录名（不翻译），完整路径给读屏。
private struct ClaudeHistoryGroupHeader: View {
    let group: AgentHistoryGroup
    let collapsed: Bool
    /// 组里跑着的会话的状态（收起时才给）：会话数前面画一个状态点（`CodeRunGroupMark`，同 Mac）。
    var runs: [CodeRunStatus] = []
    let toggle: () -> Void
    @Environment(\.mAccent) private var accent

    var body: some View {
        let mark = CodeRunGroupMark(runs)
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
                if let mark {
                    Circle().fill(dot(mark)).frame(width: 7, height: 7)
                }
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
        .accessibilityLabel(Text(AgentHistoryText.groupAccessibility(group, collapsed: collapsed, runs: mark)))
        .accessibilityHint(Text(verbatim: AgentHistoryText.groupHelp(group) ?? ""))
        .accessibilityAddTraits(.isButton)
    }

    /// 同行上状态的圆点颜色（`CodeRunStatusMark`）；都没报过状态是灰的。
    private func dot(_ mark: CodeRunGroupMark) -> Color {
        if case .program(let record) = mark.status { return WorkspaceTabChip.color(for: record.tone, accent: accent) }
        return M.text4
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

    /// 结果里不止一种工具：每个会话的第二行最前面写工具名（同列表的行）。
    private var showsTool: Bool { AgentHistoryListing.mixesTools(search.sessions.map(\.file)) }

    private func group(_ session: AgentHistorySearchSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AgentHistoryText.sessionTitle(session.file, metadata: session.metadata))
                    .font(M.sans(15, weight: .semibold)).foregroundStyle(M.text)
                    .lineLimit(1)
                AgentSessionTimeText(history: history, file: session.file) { activity in
                    AgentHistoryText.searchSessionDetail(session, showsProject: history.scope == .all,
                                                         showsTool: showsTool, activity: activity)
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

/// 会话一行：标题，第二行（组里不止一种工具时）工具名 · 时间 · 大小 · 分支 ·（不按项目分组时）项目。行前不画工具标记（同 Mac）。
private struct ClaudeHistoryRow: View {
    let history: AgentHistoryModel
    let file: AgentHistorySessionFile
    let metadata: AgentHistorySessionMetadata?
    let showsProject: Bool
    /// 组里不止一种工具：第二行最前面写工具名。
    var showsTool = false
    /// 在 Code 标签页里继续着的那个 run：第二行前面是它此刻的状态（`CodeRunStatusMark`）。
    var run: CodeRunBoard<TermTab>.Run? = nil
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AgentHistoryText.sessionTitle(file, metadata: metadata))
                    .font(M.sans(15, weight: .medium)).foregroundStyle(M.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if let run { CodeRunStatusMark(run: run) }
                    AgentSessionTimeText(history: history, file: file) { activity in
                        AgentHistoryText.sessionSubtitle(file, metadata: metadata, showsProject: showsProject,
                                                         showsTool: showsTool, activity: activity)
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
    /// 这份记录是「接着往下聊」串起来的几份之一：顶上给一条，能翻到之前 / 后来那段（同 Mac）。
    var continuation: AgentHistoryContinuation.Link? = nil
    var onOpenPart: (AgentHistorySessionFile) -> Void = { _ in }

    @State private var expanded: Set<String> = []
    @State private var pendingAnchor: String?

    var body: some View {
        VStack(spacing: 0) {
            // 标题行下面不画横线（同 Mac 的 Code 标签页）。
            header
            if transcript.opensAtHit, !transcript.reachedEnd {
                hitBanner
                Rectangle().fill(M.divider).frame(height: 1)
            }
            if let continuation {
                continuationBanner(continuation)
                Rectangle().fill(M.divider).frame(height: 1)
            }
            messages
        }
    }

    /// 「接着往下聊」串起来的另一段：顶上说一句，给按钮翻过去。同 Mac。
    private func continuationBanner(_ link: AgentHistoryContinuation.Link) -> some View {
        let target: AgentHistorySessionFile
        let isPrevious: Bool
        switch link {
        case .previous(let file): target = file; isPrevious = true
        case .next(let file): target = file; isPrevious = false
        }
        return HStack(spacing: 8) {
            Text(AgentHistoryText.continuationNotice(link))
                .font(M.sans(12.5)).foregroundStyle(M.text2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            MBtn(title: AgentHistoryText.continuationAction(link), icon: isPrevious ? "upload" : "download",
                 kind: .secondary, height: 32, action: { onOpenPart(target) })
                .fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(M.fillFaint)
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
                MBtn(title: AgentHistoryText.backToTerminal, icon: "term", kind: .tinted, height: 34, action: onBackToTerminal)
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
            MTranscriptMarkdown(text: text)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: MRadius.md, style: .continuous).fill(M.fillFaint))
                .modifier(CopyMenu(text: item.plainText))
        case .assistantText(let text):
            MTranscriptMarkdown(text: text)
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
/// 记录里的一段 Markdown：第一次排版就是解析好的样子（同 Mac 的 `AgentTranscriptMarkdown`）。
///
/// 不用 `MStreamingMarkdown`：它在 `onAppear` 里才解析，没出现过的行懒栈都按空文档量高（120 条：内容高 5471pt，实际一万五以上）。
/// 往回翻时一行行出现、一行行长到真实高度，内容总高度在滚动中一次变上万点，偏移被拽到别处、画面整屏换掉
/// （`ClaudeTranscriptScrollProbeTests`）。记录里的文字是落定的，这里在 body 里同步取解析结果；两端共用一份缓存。
private struct MTranscriptMarkdown: View {
    let text: String

    var body: some View {
        MMarkdownBlocks(document: MarkdownDocumentCache.transcript.document(for: text))
    }
}

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

/// App 重新打开后 Code 标签页详情要还原的那一个（`ClaudeHistoryTab.restoredSelection`）。
nonisolated enum CodeRestoredSelection: Equatable, Sendable {
    /// 一个跑着的会话（`CodeRunBoard.Run.id`）；`showsTranscript`：看的是它的记录。
    case run(UUID, showsTranscript: Bool)
    /// 一份只读记录。
    case record(AgentHistoryPinKey)
}
