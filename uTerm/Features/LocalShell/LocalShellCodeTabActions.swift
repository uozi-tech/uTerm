import Foundation
import UPaneGroups

// 设备请 Mac 在它的 Code 标签页里做的事（远控 64 号消息，`RemoteCodeTabAction`）落到本机终端窗口上。
// App 进程里的落点；远控进程经 XPC 转到这里（`RemoteHostAgentBridge`）。

extension RemoteCodeTabActor {
    /// App 里接上 Mac 的窗口：要打开「允许打开本机终端」（SSH 主机的也是这个开关）。本机的交给本机终端窗口，Mac 上还没有
    /// 本机终端窗口时开一个，只留 Code 标签页；SSH 主机的（`action.server`）交给那台主机的工作区 / 终端窗口，见 `route`。
    @MainActor
    static func live(settings: RemoteControlSettings, registry: TerminalSessionRegistry) -> RemoteCodeTabActor {
        RemoteCodeTabActor { [weak settings, weak registry] action in
            guard let settings, let registry else { return .failure(action, String(localized: "uTerm 正在退出")) }
            guard settings.isLocalShellEnabled else {
                return .failure(action, String(localized: "Mac 上没有打开「允许打开本机终端」。在 Mac 的 uTerm 里打开「设置 › 远程控制」。"))
            }
            return await route(action, localWindows: LocalShellWindowRouter.shared.modelsByRecency,
                               workspaces: registry.codeTabWorkspaces(),
                               openLocalWindow: { directory in await openWindow(directory: directory, registry: registry) })
        }
    }

    /// 按 `action.server` 分：没带或是本机的照旧交给本机终端窗口（`LocalShellCodeTabActions.perform`）；SSH 主机的只交给
    /// 那台主机的窗口（`WorkspaceCodeTabActions.perform`），那台主机一个窗口都没有时回错误，绝不落到本机终端上。
    @MainActor
    static func route(_ action: RemoteCodeTabAction, localWindows: [LocalShellWindowModel], workspaces: [WorkspaceModel],
                      openLocalWindow: @MainActor (String?) async
                          -> Result<LocalShellCodeTabActions.OpenedWindow, RemoteLocalShellOpener.Failure>,
                      historyWait: Duration? = nil) async -> RemoteCodeTabActionResult {
        if let host = action.sshServer {
            return await WorkspaceCodeTabActions.perform(action, host: host, workspaces: workspaces, historyWait: historyWait)
        }
        return await LocalShellCodeTabActions.perform(action, windows: localWindows, openWindow: openLocalWindow,
                                                      historyWait: historyWait)
    }

    /// 开一个本机终端窗口（同手机「新建本机终端」），等它的 shell 登记、窗口的 model 出现。
    @MainActor
    private static func openWindow(directory: String?, registry: TerminalSessionRegistry)
        async -> Result<LocalShellCodeTabActions.OpenedWindow, RemoteLocalShellOpener.Failure> {
        let waitSeconds = RemoteLocalShellOpener.waitSeconds
        guard let open = registry.openLocalShell, let paneID = open(directory) else {
            return .failure(.init(message: String(localized: "Mac 上的 uTerm 还没准备好打开窗口，稍后再试")))
        }
        let failure = RemoteLocalShellOpener.Failure(
            message: String(localized: "本机终端未能在 \(waitSeconds) 秒内启动，原因见 Mac 上的本机终端窗口"))
        guard await registry.waitForSession(id: paneID, timeout: .seconds(waitSeconds)) != nil else {
            return .failure(failure)
        }
        // 窗口的 model 在视图挂进窗口时登记（`LocalShellWindowRouterBinding`），一般早于 shell 登记。
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let model = LocalShellWindowRouter.shared.model(containing: paneID) {
                return .success(.init(model: model, firstPane: paneID))
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return .failure(failure)
    }
}

/// 找到做这件事的本机终端窗口（规则见 `perform`），交给它（`LocalShellWindowModel.performCodeTabAction`）。
@MainActor
enum LocalShellCodeTabActions {
    /// 替这次请求新开的窗口和它起的第一个 shell。
    struct OpenedWindow {
        let model: LocalShellWindowModel
        let firstPane: UUID
    }

