import Foundation
import Observation
import SwiftData

/// Code 标签页里跑着的会话：建终端、打命令、看着程序退出、关掉。哪些在跑、看哪个、新会话怎么对上记录由
/// `CodeRunBoard` 管，这里是它和真终端（`TermTab`）之间的那一层。
///
/// 每个 run 的终端就是一个不在标签条上的 `TermTab`：连接（直连主机走 `PersistentSSHConnection`，同普通终端标签页）、
/// 断线重连、键盘条、实时活动、归档都照终端标签页那样算（工作区把它们算进去，见 `MobileWorkspace.allTerminals`）。
///
/// 命令后面接 `; exit`：程序一退出 shell 跟着结束、会话收尾，控制器翻成 `.disconnected`——这就是「程序退出」的信号，
/// 不用去猜前台是不是还是那个程序。会话留在主机上的（保持进程）断网只是重连，不会被当成退出；
/// 没有保持进程的主机断网，shell 和程序本来也跟着没了，当成退出是对的。
extension ClaudeHistoryTab {
    /// 这台主机能不能在标签页里跑：直连的主机可以；配对的 Mac 照旧开终端标签页（见类型注释）。
    var runsInPlace: Bool { remoteMac == nil && canResume }

    /// 正在跑的终端（工作区算键盘、实时活动、归档、关前确认时要看）。
    var runTerminals: [TermTab] { runs.runs.map(\.terminal) }

    /// 详情此刻露出来、可以打字的终端：在看终端、连接中页已经撤下。键盘归它。
    var keyboardTerminal: TermTab? {
        guard let run = runs.focused, run.showsTerminal, run.isRunning, runCovers[run.id] == nil else { return nil }
        return run.terminal
    }

    /// 列表与详情标题行上这个 run 的名字：对上了记录用记录的标题，新会话叫「新会话」。
    func title(of run: CodeRunBoard<TermTab>.Run) -> String {
        if let title = runTitles[run.id] { return title }
        if let path = run.sessionPath, let history = connection.history,
           let title = history.metadata[path]?.title { return title }
        if run.isNewSession { return AgentHistoryText.newSession }
        return String(localized: "（无标题）\(String((run.sessionID ?? "").prefix(8)))")
    }

    // MARK: 起

    /// 「继续这个会话」：这份记录已经在跑就回到它的终端，没有就起一个。
    func resumeInPlace(_ file: AgentHistorySessionFile, command: String, directory: String,
                       container: ModelContainer, relay: HostKeyChallengeRelay) {
        restoredSelection = nil
        let factory = runTerminalFactory
        let host = self.host
        guard let run = runs.resume(sessionPath: file.path, sessionID: file.sessionID, tool: file.tool,
                                    directory: directory, make: { factory(host) }) else { return }
        launch(run, command: command, container: container, relay: relay)
    }

    /// 「＋」新会话：在这个标签页里起一个终端跑它。还没有记录，列表最顶上先放一行「新会话」占位。
    func startNewInPlace(tool: AgentHistoryTool, command: String, directory: String,
                         container: ModelContainer, relay: HostKeyChallengeRelay) {
        restoredSelection = nil
        let run = runs.startNew(tool: tool, directory: directory, terminal: runTerminalFactory(host))
        launch(run, command: command, container: container, relay: relay)
        pollNewSessionsIfNeeded()
    }

    private func launch(_ run: CodeRunBoard<TermTab>.Run, command: String,
                        container: ModelContainer, relay: HostKeyChallengeRelay) {
        runContainer = container
        runRelay = relay
        let term = run.terminal
        term.controller.start(profile: host, container: container, relay: relay)
        let cover = MConnectRequest(host: host, kind: .terminal, origin: .hosts)
        cover.terminal = term.controller
        runCovers[run.id] = cover
        runStartCommands[run.id] = command
        // 程序退出 shell 跟着结束（见类型注释）。
        runCommands[run.id] = command + "; exit"
        type(run.id)
        watch(run.id)
    }

    /// 连上、行编辑器起来之后打命令。重试时先作废上一次在等的，免得连上之后打两遍。
    private func type(_ id: UUID) {
        runTyping[id]?.cancel()
        guard let term = runs.run(id: id)?.terminal, let command = runCommands[id] else { return }
        let controller = term.controller
        let terminal = controller.terminal
        runTyping[id] = Task { [weak controller] in
            await TerminalCommandTyping.type(
                command, shadow: terminal.shadow,
                generation: { terminal.outputPump.generation },
                isConnected: { [weak controller] in controller?.state == .connected },
                send: { [weak controller] line in
                    guard !Task.isCancelled else { return }
                    controller?.sendText(line)
                })
        }
    }

