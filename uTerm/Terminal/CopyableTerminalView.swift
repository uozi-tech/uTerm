import SwiftTerm
import AppKit

/// SwiftTerm.TerminalView 的 uTerm 子类。
///
/// 职责：
/// 1. 获取第一响应者身份（override mouseDown / rightMouseDown）
/// 2. Copy-on-select：跟踪 mouseDown -> mouseDragged -> mouseUp 序列，
///    在确认有有效选择（drag 拖动 OR clickCount>=2 双/三击）后调
///    super.copy(self) 触发 SwiftTerm 内部把 selection 写剪贴板。
///
/// 不在 selectionChanged(source:) 里 copy：那个回调在 selection 清空
/// （active=false）时也触发，会清空用户剪贴板。基于 mouse 事件序列
/// 更可靠且与用户的"选中即复制"语义一致。
final class CopyableTerminalView: SwiftTerm.TerminalView {

    /// 是否在选中后自动把内容写入剪贴板。由 TerminalHostView 据
    /// @AppStorage("terminalCopyOnSelect") 同步更新。
    var copyOnSelect: Bool = false

    // MARK: 选中状态跟踪

    /// mouseDown 的窗口坐标 - mouseUp 时用于确认本次 mouse 序列确实始于当前 view。
    private var mouseDownLocation: NSPoint?

    /// mouseDown 时是否已发生 mouseDragged - mouseUp 时用于判定是否拖动选择。
    private var didDragSinceMouseDown: Bool = false

    // MARK: NSResponder overrides

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        mouseDownLocation = event.locationInWindow
        didDragSinceMouseDown = false
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        super.rightMouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        didDragSinceMouseDown = true
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let hadMouseDown = mouseDownLocation != nil
        mouseDownLocation = nil
        defer { didDragSinceMouseDown = false }
        guard copyOnSelect else { return }
        guard hadMouseDown else { return }
        // 仅当事件序列暗示有有效选中时才调 copy(self)，避免清空剪贴板：
        // - didDragSinceMouseDown: 拖动 drag-selection 范围
        // - event.clickCount >= 2: 双击选词 / 三击选行
        if didDragSinceMouseDown || event.clickCount >= 2 {
            // super.copy(self) 由 SwiftTerm 内部读 selection.getSelectedText()
            // 写 NSPasteboard.general（包含 clearContents）。
            super.copy(self)
        }
    }
}
