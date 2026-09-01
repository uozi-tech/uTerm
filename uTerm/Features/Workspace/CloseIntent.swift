import Foundation
import UPaneGroups

/// ⌘W 关闭时，用户键盘焦点所在的内容区。
enum FocusRegion: Equatable {
    case preview    // 文件 / 编辑区
    case terminal   // 终端区
    case unknown    // 无法归类（SFTP 栏 / Agent 栏 / 图片预览 / 无焦点）
}

/// ⌘W 决策结果。
enum CloseIntent: Equatable {
    case closeFileBuffer(UUID)
    /// 关终端区**活动组的前台标签**；组因此空掉就从分屏树里塌缩。
    /// 旧名 `closeTerminalFocusedPane` —— 那时是「关活动标签的聚焦窗格，
    /// 最后一个窗格再关掉整个标签」，窗口级标签这个层次现在没有了。
    case closeTerminalActiveTab(tabID: UUID)
    case closeWindow
}

/// `resolveCloseIntent` 的纯输入快照（不依赖 SFTP / NSWindow，便于单测）。
struct CloseContext {
    var focusedRegion: FocusRegion
    var activeFileBufferID: UUID?
    var activeTerminalTabID: UUID?
}

/// 纯函数：焦点区有对应内容就关它；否则按「文件 → 终端 → 窗口」回退。
nonisolated func resolveCloseIntent(_ ctx: CloseContext) -> CloseIntent {
    switch ctx.focusedRegion {
    case .preview:
        if let id = ctx.activeFileBufferID { return .closeFileBuffer(id) }
    case .terminal:
        if let id = ctx.activeTerminalTabID { return .closeTerminalActiveTab(tabID: id) }
    case .unknown:
        break
    }
    // 回退优先级：文件 → 终端 → 窗口
    if let id = ctx.activeFileBufferID  { return .closeFileBuffer(id) }
    if let id = ctx.activeTerminalTabID { return .closeTerminalActiveTab(tabID: id) }
    return .closeWindow
}

extension WorkspaceModel {
    /// 从当前工作区状态构造 `CloseContext` 并求 ⌘W 意图。
    func closeIntent(focusedRegion: FocusRegion) -> CloseIntent {
        resolveCloseIntent(CloseContext(
            focusedRegion: focusedRegion,
            activeFileBufferID: filePreviewModel.activeBufferID,
            activeTerminalTabID: terminalCloseTargetID))
    }

    /// ⌘W 在终端区有没有东西可关：活动组的前台标签；活动组是空的（分屏开出来还
    /// 没放东西）但树里还有别的组时，可关的是那个**空组**本身 —— 用组 id 顶上，
    /// `closeActiveTerminalTab()` 会把它收掉。都没有则 nil，回落到关窗口。
    private var terminalCloseTargetID: UUID? {
        if let id = terminalGroups.activeTab?.id { return id }
        guard terminalGroups.groupCount > 1 else { return nil }
        return terminalGroups.activeGroupID
    }
}
