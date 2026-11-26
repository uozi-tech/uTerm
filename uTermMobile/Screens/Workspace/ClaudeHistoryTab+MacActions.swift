import Foundation

/// 配对的 Mac 认得 `codeTabAction`（64 号消息，`RemoteCodeTabAction`）时，这台 Mac 的 Code 标签页里的「继续这个会话」
/// 「＋新会话」「重新开始」「移到新标签页」都请 Mac 在它自己的 Code 标签页里做：会话起在 Mac 的 Code 标签页里，
/// 再经镜像（63 号消息，`ClaudeHistoryTab+Mirror`）出现在这里，不再在 Mac 上另开一个本机终端标签页。
/// 老 Mac 不认，照旧开终端标签页（`runInNewTerminal`）。
///
/// Mac 回复（65 号）里是做完之后的那个会话：它在 Mac 推来的 Code 标签页里可能先到也可能后到，先到的当场选上，
/// 后到的记着（`pendingMacFocus`），出现时再选（`addMirroredRuns` 里调 `takePendingMacFocus`），过一会儿还没出现就作废。
/// 在途的请求没回复之前再点不再发。做不成抛出来（`RemoteAttachError.rejected`，带给人看的原因），由界面提示。
extension ClaudeHistoryTab {
    /// 回复里的会话最多等它这么久出现在 Mac 推来的 Code 标签页里。
    nonisolated static var macFocusTimeout: Duration { .seconds(20) }
    /// 手机还没接管这台 Mac（没在跟进它的终端与 Code 标签页）时，接管之前先等 Mac 推来的 Code 标签页里出现那个会话，
    /// 最多等这么久：接管时它已经归 Code 标签页，就不会先被开成一个终端标签页。
    nonisolated static var macTakeoverWait: Duration { .seconds(5) }

    /// 这台 Mac 的「继续」「＋」「重新开始」「移到新标签页」在它的 Code 标签页里做。
    var runsOnMacCodeTab: Bool { remoteMac != nil && macSupportsCodeTabActions() }

    /// 这份记录正在那台 Mac 的 Code 标签页里跑着（镜像过来的）：回到它的终端，返回 true。不是就什么都不做。
    @discardableResult
    func focusRunningMirror(for file: AgentHistorySessionFile) -> Bool {
        guard let run = runs.run(forSession: file.path), run.isMirrored, run.isRunning else { return false }
        selectMirroredRun(run.id)
        return true
    }

    /// 「继续这个会话」：请 Mac 在它的 Code 标签页里继续这份记录（`directory` 是这边算的继续目录，Mac 对不上记录时用它）。
    /// 已经在那里跑着就只回到它，不发。`workspace` / `store`：手机还没接管这台 Mac 时由它们接管（见 `follow`）。
    func resumeOnMac(_ file: AgentHistorySessionFile, directory: String,
                     workspace: MobileWorkspace? = nil, store: MobileStore? = nil) async throws {
        if focusRunningMirror(for: file) { return }
        let action = RemoteCodeTabAction(action: .resume, tab: mirroredMacTabID, path: file.path,
                                         tool: file.tool.rawValue, sessionID: file.sessionID, directory: directory)
        guard let session = try await performOnMac(action) else { return }
        follow(session, workspace: workspace, store: store)
    }

    /// 「＋新会话」：请 Mac 在它的 Code 标签页里新开一个。
    func startOnMac(tool: AgentHistoryTool, directory: String,
                    workspace: MobileWorkspace? = nil, store: MobileStore? = nil) async throws {
        let action = RemoteCodeTabAction(action: .start, tab: mirroredMacTabID, tool: tool.rawValue, directory: directory)
        guard let session = try await performOnMac(action) else { return }
        follow(session, workspace: workspace, store: store)
    }

    /// 已结束的镜像会话「重新开始」：Mac 在原来的位置起一个新的（同一种工具、同一个目录），这边选上它。
    func restartOnMac(_ id: UUID) async throws {
        guard let run = runs.run(id: id), run.isMirrored, !run.isRunning else { return }
        let action = RemoteCodeTabAction(action: .restart, tab: mirroredMacTabID, session: id)
        guard let session = try await performOnMac(action) else { return }
        focusWhenMirrored(session)
    }

    /// 跑着的镜像会话「移到新标签页」：Mac 把它挪成它那边的普通终端标签页，Mac 推来新的 Code 标签页之后这边拿掉镜像、
    /// 由跟进开成远控终端标签页（`MobileWorkspace.follow`），开出来时放到前台。
    func moveMirroredRunToTab(_ id: UUID, in workspace: MobileWorkspace) async throws {
        guard let run = runs.run(id: id), run.isMirrored, run.isRunning, let client = remoteMac else { return }
        let action = RemoteCodeTabAction(action: .moveToTab, tab: mirroredMacTabID, session: id)
        guard let session = try await performOnMac(action) else { return }
        workspace.bringToFront(remote: MRemoteSource(client: client, sessionID: session))
    }