    /// `windows` 是本机终端窗口，最近活跃的在前。
    ///
    /// - 「重新开始」「移到新标签页」：哪个窗口的 Code 标签页里跑着那个会话就交给它。
    /// - 「继续」「新会话」：交给有 Code 标签页的窗口（这台 Mac 只开一个；设备点名的那个优先）；都没有就交给最近活跃的窗口，
    ///   由它新开一个。一个本机终端窗口都没有时开一个（`openWindow`），做完关掉它起的那个 shell，窗口里只留 Code 标签页。
    static func perform(_ action: RemoteCodeTabAction, windows: [LocalShellWindowModel],
                        openWindow: @MainActor (String?) async -> Result<OpenedWindow, RemoteLocalShellOpener.Failure>,
                        historyWait: Duration? = nil) async -> RemoteCodeTabActionResult {
        guard let kind = action.knownAction else { return .failure(action, LocalShellCodeTabText.unknownAction) }
        switch kind {
        case .restart, .moveToTab:
            guard let session = action.session,
                  let model = windows.first(where: { $0.codeTab(running: session) != nil }) else {
                return .failure(action, LocalShellCodeTabText.sessionGone)
            }
            return await model.performCodeTabAction(action, historyWait: historyWait)
        case .resume, .start:
            let owner = action.tab.flatMap { tab in windows.first { $0.groups.tab(tab)?.payload.codeTab != nil } }
                ?? windows.first { $0.hasCodeTab }
                ?? windows.first
            if let owner { return await owner.performCodeTabAction(action, historyWait: historyWait) }
            switch await openWindow(action.directory) {
            case .failure(let failure):
                return .failure(action, failure.message)
            case .success(let opened):
                let result = await opened.model.performCodeTabAction(action, historyWait: historyWait)
                // 窗口是替这次请求开的：Code 标签页开出来了就关掉它起的那个 shell，窗口里只留 Code 标签页。
                if opened.model.hasCodeTab, opened.model.groups.locateTab(opened.firstPane) != nil {
                    opened.model.close(opened.firstPane)
                }
                return result
            }
        }
    }
}

/// 一个能在它的 Code 标签页里替设备做事的窗口：本机终端窗口（`LocalShellWindowModel`），SSH 主机的工作区 / 终端窗口
///（`WorkspaceModel`，见 `WorkspaceCodeTabActions`）。做法两边一样（`performCodeTabAction`），只是标签树不同。
@MainActor
protocol CodeTabActionHost: AnyObject {
    /// 跑着 `session` 这个会话的 Code 标签页：标签 id 与它的模型。
    func codeTabHolding(_ session: UUID) -> (tabID: UUID, code: CodeTabModel)?
    /// 把这个标签切到前台。
    func activateCodeTab(_ tabID: UUID)
    /// 「移到新标签页」。
    func moveCodeRunToTab(_ runID: UUID, fromCodeTab tabID: UUID)
    /// 有一个跑着 `session` 的普通终端标签页（「移到新标签页」之后用来核对）。
    func hasTerminalTab(_ session: UUID) -> Bool
    /// 做「继续」「新会话」的那个 Code 标签页，切到前台（已经有的不改它「新会话」的目录）；没有就新开一个（开在
    /// `action.directory`）。开不了为 nil。
    func codeTabForRemote(_ action: RemoteCodeTabAction) -> CodeTabModel?
}

extension CodeTabActionHost {
    /// 新开的 Code 标签页等文件通道接好、列表列出来的上限（`CodeTabModel.waitForHistory`）。
    static var codeTabHistoryWait: Duration { .seconds(10) }

