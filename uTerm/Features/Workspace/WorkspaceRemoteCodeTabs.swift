import Foundation
import UPaneGroups

extension WorkspaceModel {
    /// 这个窗口里 SSH 主机的 Code 标签页，按窗口里的标签先后（远控 63 号消息，见 `TerminalSessionRegistry.codeTabs()`）：
    /// `serverID` 是那台主机（`ServerProfile.id`），`serverName` 是它的名字。标签页的 id 用存进布局的那个（`PaneModel.id`，
    /// 同 `layoutTabID`、`codeTabRecords()`），重启后不变。在观察里读会跟踪到标签树、每个 Code 标签页里的会话、它们的标题与状态。
    func remoteCodeTabs() -> [TerminalSessionRegistry.CodeTabPublication] {
        let codeTabs = terminalGroups.allTabs.compactMap { tab in tab.payload.codeTab.map { (pane: tab.payload, code: $0) } }
        guard !codeTabs.isEmpty else { return [] }
        let codeIDs = Set(codeTabs.map(\.pane.id))
        let order = terminalGroups.snapshot(Self.layoutTabID).tabOrder
        return order.compactMap { id in
            guard let tab = codeTabs.first(where: { $0.pane.id == id }) else { return nil }
            // 排在它前面的终端标签（Code 标签页不是会话，不占位置；文件标签不在这份顺序里）。
            let preceding = order.prefix { $0 != id }.filter { !codeIDs.contains($0) }
            return .init(info: tab.code.remoteInfo(id: id, serverID: tab.pane.serverProfileID), precedingSessions: preceding)
        }
    }
}
