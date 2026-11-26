import Foundation
import UPaneGroups

// 设备请 Mac 在某台 SSH 主机的 Code 标签页里做的事（远控 64 号消息，`RemoteCodeTabAction.server`）落到那台主机的
// 工作区 / 终端窗口上（`WorkspaceModel`）。本机的见 `LocalShellCodeTabActions`，分流在 `RemoteCodeTabActor.route`。

extension RemoteCodeTabAction {
    /// 要在哪台 SSH 主机的 Code 标签页里做；没带主机或是 Mac 本机的为 nil（照旧交给本机终端窗口）。
    var sshServer: UUID? {
        guard let server, server != RemoteConstants.localShellServerID else { return nil }
        return server
    }
}

/// 找到做这件事的那台主机的窗口（规则见 `perform`），交给它（`WorkspaceModel.performCodeTabAction`）。
@MainActor
enum WorkspaceCodeTabActions {
    /// `workspaces` 是 Mac 上的工作区 / 终端窗口（`TerminalSessionRegistry.codeTabWorkspaces()`）。只在 `host` 的窗口里找：
    ///
    /// - 「重新开始」「移到新标签页」：哪个窗口里 `host` 的 Code 标签页跑着那个会话就交给它。
    /// - 「继续」「新会话」：交给有 `host` 的 Code 标签页的窗口（一台主机只开一个；设备点名的那个优先）；都没有就交给连着
    ///   这台主机的窗口（有它的终端标签页，或窗口就是这台主机的），由它新开一个。一个都没有时回错误：不替设备在 Mac 上
    ///   新开窗口、新建 SSH 连接，也绝不落到本机终端上。
    static func perform(_ action: RemoteCodeTabAction, host: UUID, workspaces: [WorkspaceModel],
                        historyWait: Duration? = nil) async -> RemoteCodeTabActionResult {
        guard let kind = action.knownAction else { return .failure(action, LocalShellCodeTabText.unknownAction) }
        switch kind {
        case .restart, .moveToTab:
            guard let session = action.session,
                  let owner = workspaces.first(where: { $0.codeTab(running: session)?.tab.payload.serverProfileID == host })
            else { return .failure(action, LocalShellCodeTabText.sessionGone) }
            return await owner.performCodeTabAction(action, historyWait: historyWait)
        case .resume, .start:
            let owner = action.tab.flatMap { tab in workspaces.first { $0.codeTabID(of: host) == tab } }
                ?? workspaces.first { $0.codeTabID(of: host) != nil }
                ?? workspaces.first { $0.codeTabHostName(host) != nil }
            guard let owner else { return .failure(action, WorkspaceCodeTabText.noHostWindow) }
            return await owner.performCodeTabAction(action, historyWait: historyWait)
        }
    }
}

extension WorkspaceModel: CodeTabActionHost {
    func codeTabHolding(_ session: UUID) -> (tabID: UUID, code: CodeTabModel)? {
        codeTab(running: session).map { ($0.tab.id, $0.code) }
    }

    func activateCodeTab(_ tabID: UUID) {
        guard let at = terminalGroups.locateTab(tabID) else { return }
        terminalGroups.activateTab(groupID: at.groupID, index: at.index)
    }

    func hasTerminalTab(_ session: UUID) -> Bool {
        terminalGroups.allTabs.contains { $0.payload.isTerminal && $0.payload.id == session }
    }

    /// `action.server` 的 Code 标签页：本窗口有就切过去，没有就在本窗口新开（`WorkspaceCodeTabActions.perform` 只把连着这台
    /// 主机的窗口交过来）。不是 SSH 主机的、这个窗口不连这台主机的为 nil。
    func codeTabForRemote(_ action: RemoteCodeTabAction) -> CodeTabModel? {
        guard let host = action.sshServer else { return nil }
        let id: UUID
        if let existing = focusCodeTab(host: host, directory: nil) {
            id = existing
        } else {
            guard let name = codeTabHostName(host) else { return nil }
            id = openCodeTab(serverID: host, hostName: name, directory: action.directory)
        }
        return terminalGroups.tab(id)?.payload.codeTab
    }

    /// 本窗口里 `host` 的 Code 标签页报给设备的 id（`remoteCodeTabs`，即 `PaneModel.id`）；没有为 nil。
    func codeTabID(of host: UUID) -> UUID? {
        terminalGroups.allTabs.first { $0.payload.codeTab != nil && $0.payload.serverProfileID == host }?.payload.id
    }

    /// 这个窗口连着 `host` 时，给它新开的 Code 标签页用的主机名：它的终端标签页连上时的名字（没有就标签名），或窗口绑定的
    /// 就是这台主机（工作区窗口）。不连这台主机为 nil。
    func codeTabHostName(_ host: UUID) -> String? {
        if let pane = terminalPanes.first(where: { $0.serverProfileID == host }),
           let name = pane.connectedServerName ?? pane.tabTitle {
            return name
        }
        return defaultServerProfileID == host ? defaultServerTitle : nil
    }
}

/// 回给设备的失败原因（其余的同本机，见 `LocalShellCodeTabText`）。
@MainActor
enum WorkspaceCodeTabText {
    static var noHostWindow: String {
        String(localized: "Mac 上没有开着这台主机的窗口。先在 Mac 上打开这台主机的终端，再试一次")
    }
}
