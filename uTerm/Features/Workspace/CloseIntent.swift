import Foundation

/// ⌘W 关闭时，用户键盘焦点所在的内容区。
enum FocusRegion: Equatable {
    case preview    // 文件 / 编辑区
    case terminal   // 终端区
    case unknown    // 无法归类（SFTP 栏 / Agent 栏 / 图片预览 / 无焦点）
}

/// ⌘W 决策结果。
enum CloseIntent: Equatable {
    case closeFileBuffer(UUID)
    case closeTerminalFocusedPane(tabID: UUID)
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
        if let id = ctx.activeTerminalTabID { return .closeTerminalFocusedPane(tabID: id) }
    case .unknown:
        break
    }
    // 回退优先级：文件 → 终端 → 窗口
    if let id = ctx.activeFileBufferID  { return .closeFileBuffer(id) }
    if let id = ctx.activeTerminalTabID { return .closeTerminalFocusedPane(tabID: id) }
    return .closeWindow
}

extension WorkspaceModel {
    /// 从当前工作区状态构造 `CloseContext` 并求 ⌘W 意图。
    func closeIntent(focusedRegion: FocusRegion) -> CloseIntent {
        resolveCloseIntent(CloseContext(
            focusedRegion: focusedRegion,
            activeFileBufferID: filePreviewModel.activeBufferID,
            activeTerminalTabID: activeTab?.id))   // activeTab 非 nil 才有真实活动标签
    }
}
