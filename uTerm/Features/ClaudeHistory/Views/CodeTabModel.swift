import Foundation
import Observation

/// Code 标签页里跑着一个会话的那个终端：SSH 窗口里是 `PaneModel`，本机终端窗口里是 `LocalShellPane`。
/// 它是真的终端会话（登记进注册表、写保持进程的归属），只是不单独占一个标签页，挂在 Code 标签页的右边。
///
/// 只要这几样，不碰终端引擎与界面：`CodeTabModel` 因此不沾 AppKit / UIKit，两端以后可以共用一份（iOS 的终端换成它自己的实现）。
@MainActor
protocol CodeTabTerminal: AnyObject {
    var id: UUID { get }
    /// 连上、行编辑器起来之后打进这条命令（继续 / 新开会话）。不包子 shell。
    func runCodeCommand(_ command: String)
    /// 那条命令跑完了（用户退出了编码工具），或者 shell 自己退出了。连接失败不算：面板上给重试。
    var codeCommandHasEnded: Bool { get }
    /// 结束这个终端（关 shell、注销）。
    func dispose()
    /// 那条命令起止标记的编号（存进保持进程的布局，重启后据此认出程序退出）。没有为 nil。
    var codeCommandMarker: String? { get }
    /// 程序经 OSC 7501 报的状态（工作中、等确认、空闲……），同终端标签页上的圆点。没报过为 nil。
    /// 界面在每一行自己的视图里读它：状态变了只重画那一行。
    var codeProgramStatus: ProgramStatusRecord? { get }
    /// App 重启后接回：命令照「还在跑」接上，再判一次程序在 App 不在时是不是已经退出了（规则见
    /// `TerminalSession.restoreCodeCommand`）。
    func restoreCodeCommand(marker: String?, startedAt: Date)
}

extension CodeTabTerminal {
    var codeCommandMarker: String? { nil }
    var codeProgramStatus: ProgramStatusRecord? { nil }
    func restoreCodeCommand(marker: String?, startedAt: Date) {}
}

/// 一个 Code 标签页：左边这台主机上编码工具的历史会话，右边看选中那份记录，或者就在右边接着聊（一个跑着继续命令的终端）。
///
/// 被「继续」过的会话各自留着自己的终端（`runs`）：点侧栏里别的会话不打断正在跑的，点回去就回到它的终端。
/// 终端里的程序退出（用户退出了 Claude）：有对话记录可看的，结束那个终端，回到只读记录（重新读到最新）；没有的（新开了
/// 没说话就退出、记录没写出来或者是空的），终端留着（最后的画面），右边顶上一条「会话已结束」，由用户「重新开始」或「关闭」。
/// App 重启后整个标签页按保持进程里存的布局开回来（`record` 存、`restore` 接回），里面的会话回到它里面。
@MainActor
@Observable
final class CodeTabModel {
    /// 一个在这个标签页里跑着的会话。
    struct Run: Identifiable {
        let terminal: any CodeTabTerminal
        var id: UUID { terminal.id }
        let tool: AgentHistoryTool
        /// 在哪个目录里起的。
        let directory: String
        let startedAt: Date
        /// 对应的记录文件。「＋」新开的会话一开始没有（记录还没写出来或还没列到），对上之后填上（`matchNewSessions`）。
        var path: String?
        /// 起的时候列表里已经有的记录：新会话对记录时不考虑它们。重启后接回的新会话不知道（不存记录的路径），为空。
        let knownPaths: Set<String>
        /// 起的时候那份记录的标题（继续的会话）；新会话为 nil。
        let title: String?
        /// 右边现在看的是它的记录（「终端 / 记录」切到「记录」）。
        var showsTranscript = false
        /// 对应的是哪份记录（工具 + 会话 ID，同置顶的认法）：和 `path` 一起填上，存进布局的就是它。重启后接回的会话
        /// 先只有它，列表读出来之后再找回 `path`（`resolveRestoredRuns`）；找到之前不当新会话去对别的记录。
        var key: AgentHistoryPinKey?
        /// 起它时打的命令（「重新开始」照原样再打一次）。重启后接回的没有（按记录现算，见 `restart`）。
        var command: String?
        /// 是「继续」一份记录起的（不是「＋」新会话）。「重新开始」据此再继续同一份，还是在同一个目录里新开一个。
        var resumesRecord: Bool
        /// 程序已经退出、终端留着给人看（没有对话记录可显示）的时刻。还在跑为 nil。
        var endedAt: Date?