    /// 在这个窗口的 Code 标签页里做设备请的一件事，回做完之后的那个会话或失败原因。Mac 上照本机点的那样显示：
    /// 切到 Code 标签页、右边是那个会话（「移到新标签页」切到挪出去的那个标签）。窗口里还没有 Code 标签页时，「继续」
    /// 「新会话」先开一个，等它接好列表再做。做完照常推 63 / 20 号消息（注册表的观察）。`historyWait` 为 nil 时等
    /// `codeTabHistoryWait`。
    func performCodeTabAction(_ action: RemoteCodeTabAction, historyWait: Duration? = nil) async
        -> RemoteCodeTabActionResult {
        guard let kind = action.knownAction else { return .failure(action, LocalShellCodeTabText.unknownAction) }
        switch kind {
        case .restart:
            guard let id = action.session, let (tabID, code) = codeTabHolding(id),
                  let old = code.runs.first(where: { $0.id == id }) else {
                return .failure(action, LocalShellCodeTabText.sessionGone)
            }
            guard old.isEnded else { return .failure(action, LocalShellCodeTabText.stillRunning) }
            guard let run = code.restart(id) else { return .failure(action, LocalShellCodeTabText.restartFailed) }
            activateCodeTab(tabID)
            code.selectRun(run.id)
            return .success(action, session: run.id)
        case .moveToTab:
            guard let id = action.session, let (tabID, _) = codeTabHolding(id) else {
                return .failure(action, LocalShellCodeTabText.sessionGone)
            }
            moveCodeRunToTab(id, fromCodeTab: tabID)
            guard codeTabHolding(id) == nil, hasTerminalTab(id) else {
                return .failure(action, LocalShellCodeTabText.moveFailed)
            }
            return .success(action, session: id)
        case .resume, .start:
            guard let tool = action.tool.flatMap(AgentHistoryTool.init(rawValue:)) else {
                return .failure(action, LocalShellCodeTabText.unsupportedTool)
            }
            guard let code = codeTabForRemote(action),
                  await code.waitForHistory(timeout: historyWait ?? Self.codeTabHistoryWait) != nil else {
                return .failure(action, LocalShellCodeTabText.notReady)
            }
            if kind == .resume {
                guard let run = code.resume(path: action.path, tool: tool, sessionID: action.sessionID,
                                            directory: action.directory) else {
                    return .failure(action, LocalShellCodeTabText.resumeFailed)
                }
                return .success(action, session: run.id)
            }
            guard let directory = action.directory ?? code.newSessionDirectory else {
                return .failure(action, LocalShellCodeTabText.noDirectory)
            }
            guard let run = code.startNewSession(tool: tool, in: directory) else {
                return .failure(action, LocalShellCodeTabText.startFailed)
            }
            return .success(action, session: run.id)
        }
    }
}

extension LocalShellWindowModel: CodeTabActionHost {
    /// 这个窗口里有 Code 标签页。
    var hasCodeTab: Bool { groups.allTabs.contains { $0.payload.codeTab != nil } }

    func codeTabHolding(_ session: UUID) -> (tabID: UUID, code: CodeTabModel)? {
        codeTab(running: session).map { ($0.tab.id, $0.code) }
    }

    func hasTerminalTab(_ session: UUID) -> Bool { groups.locateTab(session) != nil }

    /// 这台 Mac 的 Code 标签页在别的窗口里时为 nil（`LocalShellCodeTabActions.perform` 不会这样交过来）。
    func codeTabForRemote(_ action: RemoteCodeTabAction) -> CodeTabModel? {
        let id = hasCodeTab ? focusCodeTab(directory: nil) : Optional(openCodeTab(directory: action.directory))
        return id.flatMap { groups.tab($0)?.payload.codeTab }
    }

    func activateCodeTab(_ id: UUID) {
        guard let at = groups.locateTab(id) else { return }
        groups.activateTab(groupID: at.groupID, index: at.index)
    }
}

/// 回给设备的失败原因。
@MainActor
enum LocalShellCodeTabText {
    static var unknownAction: String {
        String(localized: "Mac 上的 uTerm 不认识这个操作。把 Mac 上的 uTerm 更新到最新版后再试")
    }
    static var sessionGone: String { String(localized: "这个会话已经不在 Mac 的 Code 标签页里了") }
    static var stillRunning: String { String(localized: "这个会话还在运行，结束之后才能重新开始") }
    static var restartFailed: String { String(localized: "Mac 上没能重新开始这个会话") }
    static var moveFailed: String { String(localized: "Mac 上没能把这个会话移到新标签页") }
    static var unsupportedTool: String { String(localized: "Mac 上的 uTerm 不支持这种编码工具") }
    static var notReady: String { String(localized: "Mac 上的 Code 标签页还没准备好，稍后再试") }
    static var resumeFailed: String { String(localized: "Mac 上没能继续这个会话") }
    static var noDirectory: String { String(localized: "要先选一个目录才能新开会话") }
    static var startFailed: String { String(localized: "Mac 上没能在这个目录里新开会话") }
}
