import SwiftUI
import AppKit

extension NSUserInterfaceItemIdentifier {
    /// 终端容器视图标记；⌘W 焦点判定用（见 `WorkspaceCloseShortcut.focusRegion`）。
    static let utermTerminalRegion = NSUserInterfaceItemIdentifier("uterm.region.terminal")
    /// 编辑器 / 预览容器视图标记。
    static let utermPreviewRegion  = NSUserInterfaceItemIdentifier("uterm.region.preview")
}

enum WorkspaceCloseShortcut {
    /// 沿 firstResponder 的 superview 链找带标记的容器，归类焦点区。纯遍历，便于单测。
    static func focusRegion(forFirstResponder fr: NSView?) -> FocusRegion {
        var v = fr
        while let cur = v {
            if cur.identifier == .utermTerminalRegion { return .terminal }
            if cur.identifier == .utermPreviewRegion  { return .preview }
            v = cur.superview
        }
        return .unknown
    }

    static func focusRegion(in window: NSWindow) -> FocusRegion {
        focusRegion(forFirstResponder: window.firstResponder as? NSView)
    }
}

/// 在工作区窗口装一个 ⌘W 的本地 keyDown monitor：命中即消费（`return nil`），把关闭决策交给上层闭包。
/// 与编辑器 find monitor / 终端 scroll monitor 同套路（`NSEvent.addLocalMonitorForEvents`）。
struct WorkspaceCloseShortcutInstaller: NSViewRepresentable {
    let onCloseShortcut: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { MonitorView(onCloseShortcut) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.onCloseShortcut = onCloseShortcut
    }

    final class MonitorView: NSView {
        var onCloseShortcut: @MainActor (NSWindow) -> Void
        // `nonisolated(unsafe)`：只在主线程读写；让 deinit / viewDidMoveToWindow 都能安全 removeMonitor
        // （与 CopyableTerminalView.removeScrollActivityMonitor 同构）。
        private nonisolated(unsafe) var monitor: Any?

        init(_ cb: @escaping @MainActor (NSWindow) -> Void) {
            self.onCloseShortcut = cb
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // 直接在 handler 内访问 NSView 状态（与 CodeEditorView find monitor 同款，handler 即主线程上下文）。
                    // 不用 MainActor.assumeIsolated 包裹——那会把非 Sendable 的 NSEvent 捕获进
                    // @MainActor 嵌套闭包，Swift 6 严格并发下报 “conformance of 'NSEvent' to 'Sendable' is unavailable”。
                    guard let self, let win = self.window,
                          event.window === win,                                     // 只让本窗口（key window）响应
                          event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers == "w"                  // 纯 ⌘W；⇧⌘W 等放行
                    else { return event }
                    let cb = self.onCloseShortcut
                    // 不在事件分发栈内弹模态 / performClose —— 下一拍执行（避免重入）。
                    Task { @MainActor in cb(win) }
                    return nil                                                      // 消费：工作区窗口完全接管 ⌘W
                }
            } else {
                removeMonitor()
            }
        }

        private nonisolated func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { removeMonitor() }   // 与 add 配对，防 monitor 泄漏
    }
}
