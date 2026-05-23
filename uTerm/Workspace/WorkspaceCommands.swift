import Foundation

/// 全局菜单命令 → 窗口的通知通道。`CommandMenu` 注册在 App 级，
/// 每个 `WorkspaceWindowView` 通过 `.onReceive` 订阅，决定是否响应。
extension Notification.Name {
    /// ⇧⌘D：让当前窗口的活动 tab 对聚焦窗格做垂直分屏。
    static let splitFocusedPaneVertical = Notification.Name("uterm.splitFocusedPaneVertical")
    /// ⌘⌥1：让当前工作区切换左 sidebar 显隐。
    static let toggleLeftSidebar = Notification.Name("uterm.toggleLeftSidebar")
    /// ⌘⌥2：让当前工作区切换右 inspector 显隐。
    static let toggleRightInspector = Notification.Name("uterm.toggleRightInspector")
    /// ⌘T：在当前工作区新建一个终端标签。
    static let newTerminalTab = Notification.Name("uterm.newTerminalTab")
}
