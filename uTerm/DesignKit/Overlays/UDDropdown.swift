import SwiftUI
import AppKit

/// DesignKit 下拉触发器：自绘触发按钮 + 贴在其下方的 `UDMenu` 浮层 —— 替代原生 SwiftUI
/// `Menu`（后者渲染系统样式、无法套用 DesignKit）。交互：点触发器展开 / 点选项后关 /
/// 点击任意外部关 / ESC 关。
///
/// 用法：
/// ```
/// UDDropdown(anchor: .leading) { open in
///     triggerLabel(open: open)          // 自绘胶囊 / 带 chevron
/// } content: {
///     UDMenu(width: 184, head: "模型", items: [...带 action...])
/// }
/// ```
struct UDDropdown<Trigger: View, Content: View>: View {
    /// 浮层与触发器对齐的边（左对齐 / 右对齐）。
    enum Anchor { case leading, trailing }

    var anchor: Anchor = .leading
    /// 浮层与触发器之间的竖向间隙。
    var gap: CGFloat = 6
    /// 触发器（参数 = 当前是否展开，便于旋转 chevron）。
    @ViewBuilder var trigger: (Bool) -> Trigger
    /// 浮层内容（通常是 `UDMenu`，其选项 `action` 自带业务动作；关闭由本组件统一处理）。
    @ViewBuilder var content: () -> Content

    @State private var open = false
    @State private var triggerHeight: CGFloat = 28
    /// 刚被「点击外部 / 再点触发器」关闭的时刻 —— 用于去抖，避免「关闭那一下」又把它重开。
    @State private var lastClosedAt: Date?

    var body: some View {
        trigger(open)
            .contentShape(Rectangle())
            .onTapGesture {
                // 若刚被 dismiss 监听关掉（同一次点击），吞掉这次「重开」。
                if let t = lastClosedAt, Date().timeIntervalSince(t) < 0.25 {
                    lastClosedAt = nil
                    return
                }
                open = true
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { triggerHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in triggerHeight = h }
                }
            )
            .overlay(alignment: anchor == .leading ? .topLeading : .topTrailing) {
                if open {
                    content()
                        .fixedSize()
                        .offset(y: triggerHeight + gap)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
            .background(UDDropdownDismiss(isOpen: open) {
                open = false
                lastClosedAt = Date()
            })
            .zIndex(open ? 100 : 0)
            .animation(.easeOut(duration: 0.1), value: open)
    }
}

/// 下拉关闭监听：展开时装一个本地事件监听，鼠标按下任意处或按 ESC 即关。
/// 选项点击：监听只 `onDismiss()` 并**放行**事件（不消费）→ 选项的 `Button` 仍会触发其
/// 业务动作，随后下一轮渲染收起浮层。结构对齐 `WorkspaceCloseShortcutInstaller`（本地监听，
/// handler 即主线程上下文）。
private struct UDDropdownDismiss: NSViewRepresentable {
    let isOpen: Bool
    let onDismiss: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView { MonitorView(onDismiss) }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        view.onDismiss = onDismiss
        view.setActive(isOpen)
    }

    final class MonitorView: NSView {
        var onDismiss: @MainActor () -> Void
        // 只在主线程读写；让 deinit / viewDidMoveToWindow 都能安全 removeMonitor。
        private nonisolated(unsafe) var monitor: Any?

        init(_ cb: @escaping @MainActor () -> Void) {
            self.onDismiss = cb
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func setActive(_ active: Bool) {
            if active { install() } else { removeMonitor() }
        }

        private func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .keyDown]
            ) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    guard event.keyCode == 53 else { return event }   // ESC
                    self.onDismiss()
                    return nil
                }
                // 鼠标按下：收起浮层并放行 —— 选项 Button 仍会收到这次点击触发动作。
                self.onDismiss()
                return event
            }
        }

        // nonisolated：只碰 nonisolated(unsafe) 的 monitor 与线程安全的 NSEvent.removeMonitor，
        // 故可从 nonisolated 的 deinit 调用（module 默认 @MainActor 隔离下否则会告警）。
        private nonisolated func removeMonitor() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { removeMonitor() }
        }

        deinit { removeMonitor() }
    }
}
