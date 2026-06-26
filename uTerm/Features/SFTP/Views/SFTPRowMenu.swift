import SwiftUI
import AppKit

/// 右键菜单行为集合：独立 SFTP 窗口与工作区侧栏共用同一套 `SFTPRowMenu`，靠这个
/// 结构注入两处差异。可选闭包为 nil 时对应菜单项自动隐藏（例：侧栏无检视器 →
/// `onShowInfo == nil` → 不显示「显示简介」；侧栏文件项 → `onDownload != nil` 才显
/// 示「下载…」）。
struct SFTPRowActions {
    /// 当前所在目录的绝对路径——「拷贝路径」据此拼完整路径 / 父目录。
    var currentPath: String
    /// 文件项主操作的文案 / 图标（独立窗口主操作 =「下载」；侧栏 =「预览」）。
    var fileActionLabel: String = "下载"
    var fileActionIcon: String = "arrow.down.circle"

    /// 进入目录 / 打开文件（独立窗口下载、侧栏预览，由调用方实现）。
    var onActivate: (RemoteEntry) -> Void
    /// 在工作区打开（独立窗口专属；nil 隐藏）。
    var onOpenWorkspace: (() -> Void)? = nil
    /// 文件单独「下载…」项（侧栏专属——侧栏主操作是预览，下载另起一项；nil 隐藏）。
    var onDownload: ((RemoteEntry) -> Void)? = nil
    /// 显示简介（选中并确保检视器可见；侧栏无检视器 → nil 隐藏）。
    var onShowInfo: ((RemoteEntry) -> Void)? = nil
    var onRename: (RemoteEntry) -> Void
    var onPermissions: (RemoteEntry) -> Void
    var onDelete: (RemoteEntry) -> Void
}

/// 文件 / 文件夹右键菜单内容（对齐设计稿 `pages/file-ops.jsx` 的 `FileContextMenu`）。
/// 用法：`.contextMenu { SFTPRowMenu(entry: e, actions: actions) }`。
///
/// 分四组（组间分隔线）：① 打开（进入/下载/预览 · 在工作区打开）② 编辑（显示简介 ·
/// 重命名 · 权限设置）③ 剪贴板（拷贝名称 · 拷贝路径▸）④ 删除（destructive）。目录 /
/// 文件项差异化。拷贝直接写 `NSPasteboard`（纯 UI 行为，内聚在此，不外溢到 model）。
struct SFTPRowMenu: View {
    let entry: RemoteEntry
    let actions: SFTPRowActions

    var body: some View {
        // ① 打开
        Button {
            actions.onActivate(entry)
        } label: {
            if entry.isDirectory {
                Label("进入", systemImage: "arrow.right.circle")
            } else {
                Label(actions.fileActionLabel, systemImage: actions.fileActionIcon)
            }
        }
        if let onOpenWorkspace = actions.onOpenWorkspace {
            Button { onOpenWorkspace() } label: { Label("在工作区打开", systemImage: "terminal") }
        }
        if let onDownload = actions.onDownload, !entry.isDirectory {
            Button { onDownload(entry) } label: { Label("下载…", systemImage: "arrow.down.circle") }
        }

        Divider()

        // ② 编辑
        if let onShowInfo = actions.onShowInfo {
            Button { onShowInfo(entry) } label: { Label("显示简介", systemImage: "info.circle") }
        }
        Button { actions.onRename(entry) } label: { Label("重命名", systemImage: "pencil") }
        Button { actions.onPermissions(entry) } label: { Label("权限设置…", systemImage: "lock") }

        Divider()

        // ③ 剪贴板
        Button { Self.copy(entry.name) } label: { Label("拷贝名称", systemImage: "doc.on.clipboard") }
        Menu {
            Button("完整路径") { Self.copy(FileBrowserModel.join(actions.currentPath, entry.name)) }
            Button("父目录") { Self.copy(actions.currentPath) }
        } label: {
            Label("拷贝路径", systemImage: "doc.on.doc")
        }

        Divider()

        // ④ 删除
        Button(role: .destructive) { actions.onDelete(entry) } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 文件列表空白处的右键菜单：在当前目录新建文件夹 / 新建文件。独立 SFTP 窗口与
/// 工作区侧栏共用。用法：`.contextMenu { SFTPBackgroundMenu(onNewFolder:onNewFile:) }`。
struct SFTPBackgroundMenu: View {
    let onNewFolder: () -> Void
    let onNewFile: () -> Void

    var body: some View {
        Button { onNewFolder() } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
        Button { onNewFile() } label: { Label("新建文件", systemImage: "doc.badge.plus") }
    }
}