    // MARK: 连接中页

    /// 连上了（成功态演完）：撤下连接中页，露出终端。
    func finishCover(_ id: UUID) {
        runCovers[id] = nil
    }

    /// 连接中页（或终端的失败页）上的「重试」：同一个终端重连，重新打命令。
    func retryRun(_ id: UUID) {
        guard let term = runs.run(id: id)?.terminal else { return }
        if let cover = runCovers[id] {
            cover.restart()
        } else {
            term.controller.restart()
        }
        type(id)
    }

    // MARK: 看哪个

    /// 列表里点了一份记录：它在跑就看它的 run（停在它上次看的那一面），否则看它的记录。
    func select(_ file: AgentHistorySessionFile) {
        guard let history = connection.history else { return }
        restoredSelection = nil
        runs.focus(runs.run(forSession: file.path)?.id)
        history.select(file)
    }

    /// 点了列表最顶上那一行（列表里没有它的记录）：看它的终端。对上了记录的，记录那边也选上（「记录」切换要用）。
    func focusRun(_ id: UUID) {
        guard let run = runs.run(id: id), let history = connection.history else { return }
        restoredSelection = nil
        runs.focus(id)
        runs.setShowsTerminal(id, true)
        if let path = run.sessionPath, let file = history.files.first(where: { $0.path == path }) {
            history.select(file)
        } else {
            history.select(nil)
        }
    }

    /// 窄屏左上角返回列表。
    func backToList() {
        restoredSelection = nil
        runs.focus(nil)
        connection.history?.select(nil)
    }

    /// 「终端 / 记录」切换。
    func setShowsTerminal(_ id: UUID, _ shows: Bool) {
        restoredSelection = nil
        runs.focus(id)
        runs.setShowsTerminal(id, shows)
        guard !shows, let path = runs.run(id: id)?.sessionPath, let history = connection.history,
              history.selectedFile?.path != path,
              let file = history.files.first(where: { $0.path == path }) else { return }
        history.select(file)
    }

    /// 记录这份是不是有 run 对着（列表行上的「运行中」）。
    func isRunning(_ file: AgentHistorySessionFile) -> Bool {
        runs.run(forSession: file.path)?.isRunning ?? false
    }

    // MARK: 程序退出

    /// 盯着 run 的连接：曾经连上过、后来收尾了（shell 退出），就是程序退出了。
    private func watch(_ id: UUID) {
        guard let run = runs.run(id: id) else { return }
        let controller = run.terminal.controller
        let state = withObservationTracking { controller.state } onChange: { [weak self] in
            Task { @MainActor in self?.watch(id) }
        }
        if state == .disconnected, controller.hadConnected, run.isRunning { runEnded(id) }
    }

    /// 程序退出了（规则见 `CodeRunExitPolicy`）：有对话记录可看、跑得够久的拿掉、关掉终端，记录重新读到最新、详情回到它；
    /// 没有对话记录的（新会话没说话就退出）、很快就退出的留着最后的画面，标成已结束。没有记录的再去主机上看一眼
    ///（记录可能刚写出来），有对话了就照常收回记录。
    func runEnded(_ id: UUID) {
        guard let run = runs.run(id: id) else { return }
        let term = run.terminal
        runCovers[id] = nil
        // App 重新打开后接回、列表还没读出来就结束了的：要还原的选中改成它的记录（列表读出来之后选上）。
        if case .run(id, _)? = restoredSelection {
            restoredSelection = run.sessionID.map { .record(AgentHistoryPinKey(tool: run.tool, sessionID: $0)) }
        }
        switch runs.ended(id, hasListedRecord: hasListedRecord(run)) {
        case .removed(let path, let wasFocused):
            dispose(id, term)
            refreshAfterRun(path: path, wasFocused: wasFocused)
        case .kept:
            if !hasListedRecord(run) { Task { await settleEnded(id) } }
        case .unknown:
            break
        }
    }

    /// 它对上的记录列表里会列出来（有对话可看）。列表还没读到那份的信息时按有算（同列表：读到之前不知道）。
    private func hasListedRecord(_ run: CodeRunBoard<TermTab>.Run) -> Bool {
        guard let path = run.sessionPath else { return false }
        return connection.history?.metadata[path]?.isListed ?? true
    }

