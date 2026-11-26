import Foundation
import Observation

/// Mac 控制 Mac 时，主控端窗口里的 Code 标签页显示的是那台 Mac 上的 Code 标签页（63 号消息，`RemoteCodeTabInfo`）：
/// 它里面跑着的会话放进这里（`isMirrored`，终端是接着那台 Mac 上那个会话的远控终端），不再各开一个终端标签页。
/// 同手机上的镜像（`ClaudeHistoryTab+Mirror`），规则一样：
///
/// - 会话的增减、对上的记录、标题、结束都照那台 Mac 报的（`RemoteCodeRunMirror`）；这边不去认记录、不看程序退出
///   （命令不是这边打的）。
/// - 「继续这个会话」「＋新会话」「重新开始」「移到新标签页」请那台 Mac 在它的 Code 标签页里做（64 号消息）；做完的那个
///   会话出现时选上它（回复可能先到也可能后到）。那台 Mac 不认 64（老版本）：继续、新开照旧在它上面新开一个本机终端
///   （`runInNewTerminal`，开成这扇窗口里的终端标签页），重新开始、移到新标签页不给。
/// - 「结束会话」请那台 Mac 结束它（8 号消息），等它推来新的 Code 标签页再拿掉；关掉这个标签页只断开镜像。
///
/// 哪个 Code 标签页开出来、什么时候关由窗口管（`RemoteMacWindowModel+Code`）。
@MainActor
@Observable
final class CodeTabRemote {
    /// 镜像着那台 Mac 上的哪个 Code 标签页（`RemoteCodeTabInfo.id`）；nil = 还没在镜像（那台 Mac 上还没有 Code 标签页）。
    var macTabID: UUID?
    /// 是接管时为了镜像才开出来的：那台 Mac 上的 Code 标签页没了就跟着关。用户自己开的（标签条按钮、右键「历史会话…」）不关。
    var opensForMirror = false
    /// 有一个请那台 Mac 做的事还没回复：这时再点不再发。
    private(set) var actionInFlight = false
    /// 请那台 Mac 做的事没做成：界面弹一个提示，看过之后清掉。
    var failure: CodeTabRemoteFailure?

    /// 请那台 Mac 做完了、回复里的那个会话还没出现在这里：出现时选上它。
    @ObservationIgnored private(set) var pendingFocus: UUID?
    @ObservationIgnored private var pendingFocusExpiry: Task<Void, Never>?
    /// 最近一次请那台 Mac 做的事（测试等它做完）。
    @ObservationIgnored private(set) var lastAction: Task<Void, Never>?

    /// 那台 Mac 认不认得 64 号消息（`RemoteMacClient.supportsCodeTabActions`）。
    @ObservationIgnored let supportsActions: @MainActor () -> Bool
    /// 发 64 号消息、等回复，返回做完之后的会话 id（`RemoteMacClient.performCodeTabAction`）。
    @ObservationIgnored let perform: @MainActor (RemoteCodeTabAction) async throws -> UUID
    /// 请那台 Mac 结束一个会话（8 号消息，`RemoteMacClient.closeSessionOnMac`）。
    @ObservationIgnored let end: @MainActor (UUID) -> Void
    /// 老 Mac 的继续 / 新开：在它上面新开一个本机终端跑这条命令（`RemoteMacWindowModel.resumeAgentSession`）。
    @ObservationIgnored let runInNewTerminal: @MainActor (_ command: String, _ directory: String) async throws -> Void

    /// 回复里的会话最多等它这么久出现在那台 Mac 推来的 Code 标签页里（同手机）。
    nonisolated static var focusTimeout: Duration { .seconds(20) }

    init(supportsActions: @escaping @MainActor () -> Bool,
         perform: @escaping @MainActor (RemoteCodeTabAction) async throws -> UUID,
         end: @escaping @MainActor (UUID) -> Void,
         runInNewTerminal: @escaping @MainActor (_ command: String, _ directory: String) async throws -> Void) {
        self.supportsActions = supportsActions
        self.perform = perform
        self.end = end
        self.runInNewTerminal = runInNewTerminal
    }

    /// 在后台做一件事；做不成记进 `failure`。在途的还没做完时不再发（返回 false）。
    @discardableResult
    func run(failureTitle: String, _ work: @escaping @MainActor () async throws -> Void) -> Bool {
        guard !actionInFlight else { return false }
        actionInFlight = true
        lastAction = Task { @MainActor [weak self] in
            do {
                try await work()
            } catch {
                self?.failure = CodeTabRemoteFailure(title: failureTitle, message: error.localizedDescription)
            }
            self?.actionInFlight = false
        }
        return true
    }