        init(terminal: any CodeTabTerminal, tool: AgentHistoryTool, directory: String, startedAt: Date, path: String?,
             knownPaths: Set<String>, title: String?, showsTranscript: Bool = false, key: AgentHistoryPinKey? = nil,
             command: String? = nil, resumesRecord: Bool? = nil) {
            self.command = command
            self.resumesRecord = resumesRecord ?? (title != nil)
            self.terminal = terminal
            self.tool = tool
            self.directory = directory
            self.startedAt = startedAt
            self.path = path
            self.knownPaths = knownPaths
            self.title = title
            self.showsTranscript = showsTranscript
            self.key = key
        }

        /// 还没对上任何记录的新会话（接回后等着找回记录的不算）。
        var isUnmatched: Bool { path == nil && key == nil }
        /// 程序已经退出（留着最后的画面）。
        var isEnded: Bool { endedAt != nil }
    }

    /// 右边显示什么。
    enum Detail: Equatable {
        /// 什么都没选：「新会话」起始页（选目录、选工具、开始）。侧栏顶上的「＋」也回到这里。
        case empty
        /// 选中那份记录的只读对话。
        case transcript
        /// 一个跑着的会话的终端。
        case terminal(UUID)
    }

    /// 主机名（标签页标题用）。
    let hostName: String
    /// 「新会话」开在哪：打开这个标签页时那个终端的当前目录，起始页上选了别的就是选的那个（随布局存着，重启后还在）。
    /// 不知道为 nil：起始页里选一个就能开。
    var newSessionDirectory: String?
    /// 起始页「选择文件夹…」怎么选：本机用系统的文件夹面板，SSH 主机输入路径。
    let directoryChooser: CodeTabDirectoryChooser
    /// 本机终端最近待过的目录（起始页的候选，接在记录的项目目录后面）。SSH 主机没有。
    @ObservationIgnored var recentDirectories: @MainActor () -> [String]
    private(set) var connection: AgentHistoryConnection?
    private(set) var runs: [Run] = []
    /// 选中的是一个还没对上记录的新会话（它在列表里没有行）。选中有记录的会话走 `AgentHistoryModel.selectedFile`。
    private(set) var selectedRunID: UUID?
    /// 要列表定位到哪个目录（标签页右键「历史会话…」）。
    private(set) var reveal: AgentHistoryReveal?
    /// 拖过的列表宽度。
    var sidebarWidth = CodeTabModel.defaultSidebarWidth
    /// 用户在宽窗口里收起了侧栏。
    var sidebarHidden = false
    /// 窄的时候侧栏点开了：占满整个标签页，右边先让开（选了会话就收回去）。只在窄的时候有意义。
    var sidebarOverlayShown = false

    /// 列表默认宽度（独立历史窗口是 300）。
    nonisolated static let defaultSidebarWidth = 280.0
    /// 多久看一次各个终端的状态（`codeCommandHasEnded`）。Mac 上命令的起止标记（`TerminalTrackedRun`）不参与观察、
    /// 连接状态的回调又被宿主占着，所以轮询；只在有会话在跑时转。
    nonisolated static let checkInterval: Duration = .seconds(1)
    /// 有会话在跑时，隔多久安静地重列一次（不闪「正在读取」）：有新会话还没对上记录时重列全部，都对上了只重列它们所在的
    /// 项目（标题跟着 Claude Code 后来起的名字走）。
    nonisolated static let refreshInterval: Duration = .seconds(10)

    /// 看终端、重列的间隔（测试换成短的）。
    struct Timing {
        var check: Duration
        var refresh: Duration
        static let standard = Timing(check: CodeTabModel.checkInterval, refresh: CodeTabModel.refreshInterval)
    }
    @ObservationIgnored var timing = Timing.standard

    /// 重启前右边看的是什么：列表还没列出来，先记着，列出来之后还原（`applyRestoredState`）；用户先点了别的就作废。
    private enum RestoredSelection: Equatable {
        case run(UUID)
        case record(AgentHistoryPinKey)
    }
    private var restoredSelection: RestoredSelection?

    /// 宿主建一个终端，开在 `directory`，返回它（已经登记、开始连接）。宿主没了为 nil。
    @ObservationIgnored private let makeTerminal: @MainActor (_ directory: String) -> (any CodeTabTerminal)?
    @ObservationIgnored private var revealGeneration = 0
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false

    init(hostName: String, directory: String?, directoryChooser: CodeTabDirectoryChooser = .typedPath,
         recentDirectories: @escaping @MainActor () -> [String] = { [] },
         makeTerminal: @escaping @MainActor (_ directory: String) -> (any CodeTabTerminal)?) {
        self.hostName = hostName
        newSessionDirectory = directory
        self.directoryChooser = directoryChooser
        self.recentDirectories = recentDirectories
        self.makeTerminal = makeTerminal
    }

    var history: AgentHistoryModel? { connection?.history }