    /// 已结束、没有记录的：去主机上对一次记录，对上了、有对话就照常收回记录（同 Mac 的 `settleEnded`）。
    func settleEnded(_ id: UUID) async {
        await matchNewSessions(includingEnded: true)
        guard let history = connection.history, let run = runs.run(id: id), !run.isRunning,
              let path = run.sessionPath else { return }
        var listed = history.metadata[path]?.isListed == true
        if !listed, let file = history.files.first(where: { $0.path == path }) ?? found(path) {
            listed = (try? await history.source.metadata(for: file))?.isListed ?? false
        }
        guard listed, runs.run(id: id) != nil else { return }
        endRun(id)
    }

    /// 列表里还没有、`matchNewSessions` 刚找到的那份记录。
    private func found(_ path: String) -> AgentHistorySessionFile? { matchedFiles[path] }

    /// 「会话已结束」上的「重新开始」：同一种工具、同一个目录再起一个（继续的会话再继续同一份），放在原来的位置，
    /// 已结束的那个终端关掉。起不了（这种工具在这里开不了）时什么都不做。
    func restartRun(_ id: UUID) {
        guard let old = runs.run(id: id), !old.isRunning, let history = connection.history,
              let container = runContainer, let relay = runRelay else { return }
        let file = old.sessionPath.flatMap { path in history.files.first { $0.path == path } }
        let resumes = file.map { history.metadata[$0.path]?.isListed ?? true } ?? false
        let command: String
        let directory: String
        if let stored = runStartCommands[id] {
            command = stored
            directory = old.directory
        } else if resumes, let file, let plan = history.resumeCommand(for: file) {
            (command, directory) = (plan.command, plan.directory)
        } else if let made = history.newSessionCommand(tool: old.tool, directory: old.directory) {
            (command, directory) = (made, old.directory)
        } else {
            return
        }
        let run = runs.makeRun(tool: old.tool, directory: directory, sessionPath: resumes ? file?.path : nil,
                               sessionID: resumes ? file?.sessionID : nil, terminal: runTerminalFactory(host))
        guard let replaced = runs.replace(id, with: run) else { return }
        dispose(id, replaced)
        restoredSelection = nil
        launch(run, command: command, container: container, relay: relay)
        if run.isNewSession { pollNewSessionsIfNeeded() }
    }

    /// 结束一个 run：已退出的「回到记录」、用户「结束会话」、连接中页上的「返回」。还在跑的连接一并关掉。
    func endRun(_ id: UUID) {
        guard let term = runs.run(id: id)?.terminal else { return }
        guard case .removed(let path, let wasFocused) = runs.remove(id) else { return }
        dispose(id, term)
        refreshAfterRun(path: path, wasFocused: wasFocused)
    }

    /// 把这个 run 的终端挪成工作区里的普通终端标签页（开在这个标签页旁边、到前台）。返回挪出去的终端。
    /// 命令后面的 `; exit` 还在：程序退出后那个标签页显示「已断开」。
    @discardableResult
    func moveRunToTab(_ id: UUID, in workspace: MobileWorkspace) -> TermTab? {
        guard let term = runs.run(id: id)?.terminal, runCovers[id] == nil else { return nil }
        let pane = workspace.paneIndex(containing: self.id).map { workspace.panes[$0].id }
        runs.remove(id)
        runTyping[id] = nil
        runCommands[id] = nil
        runTitles[id] = nil
        workspace.open(.terminal(term), in: pane)
        return term
    }

    private func dispose(_ id: UUID, _ term: TermTab) {
        runTyping.removeValue(forKey: id)?.cancel()
        runCommands[id] = nil
        runStartCommands[id] = nil
        runCovers[id] = nil
        runTitles[id] = nil
        term.controller.resignKeyboard()
        term.controller.close()
        term.agent.dispose()
        term.agentTasks.cancelAll()
    }

    /// run 拿掉之后：列表重新读（修改时间、大小、新会话的记录都变了）；看着它、或者记录那边正开着它的，重新从末尾读。
    private func refreshAfterRun(path: String?, wasFocused: Bool) {
        guard let history = connection.history else { return }
        let reopen = path.flatMap { path in wasFocused || history.selectedFile?.path == path ? path : nil }
        Task {
            await history.reload()
            guard let reopen, let file = history.files.first(where: { $0.path == reopen }) else { return }
            history.select(nil)
            history.select(file)
        }
    }