    /// 发给 Mac、等回复。老 Mac、在途的还没回复时不发（nil）。
    private func performOnMac(_ action: RemoteCodeTabAction) async throws -> UUID? {
        guard runsOnMacCodeTab, !macActionInFlight else { return nil }
        macActionInFlight = true
        defer { macActionInFlight = false }
        return try await macCodeTabAction(action)
    }

    /// 「继续」「＋」做完：选上那个会话。手机还没接管这台 Mac 时接管它（同老 Mac 那条路：开会话总是带着整台接管），
    /// 那个会话就在这个 Code 标签页里接上、放到前台（`MobileWorkspace.takeOver` 接上用户开着的这个标签页）。
    private func follow(_ session: UUID, workspace: MobileWorkspace?, store: MobileStore?) {
        guard let client = remoteMac, let workspace, let store,
              !workspace.followedClients.contains(where: { $0 === client }) else {
            focusWhenMirrored(session)
            return
        }
        focusWhenMirrored(session)
        Task { [weak client, weak store] in
            let deadline = ContinuousClock.now + Self.macTakeoverWait
            while let client, !client.codeRunSessionIDs.contains(session), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let client, let store else { return }
            store.takeOver(client, focus: session)
        }
    }

    /// 选上镜像着的这个会话、看它的终端；还没出现就等它出现（`takePendingMacFocus`），过了 `macFocusTimeout` 作废。
    func focusWhenMirrored(_ session: UUID) {
        pendingMacFocusExpiry?.cancel()
        pendingMacFocusExpiry = nil
        if runs.run(id: session)?.isMirrored == true {
            pendingMacFocus = nil
            selectMirroredRun(session)
            return
        }
        pendingMacFocus = session
        pendingMacFocusExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.macFocusTimeout)
            guard !Task.isCancelled, let self, self.pendingMacFocus == session else { return }
            self.pendingMacFocus = nil
            self.pendingMacFocusExpiry = nil
        }
    }

    /// 镜像里加进了新的会话：在等的那个出现了就选上它。
    func takePendingMacFocus() {
        guard let session = pendingMacFocus, runs.run(id: session)?.isMirrored == true else { return }
        pendingMacFocus = nil
        pendingMacFocusExpiry?.cancel()
        pendingMacFocusExpiry = nil
        selectMirroredRun(session)
    }

    /// 不再镜像：在等的作废。
    func dropPendingMacFocus() {
        pendingMacFocus = nil
        pendingMacFocusExpiry?.cancel()
        pendingMacFocusExpiry = nil
    }
}

/// Code 标签页里镜像会话的「重新开始」「移到新标签页」：请 Mac 做的走 Mac（失败交 `onFailure`），其余照旧在这边做。
extension CodeTabRuns {
    /// 已结束的会话能不能「重新开始」：在这边起的可以；镜像那台 Mac 的要 Mac 认得 `codeTabAction`。
    func canRestart(_ run: CodeRunBoard<TermTab>.Run) -> Bool {
        !run.isMirrored || tab.runsOnMacCodeTab
    }

    /// 能不能「移到新标签页」：要有工作区可放；镜像那台 Mac 的要 Mac 认得 `codeTabAction`。
    func canMoveToTab(_ run: CodeRunBoard<TermTab>.Run) -> Bool {
        onMoveToTab != nil && (!run.isMirrored || tab.runsOnMacCodeTab)
    }

    func restart(_ id: UUID) {
        guard tab.runs.run(id: id)?.isMirrored == true else {
            tab.restartRun(id)
            return
        }
        perform(failureTitle: String(localized: "无法重新开始这个会话")) { try await tab.restartOnMac(id) }
    }

    /// 在 Mac 上做一件事；做不成交给 `onFailure`。
    func perform(failureTitle: String, _ work: @escaping @MainActor () async throws -> Void) {
        let onFailure = onFailure
        Task { @MainActor in
            do {
                try await work()
            } catch {
                onFailure?(CodeActionFailure(title: failureTitle, message: error.localizedDescription))
            }
        }
    }
}

/// 请 Mac 做的事没做成（「继续这个会话」「重新开始」「移到新标签页」）：工作区屏弹一个提示。
struct CodeActionFailure: Equatable {
    var title: String
    var message: String
}