    // MARK: 连接

    /// 建文件通道、列会话。只建一次；失败后再调就是重试（`AgentHistoryConnection.open`）。
    func open(_ make: () -> AgentHistoryConnection) async {
        guard !isClosed else { return }
        if connection == nil { connection = make() }
        await connection?.open()
        applyRestoredState()
    }

    /// 测试、画廊直接放一份接好假数据的连接。
    func install(_ connection: AgentHistoryConnection) {
        self.connection = connection
    }

    /// 关标签页：里面的终端一起结束，文件通道放掉。
    func close() {
        isClosed = true
        watcher?.cancel()
        watcher = nil
        for run in runs { run.terminal.dispose() }
        runs = []
        selectedRunID = nil
        restoredSelection = nil
        connection?.close()
    }

    /// 标签页里的终端（关标签页 / 关窗口时问前台程序、退出 App 时一起断开），含已结束、留着画面的。
    var terminals: [any CodeTabTerminal] { runs.map(\.terminal) }

    /// 还在跑的会话个数（标签上、收起的侧栏上的数字）。已结束、留着画面的不算。
    var runningCount: Int { runs.reduce(0) { $0 + ($1.isEnded ? 0 : 1) } }

    // MARK: 右边显示什么

    var detail: Detail {
        if let selectedRunID, let run = runs.first(where: { $0.id == selectedRunID }) {
            let showsRecord = run.showsTranscript && run.path != nil && history?.selectedFile?.path == run.path
            return showsRecord ? .transcript : .terminal(run.id)
        }
        guard let path = history?.selectedFile?.path else { return .empty }
        if let run = runs.first(where: { $0.path == path }), !run.showsTranscript { return .terminal(run.id) }
        return .transcript
    }

    /// 右边那个会话对应的跑着的终端（看终端或者切到了记录都算）。
    var displayedRun: Run? {
        if let selectedRunID { return runs.first { $0.id == selectedRunID } }
        guard let path = history?.selectedFile?.path else { return nil }
        return runs.first { $0.path == path }
    }

    /// 右边正显示的终端（标题栏、状态栏、注册表的前台会话跟着它）。看记录时为 nil。
    var displayedTerminal: (any CodeTabTerminal)? {
        guard case .terminal(let id) = detail else { return nil }
        return runs.first { $0.id == id }?.terminal
    }

    func run(for path: String) -> Run? { runs.first { $0.path == path } }

    // MARK: 选择

    /// 点了侧栏顶上一个列表里没有行的会话（`unlistedRuns`）：有记录的选中那份记录（右边是它的终端），没有记录的新会话单独选中。
    func selectRun(_ id: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        restoredSelection = nil
        runs[index].showsTranscript = false
        if let path = runs[index].path, let file = history?.files.first(where: { $0.path == path }) {
            selectedRunID = nil
            history?.select(file)
        } else {
            // 先清掉列表的选中：之后点回原来那一行也算一次换选中。
            history?.select(nil)
            selectedRunID = id
        }
    }

    /// 列表的选中变了（用户点了列表里的一行）：不再看那个没对上记录的新会话。
    func historySelectionChanged() {
        guard history?.selectedFile != nil else { return }
        selectedRunID = nil
        restoredSelection = nil
    }

