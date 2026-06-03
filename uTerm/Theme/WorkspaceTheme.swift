import SwiftUI
import AppKit

/// 工作区窗口的**钉色 NSColor**。视图层配色已统一走 DesignKit `UD` token（深 / 浅
/// 动态，工作区被 `WorkspaceWindowAppearance` 钉死 `.darkAqua` 故恒解析为深色值）；
/// 这里只剩 AppKit 层窗口去玻璃 / 不透明底所需的 `NSColor`（SwiftUI `Color` 不便直接给
/// `window.backgroundColor` / `layer.backgroundColor`），与 `UD.bg`/`UD.panel` 同值。
///
/// 标 `nonisolated` 让常量能在任意上下文读取；`NSColor` 常量跨线程安全。
enum WS {
    /// `UD.bg`(#101012) 的 NSColor 版 —— 窗口不透明底色 / AppKit 去玻璃用。
    nonisolated static let bgNSColor  = NSColor(srgbRed: 16/255, green: 16/255, blue: 18/255, alpha: 1)
    /// `UD.panel`(#17171A) 的 NSColor 版 —— 标题栏拖动手柄 `WindowDragHandle` 的实色底。
    nonisolated static let panelNSColor = NSColor(srgbRed: 23/255, green: 23/255, blue: 26/255, alpha: 1)
}

/// 把宿主 `NSWindow` 钉成扁平深色 + 去玻璃，但**不改标题栏样式** —— 给保留系统
/// 窗口 chrome 的深色窗口用（如新建服务器表单 `ServerFormView`）。工作区主窗口
/// 用更激进的 `WorkspaceWindowChrome`（透明标题栏 + full-size content）。
struct WorkspaceWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PinView() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? PinView)?.apply() }

    private final class PinView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                MainActor.assumeIsolated { self?.apply() }
            }
        }
        func apply() {
            guard let window else { return }
            window.appearance = NSAppearance(named: .darkAqua)
            window.isOpaque = true
            window.backgroundColor = WS.bgNSColor
            var root: NSView? = window.contentView
            while let parent = root?.superview { root = parent }
            if let root { Self.deglass(root) }
        }
        private static func deglass(_ view: NSView) {
            if let effect = view as? NSVisualEffectView {
                effect.blendingMode = .withinWindow
                effect.state = .inactive
                effect.material = .windowBackground
            }
            for sub in view.subviews { deglass(sub) }
        }
    }
}

/// 设计稿 workspace 标题栏里的连接状态胶囊。app-bound 适配器：把
/// `TerminalSession.ConnectionState` 映射到 DesignKit `UDStatusBadge`（含呼吸光晕）。
struct WSStatusPill: View {
    let state: TerminalSession.ConnectionState

    var body: some View {
        UDStatusBadge(state: badgeState)
    }

    private var badgeState: UDStatusBadge.State {
        switch state {
        case .idle:         return .idle
        case .connecting:   return .connecting
        case .connected:    return .connected
        case .disconnected: return .disconnected
        case .failed:       return .failed
        }
    }
}