    /// 标签页关了：全部结束。
    func closeAllRuns() {
        newSessionPoll?.cancel()
        newSessionPoll = nil
        for run in runs.runs { dispose(run.id, run.terminal) }
        _ = runs.removeAll()
    }

    /// 关标签页前问：里面还有没有程序在跑。有一个在跑就按它问。
    func foregroundActivity() async -> TerminalActivity {
        for term in runTerminals {
            let activity = await term.controller.foregroundActivity()
            if activity != .idle { return activity }
        }
        return .idle
    }

    // MARK: App 重新打开后接回

    /// 记进归档的样子（`MobileTerminalTabArchive.codeTabs`）：哪台主机、「＋」的目录、要接回的会话（`included`：
    /// 还没断开、能接回的那些，键是 run 的 id）、详情看的是哪一个。配对的 Mac、主机已经删了的不记（nil）。
    func archiveRecord(including included: [CodeRunBoard<TermTab>.Run]) -> CodeTabRecord? {
        guard remoteMac == nil, !host.isDeleted, host.modelContext != nil else { return nil }
        var record = CodeTabRecord(id: id, host: host.id, directory: directory)
        record.runs = included.map { run in
            CodeRunRecord(session: run.terminal.controller.hostSessionID, tool: run.tool, sessionID: run.sessionID,
                          directory: run.directory, startedAt: run.startedAt,
                          showsTranscript: run.showsTerminal ? nil : true)
        }
        switch restoredSelection {
        case .run(let id, _):
            record.selectedRun = included.first { $0.id == id }?.terminal.controller.hostSessionID
        case .record(let key):
            record.selectedRecord = key.stored
        case nil:
            if let focused = runs.focused {
                record.selectedRun = included.first { $0.id == focused.id }?.terminal.controller.hostSessionID
            } else if let file = connection.history?.selectedFile {
                record.selectedRecord = AgentHistoryPinKey(file).stored
            }
        }
        return record
    }

    /// 把归档里的会话放回这个标签页：`terminals` 是带着原来会话 id 的终端（键是 `CodeRunRecord.session`），交给 `start`
    /// 去连（走普通终端标签页那条接回路径）。认不出工具的、没有终端的不放（外面照普通终端标签页开）。返回放进来的会话 id。
    ///
    /// 程序退出照旧靠命令后面接的 `; exit`（会话跟着结束，连接收尾 → `watch`）。但 App 不在时会话已经结束了的，
    /// 接回时主机上的保持进程会用同一个 id 新开一个 shell（`PersistentSSHConnection` 第一次接入带 `--create`），连接不会断，
    /// 所以连上之后再问一次前台进程（`checkRestored`）：停在提示符上 = 那个程序已经不在了，照程序退出处理、回到记录。
    /// 前台还有程序、判断不了（主机上没有 `ps`、超时）都当它还在跑：宁可留着让用户看见，也不能把还在跑的会话关掉。
    @discardableResult
    func restoreRuns(_ record: CodeTabRecord, terminals: [UUID: TermTab], start: (TermTab) -> Void) -> [UUID] {
        var adopted: [UUID] = []
        var focusID: UUID?
        var focusShowsTranscript = false
        for saved in record.runs {
            guard let tool = saved.agentTool, let term = terminals[saved.session],
                  runs.run(for: term) == nil else { continue }
            let run = runs.restore(tool: tool, directory: saved.directory, startedAt: saved.startedAt,
                                   sessionID: saved.sessionID, showsTerminal: saved.showsTranscript != true,
                                   terminal: term)
            start(term)
            watch(run.id)
            checkRestored(run.id)
            adopted.append(saved.session)
            if saved.session == record.selectedRun {
                focusID = run.id
                focusShowsTranscript = saved.showsTranscript == true
            }
        }
        if let focusID {
            // 先看它的终端（不等列表）；看的是记录的，列表读出来之后切过去。
            runs.focus(focusID)
            restoredSelection = .run(focusID, showsTranscript: focusShowsTranscript)
        } else if let stored = record.selectedRecord, let key = AgentHistoryPinKey(stored: stored) {
            restoredSelection = .record(key)
        } else if record.selectedRun != nil, let first = runs.runs.first {
            // 看着的那个会话没接回来：退到第一个跑着的。
            runs.focus(first.id)
            restoredSelection = .run(first.id, showsTranscript: false)
        }
        applyRestoredState()
        return adopted
    }

