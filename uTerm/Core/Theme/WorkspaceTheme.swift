import UDesignKit
import SwiftUI
import AppKit

/// 工作区窗口的**钉色 NSColor**。视图层配色已统一走 DesignKit `UD` token（深 / 浅
/// 动态）；这里只剩 AppKit 层窗口去玻璃 / 不透明底所需的 `NSColor`（SwiftUI `Color`
/// 不便直接给 `window.backgroundColor` / `layer.backgroundColor`），与
/// `UD.bg`/`UD.panel` 同值，随外观深/浅动态解析。
///
/// 标 `nonisolated` 让常量能在任意上下文读取；`NSColor` 常量跨线程安全。
enum WS {
    /// `UD.bg` 的 NSColor 版（深 #101012 / 浅 #FFFFFF）—— 窗口不透明底色 / AppKit 去玻璃用。
    nonisolated static let bgNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 16/255, green: 16/255, blue: 18/255, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }
    /// `UD.panel` 的 NSColor 版（深 #17171A / 浅 #FFFFFF）—— 标题栏拖动手柄实色底。
    /// 日间与 `bgNSColor` 同值（全部统一纯白 = UDInput 的白）：标题栏 chrome 与窗口底无缝。
    nonisolated static let panelNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 23/255, green: 23/255, blue: 26/255, alpha: 1)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    }
}

/// 把宿主 `NSWindow` 去玻璃 + 不透明底色，但**不改标题栏样式**，外观跟随全局设置
///（`NSApp.appearance`，由 `AppAppearanceSync` 驱动） —— 给保留系统窗口 chrome 的
/// 窗口用（如新建服务器表单 `ServerFormView`、密钥管理窗口）。工作区主窗口用更激进
/// 的 `WorkspaceWindowChrome`（透明标题栏 + full-size content）。
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
            window.appearance = nil   // 跟随 NSApp.appearance（密钥管理 / 新建服务器表单也随主题）
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

/// 设计稿 workspace 标题栏里的连接状态胶囊：圆点（连接中 / 已连接时呼吸）+ 文案，
/// 外裹语义色 14% 胶囊底（`idle` 用中性 `uw03`）。
///
/// 曾经直接用 DesignKit 的 `UDStatusBadge`，但它的呼吸光晕是 SwiftUI
/// `.repeatForever`——会把整个窗口钉在每帧重绘上（详见 `PulseDot` 的注释：实测空载
/// 30%+ CPU）。这里按同一套视觉参数就地复刻，光晕换成 CA 驱动的 `PulseDot`。
/// 色调与文案继续走 `ConnectionStatusDisplay`（已有单测），与 `UDStatusBadge`
/// 的映射逐项等价。
struct WSStatusPill: View {
    let state: TerminalSession.ConnectionState

    var body: some View {
        let display = ConnectionStatusDisplay(state: state)
        return HStack(spacing: UD.Space.xs) {
            PulseDot(
                color: display.tint.color,
                coreSize: 7,
                haloSize: 9,
                // 原 UDStatusBadge 是两层 opacity 相乘：0.2 × 0.2。
                peakOpacity: 0.04,
                pulse: pulses
            )
            Text(display.label)
                .font(UD.caption)
                .foregroundStyle(isIdle ? UD.text2 : display.tint.color)
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(isIdle ? UD.uw03 : display.tint.color.opacity(0.14)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("连接状态")
        .accessibilityValue(display.label)
    }

    /// 只有「已连接 / 连接中」呼吸，与 `UDStatusBadge.State.pulse` 一致。
    private var pulses: Bool {
        switch state {
        case .connected, .connecting:       return true
        case .idle, .disconnected, .failed: return false
        }
    }

    private var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }
}