    /// 记下要选上的会话，过了 `focusTimeout` 还没出现就作废。
    func awaitFocus(_ session: UUID) {
        dropPendingFocus()
        pendingFocus = session
        pendingFocusExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.focusTimeout)
            guard !Task.isCancelled, let self, self.pendingFocus == session else { return }
            self.pendingFocus = nil
            self.pendingFocusExpiry = nil
        }
    }

    func dropPendingFocus() {
        pendingFocus = nil
        pendingFocusExpiry?.cancel()
        pendingFocusExpiry = nil
    }
}

/// 请那台 Mac 做的事没做成（「继续这个会话」「＋新会话」「重新开始」「移到新标签页」）：窗口弹一个提示。
struct CodeTabRemoteFailure: Equatable {
    var title: String
    var message: String
}

extension CodeTabModel {
    // MARK: 跟着那台 Mac

    /// 镜像着的会话此刻的样子（交给 `RemoteCodeRunMirror.plan` 比对）。
    var mirroredRunStates: [RemoteCodeRunMirror.Mirrored] {
        runs.filter(\.isMirrored).map { run in
            RemoteCodeRunMirror.Mirrored(session: run.id, path: run.path, sessionID: run.key?.sessionID, title: run.title,
                                         endedAt: run.endedAt)
        }
    }

    /// 和那台 Mac 上的这个 Code 标签页对一次（`info` 为 nil = 那台 Mac 上已经没有了）。`listed`：它此刻的会话列表。
    func mirrorPlan(_ info: RemoteCodeTabInfo?, listed: Set<UUID>) -> RemoteCodeRunMirror.Plan {
        RemoteCodeRunMirror.plan(mirrored: mirroredRunStates, info: info, listed: listed)
    }

    /// 拿掉镜像着的会话：只断开这边的接入，那台 Mac 上的会话照旧。
    func removeMirroredRuns(_ sessions: [UUID]) {
        for id in sessions { removeMirrored(id)?.terminal.dispose() }
    }

    /// 两边都有的会话照那台 Mac 改：对上的记录、标题、结束时刻。
    func applyMirrorUpdates(_ updated: [RemoteCodeTabInfo.Run]) {
        for info in updated {
            updateMirrored(info.session) { run in
                run.path = info.path
                if let tool = AgentHistoryTool(rawValue: info.tool) {
                    run.key = info.sessionID.map { AgentHistoryPinKey(tool: tool, sessionID: $0) }
                }
                run.title = info.title
                run.endedAt = info.endedAt
            }
        }
    }

    /// 加进那台 Mac 上新出现的会话。`makeTerminal` 按会话 id 建接着它的终端（已经开始接入）。返回加进来的会话 id。
    @discardableResult
    func addMirroredRuns(_ added: [RemoteCodeTabInfo.Run],
                         makeTerminal: (UUID) -> any CodeTabTerminal) -> [UUID] {
        var adopted: [UUID] = []
        for info in added {
            guard let tool = AgentHistoryTool(rawValue: info.tool), !runs.contains(where: { $0.id == info.session }) else {
                continue
            }
            let terminal = makeTerminal(info.session)
            var run = Run(terminal: terminal, tool: tool, directory: info.directory, startedAt: info.startedAt,
                          path: info.path, knownPaths: [], title: info.title,
                          key: info.sessionID.map { AgentHistoryPinKey(tool: tool, sessionID: $0) },
                          resumesRecord: info.sessionID != nil)
            run.isMirrored = true
            run.endedAt = info.endedAt
            if insertMirrored(run) { adopted.append(info.session) } else { terminal.dispose() }
        }
        // 请那台 Mac 开的会话回复先到、这会儿才出现：选上它。
        takePendingFocus()
        return adopted
    }

    /// 第一次开出这个镜像时照那台 Mac 右边看着的选（之后的选中只在这边）。
    func adoptMacSelection(of info: RemoteCodeTabInfo) {
        if let selected = info.selectedRun, runs.first(where: { $0.id == selected })?.isMirrored == true {
            selectRun(selected)
        } else if let stored = info.selectedRecord, let key = AgentHistoryPinKey(stored: stored) {
            selectRecordWhenListed(key)
        }
    }

    /// 不再镜像（那台 Mac 上那个 Code 标签页没了，而这个标签页是用户自己开的、留着）：镜像着的会话全部断开拿掉。
    func stopMirroring() {
        removeMirroredRuns(runs.filter(\.isMirrored).map(\.id))
        remote?.macTabID = nil
        remote?.dropPendingFocus()
    }