    /// 列表读出来之后：接回的会话找回记录，再还原详情看的那一个。那份记录找不到就退到第一个跑着的会话，没有就回到列表。
    /// 列表还没读出来时什么都不做（`start` 读完之后再来）。
    func applyRestoredState() {
        guard let history = connection.history, history.phase == .ready || history.phase == .empty else { return }
        var byKey: [AgentHistoryPinKey: AgentHistorySessionFile] = [:]
        for file in history.files where byKey[AgentHistoryPinKey(file)] == nil { byKey[AgentHistoryPinKey(file)] = file }
        runs.resolveRestored { tool, sessionID in byKey[AgentHistoryPinKey(tool: tool, sessionID: sessionID)]?.path }
        guard let wanted = restoredSelection else { return }
        restoredSelection = nil
        switch wanted {
        case .run(let id, let showsTranscript):
            guard let run = runs.run(id: id) else { return }
            if let path = run.sessionPath, let file = history.files.first(where: { $0.path == path }) {
                history.select(file)
                runs.setShowsTerminal(id, !showsTranscript)
            } else {
                // 记录没找到：只能看终端。
                runs.setShowsTerminal(id, true)
            }
        case .record(let key):
            if let file = byKey[key] {
                runs.focus(runs.run(forSession: file.path)?.id)
                history.select(file)
            } else if let first = runs.runs.first {
                focusRun(first.id)
            }
        }
    }

    /// 接回的会话连上之后问一次前台进程（规则见 `restoreRuns`）。一直没连上（`waitLimit` 内）就不再问，当它在跑。
    private func checkRestored(_ id: UUID, waitLimit: Duration = .seconds(120)) {
        guard let controller = runs.run(id: id)?.terminal.controller else { return }
        Task { [weak self, weak controller] in
            let deadline = ContinuousClock.now + waitLimit
            while ContinuousClock.now < deadline {
                guard let self, let controller, self.runs.run(id: id)?.isRunning == true else { return }
                switch controller.state {
                case .connected:
                    let activity = await controller.foregroundActivity()
                    if activity == .idle, self.runs.run(id: id)?.isRunning == true { self.runEnded(id) }
                    return
                case .disconnected:
                    return   // `watch` 管。
                default:
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    // MARK: 新会话对上记录

    /// 隔多久去主机上看一眼新会话的记录有没有写出来。
    nonisolated static var newSessionPollInterval: Duration { .seconds(6) }

    func pollNewSessionsIfNeeded() {
        guard newSessionPoll == nil, runs.hasUnmatchedNewSessions else { return }
        newSessionPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.newSessionPollInterval)
                guard let self, !Task.isCancelled else { return }
                await self.matchNewSessions()
                guard self.runs.hasUnmatchedNewSessions else { break }
            }
            self?.newSessionPoll = nil
        }
    }

    /// 去主机上看新会话的记录写出来没有：只看对应工具最近的几个项目里、比 run 起来晚的那些（读它们的末尾拿工作目录），
    /// 交给 `CodeRunBoard.reconcile` 认领。不碰列表本身（列表重读会闪），认下来后读一下标题（列表还没列出那份记录时，
    /// 顶上那一行用它）。
    func matchNewSessions(includingEnded: Bool = false) async {
        guard let history = connection.history else { return }
        let waiting = runs.runs.filter { $0.isNewSession && ($0.isRunning || includingEnded) }
        guard let earliest = waiting.map(\.startedAt).min() else { return }
        let since = earliest.addingTimeInterval(-CodeRunBoard<TermTab>.matchSlack)
        var candidates: [CodeRunBoard<TermTab>.Candidate] = []
        var found: [String: (file: AgentHistorySessionFile, source: any AgentHistorySource)] = [:]
        for tool in Set(waiting.map(\.tool)) {
            guard let source = history.source(for: tool), let projects = try? await source.projects() else { continue }
            let recent = projects.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }.prefix(4)
            for file in await source.allSessions(in: Array(recent)) where file.modifiedAt >= since {
                let directory: String?
                if let known = file.project.directory {
                    directory = known
                } else {
                    directory = (try? await source.metadata(for: file))?.resumeDirectory
                }
                candidates.append(.init(path: file.path, sessionID: file.sessionID, tool: tool, directory: directory,
                                        modifiedAt: file.modifiedAt))
                found[file.path] = (file, source)
                matchedFiles[file.path] = file
            }
        }
        for id in runs.reconcile(candidates) {
            guard let path = runs.run(id: id)?.sessionPath, let hit = found[path] else { continue }
            if let title = (try? await hit.source.metadata(for: hit.file))?.title { runTitles[id] = title }
        }
    }
}
