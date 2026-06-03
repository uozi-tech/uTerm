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

    // MARK: 滚动条仅在滚动时浮现（native overlay 手感）

    /// SwiftTerm 把它的 NSScroller 当作独立子视图常驻挂在右边缘，从不
    /// `isHidden`（见 MacTerminalView.setupScroller / updateScroller），且
    /// `scrollerStyle` 默认就是 `.overlay`。只要有 scrollback 可滚（甚至系统
    /// 「显示滚动条 = 自动/接鼠标」下），这个 knob 就一直停在右边 —— 也就是
    /// 用户抱怨的「常驻滚动条」。
    ///
    /// 这里把它改成真正的 overlay 手感：**静默时完全隐藏**（alpha 0），仅在
    /// 用户滚动（滚轮/触控板）且确有历史可滚时短暂淡入，停手约 1s 后自动淡出。
    /// 关键是把「可见」从 `canScroll`（有没有历史）解耦到「正在滚动」这个用户
    /// 动作上 —— 有历史但没在滚，照样隐藏。
    ///
    /// 只动 `alphaValue`、*不动* `isHidden`：SwiftTerm 的 `reservedScrollerWidth`
    /// 按 `isHidden` 预留终端右侧宽度，切 isHidden 会改变可用列数、触发整屏
    /// reflow 抖动。切 alpha 纯视觉、零 reflow、预留宽度恒定；且 alpha 控制凌驾
    /// 于系统「显示滚动条」设置之上，Always/Auto 都一致隐藏。
    private weak var managedScroller: NSScroller?

    /// `.scrollWheel` 本地事件监听。SwiftTerm 把 `scrollWheel` 声明成 `public`
    /// （非 `open`），子类无法 override，所以改为监听全局滚动事件、再用命中测试
    /// 判断是否落在本终端上，以此驱动「滚动时才浮现」。`nonisolated(unsafe)` 让
    /// nonisolated 的 deinit 能释放它（与 TerminalHostView.scrollForwardingMonitor
    /// 同构：仅在 view 存活期间于 MainActor 改动，deinit 运行时独占访问）。
    private nonisolated(unsafe) var scrollActivityMonitor: Any?

    /// 停止滚动后多久淡出。
    private let scrollerIdleHideDelay: TimeInterval = 1.0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installManagedScrollerIfNeeded()
        updateScrollActivityMonitor()
    }

    deinit {
        removeScrollActivityMonitor()
    }

    private func installManagedScrollerIfNeeded() {
        guard managedScroller == nil,
              let scroller = subviews.compactMap({ $0 as? NSScroller }).first
        else { return }
        managedScroller = scroller
        // overlay 细条 + 暗终端用浅色 knob（.dark 是给浅背景的深色 knob，会糊在暗底上）。
        scroller.scrollerStyle = .overlay
        scroller.knobStyle = .light
        // 静默初值：隐藏。仅滚动时由 handleScrollActivity() 淡入。
        scroller.alphaValue = 0
    }

    private func updateScrollActivityMonitor() {
        if window != nil {
            guard scrollActivityMonitor == nil else { return }
            scrollActivityMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollActivity(event)
                return event
            }
        } else {
            removeScrollActivityMonitor()
        }
    }

    /// `nonisolated`：只碰 `nonisolated(unsafe)` 的 monitor 句柄，
    /// `NSEvent.removeMonitor` 任意线程可调，好让 deinit 直接调用（与
    /// TerminalHostView.removeScrollForwardingMonitor 同构）。
    private nonisolated func removeScrollActivityMonitor() {
        if let scrollActivityMonitor {
            NSEvent.removeMonitor(scrollActivityMonitor)
            self.scrollActivityMonitor = nil
        }
    }

    /// 滚动事件命中本终端时淡入 scroller，并 debounce 安排淡出。仅当确有历史
    /// 可滚（`scroller.isEnabled == canScroll`）才淡入 —— 没历史就不闪出来。
    private func handleScrollActivity(_ event: NSEvent) {
        guard let scroller = managedScroller,
              event.window === window,
              scroller.isEnabled
        else { return }
        // 命中测试：滚动确实发生在本 pane 区域内（多 pane 时别误亮别人的条）。
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }

        if scroller.alphaValue != 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                scroller.animator().alphaValue = 1
            }
        }
        // debounce：每来一次滚动就取消上一笔待执行的淡出、重新计时；停手
        // scrollerIdleHideDelay 后才真正淡出。perform/cancelPrevious 跑在主
        // run loop，规避 Swift 6 下 Timer/DispatchWorkItem @Sendable 闭包捕获
        // non-Sendable self/NSScroller 的隔离检查。
        NSObject.cancelPreviousPerformRequests(withTarget: self,
                                               selector: #selector(fadeOutScroller),
                                               object: nil)
        perform(#selector(fadeOutScroller), with: nil, afterDelay: scrollerIdleHideDelay)
    }

    @objc private func fadeOutScroller() {
        guard let scroller = managedScroller else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            scroller.animator().alphaValue = 0
        }
    }
}
