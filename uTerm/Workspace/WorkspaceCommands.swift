import Foundation

/// 全局菜单命令 → 窗口的通知通道。`CommandMenu` 注册在 App 级，
/// 每个 `WorkspaceWindowView` 通过 `.onReceive` 订阅，决定是否响应。
extension Notification.Name {
    /// ⇧⌘D：让当前窗口的活动 tab 对聚焦窗格做垂直分屏。
    static let splitFocusedPaneVertical = Notification.Name("uterm.splitFocusedPaneVertical")
}