    // MARK: 请那台 Mac 做

    /// 继续、新开、重新开始、移到新标签页在那台 Mac 的 Code 标签页里做（它认得 64 号消息）。
    var runsOnRemoteCodeTab: Bool { remote?.supportsActions() == true }

    /// 已结束的会话能不能「重新开始」：在这边起的可以；镜像的要那台 Mac 认得 64 号消息。
    func canRestart(_ id: UUID) -> Bool {
        runs.first { $0.id == id }?.isMirrored != true || runsOnRemoteCodeTab
    }

    /// 「继续这个会话」（`resume(_:)` 转过来）：请那台 Mac 继续这份记录；老 Mac 在它上面新开终端跑 `command`。
    func resumeOnRemote(_ file: AgentHistorySessionFile, command: String, directory: String) {
        guard let remote else { return }
        let title = String(localized: "无法继续这个会话")
        guard runsOnRemoteCodeTab else {
            remote.run(failureTitle: title) { try await remote.runInNewTerminal(command, directory) }
            return
        }
        let action = RemoteCodeTabAction(action: .resume, tab: remote.macTabID, path: file.path, tool: file.tool.rawValue,
                                         sessionID: file.sessionID, directory: directory)
        remote.run(failureTitle: title) { [weak self] in
            let session = try await remote.perform(action)
            self?.focusWhenMirrored(session)
        }
    }

    /// 「＋新会话」（`startNewSession` 转过来）：请那台 Mac 在它的 Code 标签页里新开；老 Mac 在它上面新开终端。
    func startOnRemote(tool: AgentHistoryTool, command: String, directory: String) {
        guard let remote else { return }
        let title = String(localized: "无法新开会话")
        guard runsOnRemoteCodeTab else {
            remote.run(failureTitle: title) { try await remote.runInNewTerminal(command, directory) }
            return
        }
        let action = RemoteCodeTabAction(action: .start, tab: remote.macTabID, tool: tool.rawValue, directory: directory)
        remote.run(failureTitle: title) { [weak self] in
            let session = try await remote.perform(action)
            self?.focusWhenMirrored(session)
        }
    }

    /// 已结束的镜像会话「重新开始」：那台 Mac 在原来的位置起一个新的，这边选上它。老 Mac 不给（`canRestart`）。
    func restartOnRemote(_ id: UUID) {
        guard let remote, runsOnRemoteCodeTab, let run = runs.first(where: { $0.id == id }), run.isMirrored,
              run.isEnded else { return }
        let action = RemoteCodeTabAction(action: .restart, tab: remote.macTabID, session: id)
        remote.run(failureTitle: String(localized: "无法重新开始这个会话")) { [weak self] in
            let session = try await remote.perform(action)
            self?.focusWhenMirrored(session)
        }
    }

    /// 跑着的镜像会话「移到新标签页」：那台 Mac 把它挪成普通终端标签页，推来新的 Code 标签页之后这边拿掉镜像、由窗口开成
    /// 终端标签页。`moved` 拿到挪出去的会话 id（窗口把它放到前台）。老 Mac、没在跑、在途的还没回复时什么都不做。
    func moveToTabOnRemote(_ id: UUID, moved: @escaping @MainActor (UUID) -> Void) {
        guard let remote, runsOnRemoteCodeTab, let run = runs.first(where: { $0.id == id }), run.isMirrored,
              !run.isEnded else { return }
        let action = RemoteCodeTabAction(action: .moveToTab, tab: remote.macTabID, session: id)
        remote.run(failureTitle: String(localized: "无法移到新标签页")) {
            moved(try await remote.perform(action))
        }
    }

    /// 选上镜像着的这个会话；还没出现就等它出现（`takePendingFocus`），过了 `CodeTabRemote.focusTimeout` 作废。
    func focusWhenMirrored(_ session: UUID) {
        guard let remote else { return }
        if runs.first(where: { $0.id == session })?.isMirrored == true {
            remote.dropPendingFocus()
            selectRun(session)
        } else {
            remote.awaitFocus(session)
        }
    }

    /// 镜像里加进了新的会话：在等的那个出现了就选上它。
    func takePendingFocus() {
        guard let remote, let session = remote.pendingFocus,
              runs.first(where: { $0.id == session })?.isMirrored == true else { return }
        remote.dropPendingFocus()
        selectRun(session)
    }
}
