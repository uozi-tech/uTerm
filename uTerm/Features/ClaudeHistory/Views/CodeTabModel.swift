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
}

/// 一个 Code 标签页：左边这台主机上编码工具的历史会话，右边看选中那份记录，或者就在右边接着聊（一个跑着继续命令的终端）。
///
/// 被「继续」过的会话各自留着自己的终端（`runs`）：点侧栏里别的会话不打断正在跑的，点回去就回到它的终端。
/// 终端里的程序退出（用户退出了 Claude）就结束那个终端，这个会话回到只读记录，记录重新读到最新。
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
        /// 起的时候列表里已经有的记录：新会话对记录时不考虑它们。
        let knownPaths: Set<String>
        /// 起的时候那份记录的标题（继续的会话）；新会话为 nil。
        let title: String?
        /// 右边现在看的是它的记录（「终端 / 记录」切到「记录」）。
        var showsTranscript = false
    }

    /// 右边显示什么。
    enum Detail: Equatable {
        case empty
        /// 选中那份记录的只读对话。
        case transcript
        /// 一个跑着的会话的终端。
        case terminal(UUID)
    }

    /// 主机名（标签页标题用）。
    let hostName: String
    /// 「＋」新会话默认开在哪：打开这个标签页时那个终端的当前目录；不知道为 nil（按钮不可用）。
    var newSessionDirectory: String?
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
    /// 有新会话还没对上记录时，隔多久安静地重列一次（不闪「正在读取」）。
    nonisolated static let refreshInterval: Duration = .seconds(10)

    /// 宿主建一个终端，开在 `directory`，返回它（已经登记、开始连接）。宿主没了为 nil。
    @ObservationIgnored private let makeTerminal: @MainActor (_ directory: String) -> (any CodeTabTerminal)?
    @ObservationIgnored private var revealGeneration = 0
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false

    init(hostName: String, directory: String?,
         makeTerminal: @escaping @MainActor (_ directory: String) -> (any CodeTabTerminal)?) {
        self.hostName = hostName
        newSessionDirectory = directory
        self.makeTerminal = makeTerminal
    }

    var history: AgentHistoryModel? { connection?.history }

    // MARK: 连接

    /// 建文件通道、列会话。只建一次；失败后再调就是重试（`AgentHistoryConnection.open`）。
    func open(_ make: () -> AgentHistoryConnection) async {
        guard !isClosed else { return }
        if connection == nil { connection = make() }
        await connection?.open()
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
        connection?.close()
    }

    /// 标签页里跑着的终端（关标签页 / 关窗口时问前台程序、退出 App 时一起断开）。
    var terminals: [any CodeTabTerminal] { runs.map(\.terminal) }

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
        if history?.selectedFile != nil { selectedRunID = nil }
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
        if let index = runs.firstIndex(where: { $0.path == file.path }) {
            runs[index].showsTranscript = false
            selectedRunID = nil
            history.select(file)
            return runs[index]
        }
        guard let plan = history.resumeCommand(for: file) else { return nil }
        let title = AgentHistoryText.sessionTitle(file, metadata: history.metadata[file.path])
        guard let run = start(plan.command, tool: file.tool, directory: plan.directory, path: file.path, title: title) else {
            return nil
        }
        selectedRunID = nil
        history.select(file)
        return run
    }

    /// 「＋」新会话：在右边起一个终端跑新会话的命令。它在列表里还没有行，单独选中，等对上记录（`matchNewSessions`）。
    @discardableResult
    func startNewSession(tool: AgentHistoryTool, command: String, directory: String) -> Run? {
        guard let run = start(command, tool: tool, directory: directory, path: nil, title: nil) else { return nil }
        history?.select(nil)
        selectedRunID = run.id
        return run
    }

    private func start(_ command: String, tool: AgentHistoryTool, directory: String, path: String?,
                       title: String?) -> Run? {
        guard !isClosed, let terminal = makeTerminal(directory) else { return nil }
        terminal.runCodeCommand(command)
        let run = Run(terminal: terminal, tool: tool, directory: directory, startedAt: Date(), path: path,
                      knownPaths: Set(history?.files.map(\.path) ?? []), title: title)
        runs.append(run)
        startWatching()
        return run
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

    // MARK: 看着各个终端

    private func startWatching() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            var sinceRefresh = Duration.zero
            while !Task.isCancelled {
                try? await Task.sleep(for: CodeTabModel.checkInterval)
                guard let self, !Task.isCancelled, !self.runs.isEmpty else { break }
                self.checkRuns()
                sinceRefresh += CodeTabModel.checkInterval
                if sinceRefresh >= CodeTabModel.refreshInterval, self.runs.contains(where: { $0.path == nil }) {
                    sinceRefresh = .zero
                    await self.refreshList()
                }
            }
            self?.watcher = nil
        }
    }

    /// 跑完的结束掉；新会话试着对上记录。
    func checkRuns() {
        for run in runs where run.terminal.codeCommandHasEnded { finish(run) }
        matchNewSessions()
    }

    private func finish(_ run: Run) {
        guard runs.contains(where: { $0.id == run.id }) else { return }
        runs.removeAll { $0.id == run.id }
        run.terminal.dispose()
        // 右边正看着它：回到它的记录，并从末尾重新读到最新。没对上记录的新会话就回到空态，等下面重列之后再对。
        if let path = run.path, history?.selectedFile?.path == path { history?.jumpToLatest() }
        if selectedRunID == run.id { selectedRunID = nil }
        let pending = run.path == nil ? run : nil
        Task { [weak self] in
            await self?.refreshList()
            guard let self, let pending, let history = self.history else { return }
            // 跑完了才列到的新会话：右边没在看别的就打开那份记录。
            if let path = Self.match([pending], files: history.files, metadata: history.metadata,
                                     claimed: Set(self.runs.compactMap(\.path)))[pending.id],
               history.selectedFile == nil, self.selectedRunID == nil,
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

    /// 把还没对上记录的新会话对上列表里的真实记录（规则见 `match`）。对上了：侧栏顶上那一行「新会话」拿掉，
    /// 列表里那份记录平常的那一行标成在跑（不自动置顶）；
    /// 右边正看着它的继续看它的终端（改由列表选中那份记录）。
    func matchNewSessions() {
        guard let history, runs.contains(where: { $0.path == nil }) else { return }
        let claimed = Set(runs.compactMap(\.path))
        let matches = Self.match(runs.filter { $0.path == nil }, files: history.files, metadata: history.metadata,
                                 claimed: claimed)
        for (id, path) in matches {
            guard let index = runs.firstIndex(where: { $0.id == id }) else { continue }
            runs[index].path = path
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

    /// 一个跑着的会话叫什么：对上了记录用记录的标题，继续的会话用起的时候的标题，新会话叫「新会话」。
    func title(of run: Run) -> String {
        let file = run.path.flatMap { path in history?.files.first { $0.path == path } }
        return file.map { AgentHistoryText.sessionTitle($0, metadata: history?.metadata[$0.path]) }
            ?? run.title ?? AgentHistoryText.newSession
    }
}
