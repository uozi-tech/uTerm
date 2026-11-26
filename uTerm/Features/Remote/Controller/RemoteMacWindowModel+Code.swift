import Foundation
import UPaneGroups

/// 那台 Mac 的 Code 标签页在这扇窗口里怎么镜像：要它报 Code 标签页（`code-tabs`）、也认得文件请求（`files`，历史会话经
/// 文件通道读它的 `~/.claude`）。不认的照旧：Code 标签页里的会话各开一个终端标签。测试换成假的（不连真 Mac 时读不到握手能力）。
struct RemoteMacCodeTabHooks {
    var isSupported: @MainActor (RemoteMacClient) -> Bool = { $0.supportsCodeTabs && $0.supportsFiles }
    var supportsActions: @MainActor (RemoteMacClient) -> Bool = { $0.supportsCodeTabActions }
    var perform: @MainActor (RemoteMacClient, RemoteCodeTabAction) async throws -> UUID = {
        try await $0.performCodeTabAction($1)
    }
    var end: @MainActor (RemoteMacClient, UUID) -> Void = { $0.closeSessionOnMac($1) }
}

/// 镜像那台 Mac 的 Code 标签页时第一步做完、等第二步加进来的会话（见 `RemoteMacWindowModel.follow`）。
struct RemoteMacPendingCodeRuns {
    let code: CodeTabModel
    let info: RemoteCodeTabInfo
    let added: [RemoteCodeTabInfo.Run]
    /// 刚开出来：照那台 Mac 那边看着的选一次。
    let adoptsSelection: Bool
}

/// 同手机（`MobileWorkspace` 的镜像那一节），规则一样：
///
/// - 那台 Mac 有 Code 标签页（取 `mirrored()` 那一个，本机的）：这扇窗口里有用户自己开的 Code 标签页就接上它，没有就在后台
///   开一个（`opensForMirror`），排在 Mac 上它的位置（`slot`）。一扇窗口至多一个 Code 标签页。
/// - Mac 上的 Code 标签页没了：镜像才开出来的关掉，用户自己开的留着、只停镜像。
/// - 用户关掉镜像着的 Code 标签页：只断开镜像，重新接管之前不再自动开（`closedCodeTabs`），里面的会话也不另开终端标签。
/// - 只在第一次开出来时照 Mac 那边右边看着的选。
extension RemoteMacWindowModel {
    /// 这扇窗口的 Code 标签页（至多一个）。
    var codePane: RemoteTerminalPane? {
        groups.allTabs.lazy.map(\.payload).first { $0.codeTab != nil }
    }

    /// 能不能在这扇窗口里开 Code 标签页（标签条按钮、右键「历史会话…」）。不能的照旧开独立的历史会话窗口。
    var offersCodeTab: Bool { codeHooks.isSupported(client) }

    /// 那台 Mac 能在它的 Code 标签页里做事（继续、新开、重新开始、移到新标签页）。
    var supportsCodeTabActions: Bool { codeHooks.supportsActions(client) }

    /// 归 Code 标签页、不开成终端标签的会话。不镜像的 Mac 没有。
    var codeRunSessionIDs: Set<UUID> { offersCodeTab ? client.codeRunSessionIDs : [] }

    /// 这个标签在那台 Mac 的标签顺序里是谁：终端标签是它接着的会话，镜像着的 Code 标签页是 Mac 上那个 Code 标签页；
    /// 还没在镜像的 Code 标签页不在 Mac 上，为 nil。
    func orderID(of pane: RemoteTerminalPane) -> UUID? {
        guard let code = pane.codeTab else { return pane.id }
        return code.remote?.macTabID
    }

    /// Mac 的标签顺序里插进 Code 标签页（按它报的 `slot`）。没镜像、没报位置时原样。
    func withCodeTab(_ order: [UUID]) -> [UUID] {
        guard let info = client.codeTabs?.mirrored(), info.slot != nil,
              codePane?.codeTab?.remote?.macTabID == info.id else { return order }
        return order.insertingCodeTabs([(info.id, info.slot)])
    }

    // MARK: 打开

    /// 标签条上的 Code 按钮、终端标签右键「历史会话…」：已经有就切过去，没有就开一个（开在活动组、放到前台），
    /// 那台 Mac 有 Code 标签页就接上它。用户关过的镜像也重新接上（用户就是想看它）。返回 Code 标签页的 id。
    @discardableResult
    func openCodeTab() -> UUID {
        if let pane = codePane, let at = groups.locateTab(pane.id) {
            groups.activateTab(groupID: at.groupID, index: at.index)
            return pane.id
        }
        // 用户先前拖过的标签先记下来（同 `openNewShell`），再开。
        layoutChanged()
        closedCodeTabs = []
        let pane = makeCodePane(opensForMirror: false)
        groups.openTab { UPaneTab(id: pane.id, payload: pane) }
        if let sessions = client.listedSessionIDs {
            let pending = beginCodeTabMirror(listed: Set(sessions))
            finishCodeTabMirror(pending)
            // 接上了 Mac 的 Code 标签页：排到 Mac 上它的位置（用户亲手排过就不动）。
            if pending != nil, let order = takeover?.arrangement(client.sessions.macTabOrder) {
                arrange(by: withCodeTab(order))
            }
        }
        recordLayout()
        return pane.id
    }

