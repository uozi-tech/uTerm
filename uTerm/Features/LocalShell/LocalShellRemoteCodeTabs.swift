import Foundation
import UPaneGroups

extension LocalShellWindowModel {
    /// 这个窗口里的 Code 标签页，按窗口里的标签先后（远控 63 号消息，见 `TerminalSessionRegistry.codeTabs()`）。
    /// 在观察里读会跟踪到标签树、每个 Code 标签页里的会话、它们的标题与状态。
    func remoteCodeTabs() -> [TerminalSessionRegistry.CodeTabPublication] {
        let codeTabIDs = Set(groups.allTabs.filter { $0.payload.codeTab != nil }.map(\.id))
        guard !codeTabIDs.isEmpty else { return [] }
        let order = groups.snapshot(Self.layoutTabID).tabOrder
        return order.compactMap { id in
            guard codeTabIDs.contains(id), let code = groups.tab(id)?.payload.codeTab else { return nil }
            // 排在它前面的 shell 标签（Code 标签页不是会话，不占位置）。
            let preceding = order.prefix { $0 != id }.filter { !codeTabIDs.contains($0) }
            return .init(info: code.remoteInfo(id: id), precedingSessions: preceding)
        }
    }
}

extension CodeTabModel {
    /// 给接管这台 Mac 的设备的样子（`RemoteCodeTabInfo`）：哪些会话在里面跑着、各叫什么、结束了没有、右边看着哪个。
    /// `slot` 由注册表算。选中的认法同存进布局的那份（`record(id:)`）。
    func remoteInfo(id: UUID, serverID: UUID = RemoteConstants.localShellServerID) -> RemoteCodeTabInfo {
        let record = record(id: id)
        return RemoteCodeTabInfo(
            id: id, serverID: serverID, serverName: hostName, directory: newSessionDirectory, slot: nil,
            runs: runs.map { run in
                RemoteCodeTabInfo.Run(session: run.id, tool: run.tool.rawValue, directory: run.directory,
                                      startedAt: run.startedAt, sessionID: run.key?.sessionID, path: run.path,
                                      title: title(of: run), endedAt: run.endedAt)
            },
            selectedRun: record.selectedRun, selectedRecord: record.selectedRecord)
    }
}
