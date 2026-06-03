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

    // MARK: 滚动条仅在有可滚动历史时出现

    /// SwiftTerm 把它的 NSScroller 当作独立子视图常驻挂在右边缘，从不
    /// `isHidden`（见 MacTerminalView.setupScroller / updateScroller），所以
    /// 即便没有任何 scrollback 可滚，也会显示一个静态、禁用的 knob —— 在
    /// 系统「显示滚动条 = 自动」且接了鼠标时尤其明显（渲染成宽的 legacy 条）。
    ///
    /// 这里把它改成 VSCode 那种「仅在有历史可滚时才出现」：
    /// SwiftTerm 在 *每个* updateScroller() 里都会把 `scroller.isEnabled`
    /// 设成 `canScroll`，而 updateScroller() 覆盖了所有触发点（输出滚动 /
    /// 手动滚动 / 主备缓冲切换 / changeScrollback / resize），所以 KVO 盯住
    /// `isEnabled` 是覆盖全部代码路径的唯一可靠信号。
    ///
    /// 只镜像到 `alphaValue`、*不动* `isHidden`：因为 SwiftTerm 的
    /// `reservedScrollerWidth` 是按 `isHidden` 预留终端右侧宽度的，切 isHidden
    /// 会改变可用列数、触发整屏 reflow 抖动（且回收要等到下次 resize 才生效）。
    /// 切 alpha 纯视觉，零 reflow，预留宽度恒定。
    private var scrollerEnabledObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installScrollerAutoHideIfNeeded()
    }

    private func installScrollerAutoHideIfNeeded() {
        guard scrollerEnabledObservation == nil,
              let scroller = subviews.compactMap({ $0 as? NSScroller }).first
        else { return }
        // .initial 立即按当前 isEnabled 同步一次（启动时 canScroll=false → 淡出）。
        scrollerEnabledObservation = scroller.observe(\.isEnabled, options: [.initial, .new]) { scroller, _ in
            // KVO 回调随 SwiftTerm 在主线程改 isEnabled 同步投递（.initial 也在
            // observe() 调用处的主线程同步触发），主线程身份恒定；assumeIsolated
            // 把这一既有假设显式化，满足 Swift 6 对 @Sendable changeHandler 的隔离检查。
            MainActor.assumeIsolated {
                let target: CGFloat = scroller.isEnabled ? 1 : 0
                if scroller.alphaValue != target {
                    scroller.alphaValue = target
                }
            }
        }
    }
}