    private func makeCodePane(opensForMirror: Bool) -> RemoteTerminalPane {
        let client = client
        let hooks = codeHooks
        let remote = CodeTabRemote(
            supportsActions: { hooks.supportsActions(client) },
            perform: { try await hooks.perform(client, $0) },
            end: { hooks.end(client, $0) },
            runInNewTerminal: { [weak self] command, directory in
                guard let self else { throw RemoteProtocolError.closed }
                try await self.resumeAgentSession(directory: directory, command: command)
            })
        remote.opensForMirror = opensForMirror
        // 这边从不自己起终端：会话都在那台 Mac 上起（老 Mac 开成终端标签，见 `CodeTabRemote.runInNewTerminal`）。
        let code = CodeTabModel(hostName: client.macName, directory: nil, directoryChooser: .typedPath, remote: remote,
                                makeTerminal: { _ in nil })
        return RemoteTerminalPane(id: UUID(), client: client, codeTab: code)
    }

    /// Code 标签页的文件通道：经远控链路读那台 Mac 上的记录（同独立历史会话窗口，置顶按那台 Mac 的设备 ID 记）。
    func makeCodeConnection(for code: CodeTabModel) -> AgentHistoryConnection {
        let client = client
        return AgentHistoryConnection(preferredDirectory: code.newSessionDirectory, tools: AgentHistoryTool.allCases,
                                      followsCurrentProject: false,
                                      pinHost: { client.macDeviceID.map(AgentHistoryPinHost.pairedMac) },
                                      connect: AgentHistoryAccess.pairedMac(client))
    }

    // MARK: 跟着那台 Mac

    /// 第一步：要镜像就确保有这扇窗口的 Code 标签页、拿掉不再归它的会话、其余照 Mac 改。Mac 上没有了：镜像开出来的关掉，
    /// 用户自己开的留着、只停镜像。用户关过的不再开。还没收到 Mac 的 Code 标签页（刚连上、断开了）、不镜像的 Mac 什么都不动。
    func beginCodeTabMirror(listed: Set<UUID>) -> RemoteMacPendingCodeRuns? {
        guard offersCodeTab, let tabs = client.codeTabs else { return nil }
        let existing = codePane
        guard let info = tabs.mirrored(), !closedCodeTabs.contains(info.id) else {
            if let existing, let code = existing.codeTab, let remote = code.remote, remote.macTabID != nil {
                if remote.opensForMirror, tabs.mirrored() == nil, let at = groups.locateTab(existing.id) {
                    groups.closeTab(groupID: at.groupID, index: at.index)
                } else {
                    code.stopMirroring()
                }
            }
            return nil
        }
        let code: CodeTabModel
        let isNew: Bool
        if let existing, let found = existing.codeTab {
            code = found
            isNew = false
        } else {
            let pane = makeCodePane(opensForMirror: true)
            openInBackground(pane)
            code = pane.codeTab!
            isNew = true
        }
        guard let remote = code.remote else { return nil }
        remote.macTabID = info.id
        if code.newSessionDirectory == nil, let directory = info.directory { code.chooseNewSessionDirectory(directory) }
        let plan = code.mirrorPlan(info, listed: listed)
        code.removeMirroredRuns(plan.removed)
        code.applyMirrorUpdates(plan.updated)
        return RemoteMacPendingCodeRuns(code: code, info: info, added: plan.added, adoptsSelection: isNew)
    }

    /// 第二步：加进 Mac 上新出现的会话（各自开始接入）；刚开出来的照 Mac 那边看着的选一次。
    func finishCodeTabMirror(_ pending: RemoteMacPendingCodeRuns?) {
        guard let pending else { return }
        let client = client
        let startTerminal = startTerminal
        pending.code.addMirroredRuns(pending.added) { session in
            let pane = RemoteTerminalPane(id: session, client: client)
            startTerminal(pane)
            return pane
        }
        if pending.adoptsSelection { pending.code.adoptMacSelection(of: pending.info) }
    }

    /// 开在活动组末尾，不抢前台（窗口里还没有标签时它就是前台）。
    private func openInBackground(_ pane: RemoteTerminalPane) {
        let previous = groups.activeTab?.id
        groups.openTab { UPaneTab(id: pane.id, payload: pane) }
        if let previous, let at = groups.locateTab(previous) {
            groups.activateTab(groupID: at.groupID, index: at.index)
        }
    }

    // MARK: 移到新标签页

    /// Code 标签页里一个会话的「移到新标签页」：请那台 Mac 挪成它那边的普通终端标签，它推来新的 Code 标签页之后这边拿掉
    /// 镜像、由跟进开成终端标签，开出来时放到前台。
    func moveCodeRunToTab(_ runID: UUID) {
        codePane?.codeTab?.moveToTabOnRemote(runID) { [weak self] session in self?.bringToFront(session) }
    }

    /// 把接着那台 Mac 上这个会话的终端标签放到前台；还没开出来就等它开出来时放（`open`）。
    func bringToFront(_ session: UUID) {
        if let at = groups.locateTab(session) {
            frontOnOpen = nil
            groups.activateTab(groupID: at.groupID, index: at.index)
        } else {
            frontOnOpen = session
        }
    }
}