    /// 「终端 / 记录」切换。没有记录的新会话只有终端。
    func setShowsTranscript(_ showsTranscript: Bool, for id: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].showsTranscript = showsTranscript && runs[index].path != nil
        // 从新会话那一格切到记录：改由列表选中那份记录。
        if runs[index].showsTranscript, selectedRunID == id, let path = runs[index].path,
           let file = history?.files.first(where: { $0.path == path }) {
            selectedRunID = nil
            history?.select(file)
        }
    }

    /// 侧栏那一行右键「查看记录」：选中它那份记录、右边看记录（不打断它）。没有记录的新会话同点一下那一行。
    func showRecord(of id: UUID) {
        selectRun(id)
        setShowsTranscript(true, for: id)
    }

    func requestReveal(directory: String?) {
        guard let directory else { return }
        revealGeneration += 1
        reveal = AgentHistoryReveal(directory: directory, generation: revealGeneration)
    }

    // MARK: 继续 / 新开

    /// 「继续这个会话」：已经在这个标签页里跑着就回到它的终端，否则在右边起一个终端跑继续的命令。
    @discardableResult
    func resume(_ file: AgentHistorySessionFile) -> Run? {
        guard let history else { return nil }
        restoredSelection = nil
        if let index = runs.firstIndex(where: { $0.path == file.path }) {
            runs[index].showsTranscript = false
            selectedRunID = nil
            history.select(file)
            return runs[index]
        }
        guard let plan = history.resumeCommand(for: file) else { return nil }
        let title = AgentHistoryText.sessionTitle(file, metadata: history.metadata[file.path])
        guard let run = start(plan.command, tool: file.tool, directory: plan.directory, path: file.path, title: title,
                              key: AgentHistoryPinKey(file), resumesRecord: true) else {
            return nil
        }
        selectedRunID = nil
        history.select(file)
        return run
    }

    /// 侧栏顶上的「＋」：不直接起，右边换成起始页（清掉列表的选中；窄的时候盖着的侧栏收回去）。正跑着的会话不受影响。
    func showNewSessionPage() {
        restoredSelection = nil
        selectedRunID = nil
        history?.select(nil)
        sidebarOverlayShown = false
    }

    /// 起始页上选了一个目录：之后新开的会话都开在这里（写回 `newSessionDirectory`）。
    func chooseNewSessionDirectory(_ directory: String) {
        newSessionDirectory = ClaudeProjectPath.normalized(directory) ?? directory
    }

    /// 起始页目录菜单里的候选（见 `AgentHistoryNewSessionPlaces.candidates`）：现算，不存。
    var newSessionDirectoryChoices: [String] {
        AgentHistoryNewSessionPlaces.candidates(current: newSessionDirectory, files: history?.files ?? [],
                                                metadata: history?.metadata ?? [:], recent: recentDirectories(),
                                                home: connection?.homeDirectory)
    }

    /// 起始页「开始」：在选的目录里起选的工具。这台主机上这种工具在这个目录里新开不了时为 nil。
    @discardableResult
    func startNewSession(tool: AgentHistoryTool, in directory: String) -> Run? {
        guard let command = history?.newSessionCommand(tool: tool, directory: directory) else { return nil }
        chooseNewSessionDirectory(directory)
        return startNewSession(tool: tool, command: command, directory: directory)
    }

    /// 新会话：在右边起一个终端跑新会话的命令。它在列表里还没有行，单独选中，等对上记录（`matchNewSessions`）。
    @discardableResult
    func startNewSession(tool: AgentHistoryTool, command: String, directory: String) -> Run? {
        guard let run = start(command, tool: tool, directory: directory, path: nil, title: nil, key: nil,
                              resumesRecord: false) else { return nil }
        restoredSelection = nil
        history?.select(nil)
        selectedRunID = run.id
        return run
    }

    private func start(_ command: String, tool: AgentHistoryTool, directory: String, path: String?,
                       title: String?, key: AgentHistoryPinKey?, resumesRecord: Bool) -> Run? {
        guard !isClosed, let terminal = makeTerminal(directory) else { return nil }
        terminal.runCodeCommand(command)
        let run = Run(terminal: terminal, tool: tool, directory: directory, startedAt: Date(), path: path,
                      knownPaths: Set(history?.files.map(\.path) ?? []), title: title, key: key, command: command,
                      resumesRecord: resumesRecord)
        runs.append(run)
        startWatching()
        return run
    }

    // MARK: 重启后接回

    /// App 重启后把记下来的会话放回这个标签页。终端由宿主按会话 id 接回了保持进程（`terminals`，键是
    /// `CodeRunRecord.session`），这里只认领：命令照「还在跑」接上（`CodeTabTerminal.restoreCodeCommand`），
    /// 对上了记录的先只知道工具 + 会话 ID，列表列出来之后找回记录（`resolveRestoredRuns`）；新会话照旧去对记录。
    /// 右边看的是哪一个：看终端的立刻还原；看记录的等列表列出来（`applyRestoredState`）。返回放进来的会话 id。
    @discardableResult
    func restore(_ record: CodeTabRecord, terminals: [UUID: any CodeTabTerminal]) -> [UUID] {
        guard !isClosed else { return [] }
        if let directory = record.directory { newSessionDirectory = directory }
        var adopted: [UUID] = []
        for saved in record.runs {
            guard let tool = saved.agentTool, let terminal = terminals[saved.session],
                  !runs.contains(where: { $0.id == terminal.id }) else { continue }
            terminal.restoreCodeCommand(marker: saved.marker, startedAt: saved.startedAt)
            runs.append(Run(terminal: terminal, tool: tool, directory: saved.directory, startedAt: saved.startedAt,
                            path: nil, knownPaths: [], title: nil, showsTranscript: saved.showsTranscript ?? false,
                            key: saved.key, resumesRecord: saved.key != nil))
            adopted.append(terminal.id)
        }
        if let id = record.selectedRun, runs.contains(where: { $0.id == id }) {
            restoredSelection = .run(id)
            // 先看它的终端：不等列表（终端已经接回来了）。看的是它的记录的，等列表。
            if runs.first(where: { $0.id == id })?.showsTranscript != true { selectedRunID = id }
        } else if let stored = record.selectedRecord, let key = AgentHistoryPinKey(stored: stored) {
            restoredSelection = .record(key)
        } else if record.selectedRun != nil || record.selectedRecord != nil {
            // 看着的那个会话没接回来（App 不在时结束了）：退到第一个跑着的会话。
            restoredSelection = runs.first.map { .run($0.id) }
            if let first = runs.first { selectedRunID = first.id }
        }
        if !runs.isEmpty { startWatching() }
        applyRestoredState()
        return adopted
    }

    /// 列表列出来之后：接回的会话找回记录，再还原右边看的那一个。认不出（那份记录没列出来）的退到第一个跑着的会话，
    /// 没有就空着。列表还没列出来时什么都不做，下次再来（`open` 之后、每次对新会话时）。
    func applyRestoredState() {
        guard let history, history.phase == .ready || history.phase == .empty else { return }
        resolveRestoredRuns()
        // 列表读出来之前就认出程序退出了、当时还不知道有没有记录的：找回了有对话的记录就照常收尾（要还原的选中随之改成那份记录）。
        for run in runs where run.isEnded {
            if let path = run.path, history.metadata[path]?.isListed == true { finish(run) }
        }
        guard let wanted = restoredSelection else { return }
        restoredSelection = nil
        switch wanted {
        case .run(let id):
            guard let run = runs.first(where: { $0.id == id }) else { return selectFirstRunOrNothing() }
            if run.showsTranscript, let path = run.path, let file = history.files.first(where: { $0.path == path }) {
                selectedRunID = nil
                history.select(file)
            } else {
                let showsTranscript = run.showsTranscript
                selectRun(id)
                // 看记录但记录没找到：只能看终端（`selectRun` 已经切回终端）。
                if showsTranscript, run.path != nil { setShowsTranscript(true, for: id) }
            }
        case .record(let key):
            if let run = runs.first(where: { $0.key == key }), !run.showsTranscript {
                selectRun(run.id)
            } else if let file = history.files.first(where: { AgentHistoryPinKey($0) == key }) {
                selectedRunID = nil
                history.select(file)
            } else {
                selectFirstRunOrNothing()
            }
        }
    }

    private func selectFirstRunOrNothing() {
        if let first = runs.first { selectRun(first.id) } else { selectedRunID = nil }
    }

    /// 接回的会话按工具 + 会话 ID 找回列表里的记录。找不到的（记录没列出来）留着，下次重列再找，不当新会话去对别的记录。
    func resolveRestoredRuns() {
        guard let history, runs.contains(where: { $0.path == nil && $0.key != nil }) else { return }
        var byKey: [AgentHistoryPinKey: AgentHistorySessionFile] = [:]
        for file in history.files where byKey[AgentHistoryPinKey(file)] == nil { byKey[AgentHistoryPinKey(file)] = file }
        let claimed = Set(runs.compactMap(\.path))
        for index in runs.indices where runs[index].path == nil {
            guard let key = runs[index].key, let file = byKey[key], !claimed.contains(file.path) else { continue }
            runs[index].path = file.path
        }
    }

    /// 存进布局的样子（`HeldSessionLayout.codeTabs`）：跑着的会话、右边看的是哪一个。`id` 是标签页的 id。
    /// 列表还没列出来、重启前的选中还没还原时，照原样记下那份选中（马上又退出也不丢）。
    ///
    /// 已结束、留着画面的会话照样记（shell 还在保持进程里时，重启后接回、再判一次程序已经退出，又显示成已结束，
    /// 不会变成一个普通标签页）；shell 已经退出的保持进程里没有它，接回时自然丢掉。
    func record(id: UUID, host: UUID? = nil) -> CodeTabRecord {
        let saved = runs.map { run in
            CodeRunRecord(session: run.id, tool: run.tool, sessionID: run.key?.sessionID, directory: run.directory,
                          startedAt: run.startedAt, marker: run.terminal.codeCommandMarker,
                          showsTranscript: run.showsTranscript ? true : nil)
        }
        var record = CodeTabRecord(id: id, host: host, hostName: hostName, directory: newSessionDirectory, runs: saved)
        switch restoredSelection {
        case .run(let id):
            record.selectedRun = id
        case .record(let key):
            record.selectedRecord = key.stored
        case nil:
            if let run = displayedRun {
                record.selectedRun = run.id
            } else if let file = history?.selectedFile {
                record.selectedRecord = AgentHistoryPinKey(file).stored
            }
        }
        return record
    }

    // MARK: 挪走 / 结束

    /// 「移到新标签页」：把这个终端交给宿主开成普通标签页，从这里拿掉（不结束它）。
    func detach(_ id: UUID) -> (any CodeTabTerminal)? {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return nil }
        let run = runs.remove(at: index)
        if selectedRunID == id { selectedRunID = nil }
        return run.terminal
    }

    /// 结束一个终端（手机远控「同时关闭 Mac 上的终端」）。返回 false = 没有它。
    @discardableResult
    func end(_ id: UUID) -> Bool {
        guard let run = runs.first(where: { $0.id == id }) else { return false }
        finish(run)
        return true
    }

    /// 用户点的「结束会话」（终端顶上「⋯」、侧栏那一行的右键菜单与悬停的 ×；要不要先问由宿主定，见
    /// `TerminalCloseGuard.requestEndSession`）：同程序跑完一样收尾，有记录的回到记录、没有的回到起始页。
    /// 已结束、留着画面的同「关闭」。
    func endSession(_ id: UUID) {
        guard let run = runs.first(where: { $0.id == id }) else { return }
        if run.isEnded { dismissEnded(id) } else { finish(run) }
    }

    // MARK: 看着各个终端

    private func startWatching() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            var sinceRefresh = Duration.zero
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.timing.check ?? CodeTabModel.checkInterval)
                guard let self, !Task.isCancelled, self.runs.contains(where: { !$0.isEnded }) else { break }
                self.checkRuns()
                sinceRefresh += self.timing.check
                if sinceRefresh >= self.timing.refresh {
                    sinceRefresh = .zero
                    if self.runs.contains(where: { $0.path == nil && !$0.isEnded }) {
                        await self.refreshList()
                    } else {
                        await self.refreshRunRecords()
                    }
                }
            }
            self?.watcher = nil
        }
    }

    /// 跑完的收尾（`programExited`）；新会话试着对上记录。已结束、留着画面的不再看。
    func checkRuns() {
        for run in runs where !run.isEnded && run.terminal.codeCommandHasEnded { programExited(run) }
        matchNewSessions()
    }

    /// 终端里的程序退出了。有对话记录可看的（列表里有它那一行）结束终端、回到记录；没有的终端留着、标成已结束，
    /// 先重列一次（新会话的记录可能刚写出来），列出来了、有对话就照样回到记录，否则一直留着，等用户「重新开始」或「关闭」。
    private func programExited(_ run: Run) {
        guard let index = runs.firstIndex(where: { $0.id == run.id }) else { return }
        let listed = run.path.map { history?.metadata[$0]?.isListed == true } ?? false
        guard CodeRunExitPolicy.keepsTerminal(hasListedRecord: listed, ranFor: Date().timeIntervalSince(run.startedAt),
                                              quickExit: 0) else {
            finish(run)
            return
        }
        runs[index].endedAt = Date()
        // 重启后接回、列表还没读出来就结束了的：要还原的选中留在它身上（它的终端还在）。
        Task { [weak self] in
            await self?.refreshList()
            await self?.settleEnded(run.id)
        }
    }

    /// 已结束的会话重列之后再看一次：对上了有对话的记录就照常收尾、回到记录；还是没有就留着。
    private func settleEnded(_ id: UUID) async {
        guard let history, let run = runs.first(where: { $0.id == id }), run.isEnded else { return }
        let path = run.path ?? run.key.flatMap { key in history.files.first { AgentHistoryPinKey($0) == key }?.path }
        guard let path, let file = history.files.first(where: { $0.path == path }) else { return }
        // 记录的信息按文件现在的样子读（侧栏那份可能是会话刚开始、还没对话时读的）。
        var listed = history.metadata[path]?.isListed == true
        if !listed { listed = (try? await history.source.metadata(for: file))?.isListed ?? false }
        guard listed, let current = runs.first(where: { $0.id == id }), current.isEnded else { return }
        let looking = selectedRunID == id || (history.selectedFile?.path == path)
        finish(current)
        if looking, selectedRunID == nil {
            if history.selectedFile?.path == path {
                history.jumpToLatest()
            } else {
                history.select(file)
            }
        }
    }

    /// 「会话已结束」那一条上的「重新开始」：同一种工具、同一个目录，继续的会话再继续同一份记录，新会话再新开一个。
    /// 已结束的那个终端随之结束，右边换成新的。返回新起的；起不了（宿主没了、这种工具在这里开不了）为 nil，原样留着。
    @discardableResult
    func restart(_ id: UUID) -> Run? {
        guard let old = runs.first(where: { $0.id == id }), old.isEnded, let history else { return nil }
        let file = (old.path ?? old.key.flatMap { key in history.files.first { AgentHistoryPinKey($0) == key }?.path })
            .flatMap { path in history.files.first { $0.path == path } }
        let resumes = old.resumesRecord && file != nil
        let command = old.command
            ?? (resumes ? file.flatMap { history.resumeCommand(for: $0)?.command }
                : history.newSessionCommand(tool: old.tool, directory: old.directory))
        guard let command else { return nil }
        let title = file.map { AgentHistoryText.sessionTitle($0, metadata: history.metadata[$0.path]) } ?? old.title
        let wasSelected = displayedRun?.id == id
        guard let run = start(command, tool: old.tool, directory: old.directory, path: resumes ? file?.path : nil,
                              title: resumes ? title : nil, key: resumes ? file.map { AgentHistoryPinKey($0) } : nil,
                              resumesRecord: resumes) else { return nil }
        // 新的放在旧的位置上（侧栏顶上那一行不挪）。
        runs.removeAll { $0.id == run.id }
        if let index = runs.firstIndex(where: { $0.id == id }) { runs.insert(run, at: index) } else { runs.append(run) }
        runs.removeAll { $0.id == id }
        old.terminal.dispose()
        if wasSelected {
            restoredSelection = nil
            if resumes, let file {
                selectedRunID = nil
                if history.selectedFile?.path != file.path { history.select(file) }
            } else {
                history.select(nil)
                selectedRunID = run.id
            }
        }
        return run
    }

    /// 「会话已结束」那一条上的「关闭」：结束那个终端，右边回到起始页（侧栏里它那一行随之拿掉）。
    func dismissEnded(_ id: UUID) {
        guard let run = runs.first(where: { $0.id == id }), run.isEnded else { return }
        let wasLooking = displayedRun?.id == id
        finish(run, revealsRecord: false)
        if wasLooking { history?.select(nil) }
    }

    /// 结束一个终端，从这里拿掉。`revealsRecord`：右边正看着它的话回到它的记录（读到最新）；跑完才列到的新会话，
    /// 右边没在看别的就打开那份记录。
    private func finish(_ run: Run, revealsRecord: Bool = true) {
        guard runs.contains(where: { $0.id == run.id }) else { return }
        runs.removeAll { $0.id == run.id }
        run.terminal.dispose()
        // 右边正看着它：回到它的记录，并从末尾重新读到最新。没对上记录的新会话就回到空态，等下面重列之后再对。
        if revealsRecord, let path = run.path, history?.selectedFile?.path == path { history?.jumpToLatest() }
        if selectedRunID == run.id { selectedRunID = nil }
        // 重启后接回、列表还没读出来就结束了的（App 不在时程序已经退出）：要还原的选中改成它的记录。
        if case .run(run.id)? = restoredSelection { restoredSelection = run.key.map { .record($0) } }
        let pending = revealsRecord && run.path == nil ? run : nil
        Task { [weak self] in
            await self?.refreshList()
            guard let self, let pending, let history = self.history else { return }
            // 跑完了才列到的新会话（或者接回后还没找回记录的）：右边没在看别的就打开那份记录。
            let path: String?
            if let key = pending.key {
                path = history.files.first { AgentHistoryPinKey($0) == key }?.path
            } else {
                path = Self.match([pending], files: history.files, metadata: history.metadata,
                                  claimed: Set(self.runs.compactMap(\.path)))[pending.id]
            }
            if let path, history.selectedFile == nil, self.selectedRunID == nil,
               let file = history.files.first(where: { $0.path == path }) {
                history.select(file)
            }
        }
    }

    /// 安静地重列（不闪「正在读取」），列完对一次新会话。
    func refreshList() async {
        guard let history, !isClosed else { return }
        await history.reload(showsLoading: false)
        matchNewSessions()
    }

    /// 跑着的会话的记录重读一遍（只重列它们所在的项目）：Claude Code 一直在写，标题、时间跟着它。
    func refreshRunRecords() async {
        guard let history, !isClosed else { return }
        await history.refreshProjects(containing: Set(runs.filter { !$0.isEnded }.compactMap(\.path)))
    }

    /// 把还没对上记录的新会话对上列表里的真实记录（规则见 `match`）。对上了：侧栏顶上那一行「新会话」拿掉，
    /// 列表里那份记录平常的那一行标成在跑（不自动置顶）；
    /// 右边正看着它的继续看它的终端（改由列表选中那份记录）。
    func matchNewSessions() {
        applyRestoredState()
        guard let history, runs.contains(where: \.isUnmatched) else { return }
        let claimed = Set(runs.compactMap(\.path))
        let matches = Self.match(runs.filter(\.isUnmatched), files: history.files, metadata: history.metadata,
                                 claimed: claimed)
        for (id, path) in matches {
            guard let index = runs.firstIndex(where: { $0.id == id }) else { continue }
            runs[index].path = path
            runs[index].key = history.files.first { $0.path == path }.map { AgentHistoryPinKey($0) }
            if selectedRunID == id, let file = history.files.first(where: { $0.path == path }) {
                selectedRunID = nil
                history.select(file)
            }
        }
    }

    /// 新会话对哪份记录。记录文件的名字（会话 ID）由编码工具自己定，起的时候不知道，只能事后对：
    ///
    /// 1. 候选：同一种工具、起的时候还不在列表里（`knownPaths`）、没被别的会话占着、修改时间不早于起的时候（留一分钟误差）、
    ///    目录对得上（项目的目录；Claude 的项目名是目录换出来的；或者记录里的工作目录）。
    /// 2. 同一种工具、同一个目录只有一个新会话在等时才对：有候选就取最近改过的那份（正跑着的那个一直在写）。
    ///    同时等着好几个时分不清谁是谁，都不对，各自留在侧栏顶上当「新会话」（不丢、不重复）；跑完一个、剩下一个时再对。
    ///
    /// 重启后接回的新会话不知道起的时候列表里已经有哪些记录（`knownPaths` 为空，布局里不存记录的路径），只剩修改时间
    /// 这一条挡着：同一个目录里另有一个同种工具的会话在 App 不在时也写过记录，就可能被认成它。
    static func match(_ pending: [Run], files: [AgentHistorySessionFile],
                      metadata: [String: AgentHistorySessionMetadata], claimed: Set<String>) -> [UUID: String] {
        var result: [UUID: String] = [:]
        var taken = claimed
        let groups = Dictionary(grouping: pending) { "\($0.tool.rawValue)\u{0}\($0.directory)" }
        for run in pending.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard groups["\(run.tool.rawValue)\u{0}\(run.directory)"]?.count == 1 else { continue }
            let candidates = files.filter { file in
                file.tool == run.tool && !run.knownPaths.contains(file.path) && !taken.contains(file.path)
                    && file.modifiedAt >= run.startedAt.addingTimeInterval(-60)
                    && directoryMatches(file, metadata: metadata[file.path], directory: run.directory)
            }
            guard let best = candidates.max(by: { $0.modifiedAt < $1.modifiedAt }) else { continue }
            result[run.id] = best.path
            taken.insert(best.path)
        }
        return result
    }

    private static func directoryMatches(_ file: AgentHistorySessionFile, metadata: AgentHistorySessionMetadata?,
                                         directory: String) -> Bool {
        let wanted = ClaudeProjectPath.normalized(directory) ?? directory
        let known = [file.project.directory, metadata?.resumeDirectory, metadata?.lastDirectory]
            .compactMap { $0.flatMap { ClaudeProjectPath.normalized($0) ?? $0 } }
        if known.contains(wanted) { return true }
        return file.tool == .claude && file.project.id == ClaudeProjectPath.encode(wanted)
    }

    /// 列表里没有行的会话：还没对上记录的新会话，或者对上了但那份记录列表里还没列出来（还没重列、被「显示」筛掉了、
    /// 还没翻到）。侧栏把它们放在最顶上，一个都不丢；列表里有行的不在这里（不重复）。`shown`：列表里显示着的记录。
    func unlistedRuns(shown: Set<String>) -> [Run] {
        runs.filter { run in run.path.map { !shown.contains($0) } ?? true }
    }

    /// 一个跑着的会话叫什么：对上了记录、读到了信息的用记录的标题（Claude Code 起的名字，跟着它变），继续的会话
    /// 在那之前用起的时候的标题，新会话叫「新会话」（刚对上、记录的信息还没读到时也是，不闪一下「（无标题）」）。
    /// 接回后还没找回记录的会话用会话 ID 的前 8 位（同列表里读不到标题的那一行）。
    func title(of run: Run) -> String {
        let file = run.path.flatMap { path in history?.files.first { $0.path == path } }
        if let file, let metadata = history?.metadata[file.path] { return AgentHistoryText.sessionTitle(file, metadata: metadata) }
        if let title = run.title { return title }
        if !run.resumesRecord { return AgentHistoryText.newSession }
        if let key = run.key { return String(localized: "（无标题）\(String(key.sessionID.prefix(8)))") }
        return AgentHistoryText.newSession
    }
}

/// Code 标签页起始页上「选择文件夹…」怎么选。
enum CodeTabDirectoryChooser {
    /// 这台 Mac：系统的文件夹面板（App 带沙盒，但这里只要路径字符串：shell 由辅助程序在沙盒外起，`cd` 进去不需要
    /// 安全书签）。
    case localFolder
    /// SSH 主机：输入一个路径，经这个标签页的文件通道核对它存在、是目录。
    case typedPath
}
