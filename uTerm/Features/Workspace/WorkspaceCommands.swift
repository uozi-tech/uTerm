import Foundation

/// 全局菜单命令 → 窗口的通知通道。`CommandMenu` 注册在 App 级，
/// 每个 `WorkspaceWindowView` 通过 `.onReceive` 订阅，决定是否响应。
extension Notification.Name {
    /// ⇧⌘D：让当前窗口的活动 tab 对聚焦窗格做垂直分屏（上下，向下）。
    static let splitFocusedPaneVertical = Notification.Name("uterm.splitFocusedPaneVertical")
    /// ⌘D：让当前窗口的活动 tab 对聚焦窗格做水平分屏（左右，向右）。
    static let splitFocusedPaneHorizontal = Notification.Name("uterm.splitFocusedPaneHorizontal")
    /// ⌘⌥1：让当前工作区切换左 sidebar 显隐。
    static let toggleLeftSidebar = Notification.Name("uterm.toggleLeftSidebar")
    /// ⌘⌥2：让当前工作区切换右 inspector 显隐。
    static let toggleRightInspector = Notification.Name("uterm.toggleRightInspector")
    /// ⌘T：在当前工作区新建一个终端标签。
    static let newTerminalTab = Notification.Name("uterm.newTerminalTab")
    /// 左 sidebar 文件 tap：在 PreviewArea 打开。userInfo: path / size / mtime。
    static let openRemoteFile = Notification.Name("uterm.openRemoteFile")
    /// ⌘S：保存 preview buffer。可选 userInfo `SavePreviewBufferKey.bufferID`
    /// 指定要保存的具体 buffer（编辑器聚焦时由本地 keyDown 监听器带入，精确到正在编辑的
    /// buffer）；缺省时回落到窗口的 activeBufferID（菜单项点击 / 非编辑器聚焦）。
    static let savePreviewBuffer = Notification.Name("uterm.savePreviewBuffer")
}

/// `.savePreviewBuffer` 通知的 userInfo 键。
enum SavePreviewBufferKey {
    /// 值类型 `UUID`：要保存的 FileBuffer id。
    static let bufferID = "bufferID"
}
