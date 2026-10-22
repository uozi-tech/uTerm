import SwiftUI
import AppKit

/// 右键菜单行为集合：独立 SFTP 窗口与工作区侧栏共用同一套 `SFTPRowMenu`，靠这个
/// 结构注入两处差异。可选闭包为 nil 时对应菜单项自动隐藏（例：独立窗口没有编辑器 →
/// `onPreview == nil` → 不显示「预览」；侧栏无检视器 → 不显示「显示简介」）。
///
/// 文件动作的叫法 / 图标 / 顺序统一取 `RemoteFileAction`：预览 · 打开 · 打开方式 ▸ · 下载…
struct SFTPRowActions {
    /// 当前所在目录的绝对路径——「拷贝路径」据此拼完整路径 / 父目录。
    var currentPath: String

    /// 双击 / 回车：目录 = 进入；文件 = 所在窗口的主动作（工作区 = 预览，独立窗口 = 打开）。
    var onActivate: (RemoteEntry) -> Void
    /// 在工作区打开（独立窗口专属；nil 隐藏）。
    var onOpenWorkspace: (() -> Void)? = nil
    /// 预览：内置编辑器（只有工作区有；nil 隐藏）。
    var onPreview: ((RemoteEntry) -> Void)? = nil
    /// 打开 / 打开方式 ▸：本机应用打开、保存自动回传（nil 隐藏两项）。
    var onOpen: ((RemoteEntry, ExternalOpenCoordinator.Route) -> Void)? = nil
    /// 下载…：另存到本地（nil 隐藏）。
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
/// 分四组（组间分隔线）：① 打开（文件：预览 · 打开 · 打开方式 ▸ · 下载…；目录：进入 ·
/// 在工作区打开）② 编辑（显示简介 · 重命名 · 权限设置）③ 剪贴板（拷贝名称 · 拷贝路径▸）
/// ④ 删除（destructive）。拷贝直接写 `NSPasteboard`（纯 UI 行为，内聚在此，不外溢到 model）。
struct SFTPRowMenu: View {
    let entry: RemoteEntry
    let actions: SFTPRowActions

    var body: some View {
        // ① 打开
        if entry.isDirectory {
            Button {
                actions.onActivate(entry)
            } label: {
                Label("进入", systemImage: "arrow.right.circle")
            }
        } else {
            fileActions
        }
        if let onOpenWorkspace = actions.onOpenWorkspace {
            Button { onOpenWorkspace() } label: { Label("在工作区打开", systemImage: "terminal") }
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

    @ViewBuilder
    private var fileActions: some View {
        if let onPreview = actions.onPreview {
            Button { onPreview(entry) } label: { Self.label(.preview) }
        }
        if let onOpen = actions.onOpen {
            Button { onOpen(entry, .preferred) } label: { Self.label(.open) }
            OpenWithMenu(path: entry.name) { onOpen(entry, $0) }
        }
        if let onDownload = actions.onDownload {
            Button { onDownload(entry) } label: { Self.label(.download) }
        }
    }

    private static func label(_ action: RemoteFileAction) -> some View {
        Label(action.title, systemImage: action.systemImage)
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
