import UPaneTree
import Foundation
import SwiftUI

enum WorkspaceCommandPaletteFactory {
    struct Actions {
        let openWelcome: () -> Void
        let openGroups: () -> Void
        let openImport: () -> Void
        let openSettings: () -> Void
    }

    /// 工作区窗口的命令项：主机（连接=当前工作区开新 tab）/ 最近文件 / 命令 / 设置深链。
    @MainActor
    static func items(profiles: [ServerProfile],
                      workspace: WorkspaceModel,
                      actions: Actions) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        // 主机：连接 = 在当前工作区开新 tab
        for p in profiles.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let id = p.id
            let name = p.name.isEmpty ? p.host : p.name
            items.append(CommandPaletteItem(
                id: "host.\(id.uuidString)", kind: .host,
                title: name, detail: "\(p.username)@\(p.host)",
                hint: String(localized: "连接", comment: "命令面板提示：连接到这台主机"), group: p.group) {
                    workspace.openServer(profileID: id, title: name)
                })
        }

        // 文件（最近）：stat 取真实 size/mtime 后走既有 .openRemoteFile 大文件门
        for entry in workspace.filePreviewModel.recents {
            let path = entry.remotePath
            items.append(CommandPaletteItem(
                id: "file.\(path)", kind: .file,
                title: (path as NSString).lastPathComponent, detail: path,
                hint: String(localized: "打开", comment: "命令面板提示：打开这个文件"),
                group: String(localized: "最近", comment: "命令面板二级分组：最近打开的文件")) {
                    let browser = workspace.fileBrowserModel
                    Task { @MainActor in
                        guard let sftp = browser.sftpProvider,
                              let stat = try? await sftp.stat(path) else { return }
                        NotificationCenter.default.post(
                            name: .openRemoteFile, object: nil,
                            userInfo: ["path": path, "size": stat.size, "mtime": stat.mtime])
                    }
                })
        }

        // 命令
        items.append(CommandPaletteItem(
            id: "cmd.splitPane", kind: .command,
            title: String(localized: "向下分屏"), detail: "", hint: "⇧⌘D", group: nil) {
                workspace.splitActiveGroup(direction: .vertical)
            })
        items.append(CommandPaletteItem(
            id: "cmd.closeTab", kind: .command,
            title: String(localized: "关闭当前终端标签页"), detail: "", hint: "⌘W", group: nil) {
                workspace.requestCloseActiveTerminalTab()
            })
        items.append(CommandPaletteItem(
            id: "cmd.newHost", kind: .command,
            title: String(localized: "新建主机…"), detail: String(localized: "在欢迎窗口中新建"),
            hint: "↵", group: nil) {
                actions.openWelcome()
            })

        items.append(CommandPaletteItem(
            id: "cmd.manageGroups", kind: .command,
            title: String(localized: "管理分组…"), detail: String(localized: "新建 / 重命名 / 删除分组"),
            hint: "↵", group: nil) {
                actions.openGroups()
            })

        items.append(CommandPaletteItem(
            id: "cmd.importConfig", kind: .command,
            title: String(localized: "导入 SSH 配置…"), detail: String(localized: "从 ~/.ssh/config 批量导入"),
            hint: "↵", group: nil) {
                actions.openImport()
            })

        // 设置
        items.append(contentsOf: commandPaletteSettingsItems(openSettings: actions.openSettings))
        items.append(contentsOf: commandPaletteAccentItems())
        return items
    }

    /// RemoteHit → 命令项。文件 id 与 recents 同（file.<path>）便于去重；目录 id 用 dir.<path>。
    @MainActor
    static func mapHitToItem(_ hit: RemoteHit, workspace: WorkspaceModel) -> CommandPaletteItem {
        let path = hit.path
        let name = (path as NSString).lastPathComponent
        if hit.isDirectory {
            return CommandPaletteItem(
                id: "dir.\(path)", kind: .file, title: name, detail: path,
                hint: String(localized: "进入", comment: "命令面板提示：进入这个文件夹"),
                group: String(localized: "文件夹", comment: "命令面板二级分组")) {
                    let browser = workspace.fileBrowserModel
                    // 显示左侧文件 sidebar（leftSidebarVisibility 是真实字段；.detailOnly = 隐藏）。
                    // 先显示侧栏给即时反馈，再异步导航（导航完成后列表自然刷新）。
                    workspace.uiState.leftSidebarVisibility = .all
                    Task { @MainActor in await browser.navigate(toPath: path) }
                }
        } else {
            return CommandPaletteItem(
                id: "file.\(path)", kind: .file, title: name, detail: path,
                hint: String(localized: "打开", comment: "命令面板提示：打开这个文件"),
                group: String(localized: "文件", comment: "命令面板二级分组")) {
                    let browser = workspace.fileBrowserModel
                    Task { @MainActor in
                        guard let sftp = browser.sftpProvider,
                              let stat = try? await sftp.stat(path) else { return }
                        NotificationCenter.default.post(
                            name: .openRemoteFile, object: nil,
                            userInfo: ["path": path, "size": stat.size, "mtime": stat.mtime])
                    }
                }
        }
    }
}
