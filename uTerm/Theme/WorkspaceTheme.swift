import SwiftUI
import AppKit

/// 工作区专属深色调色板 —— 设计稿「星空之上」（Claude Design 交付包
/// `u-window.jsx` 里的 `U`）。**硬编码深色**，不随系统外观（浅 / 深 / 跟随
/// 系统）变化，与 app 全局 `AppTheme.Palette`（系统语义色）相互独立。
///
/// 只在**工作区窗口**视图树内使用 —— 工作区被 `WorkspaceWindowAppearance`
/// 钉死为 `.darkAqua`，故这里的实色无论用户全局选了什么外观都成立。欢迎页 /
/// 设置仍走 `AppTheme.Palette`，不受影响。
///
/// 标 `nonisolated` 让 token 能在任意上下文读取；`Color` 是 `Sendable`。
enum WS {
    // 背景层 —— 自上而下逐层加深；terminal 是最深的代码 / 终端正文底色。
    nonisolated static let bg         = Color(hex: 0x101012)
    nonisolated static let panel      = Color(hex: 0x17171A)
    nonisolated static let panelHi    = Color(hex: 0x1C1C20)
    nonisolated static let panelHover = Color(hex: 0x202026)
    nonisolated static let terminal   = Color(hex: 0x08080A)
    /// `bg` 的 NSColor 版 —— 窗口不透明底色 / AppKit 去玻璃用（0x101012）。
    nonisolated static let bgNSColor  = NSColor(srgbRed: 16/255, green: 16/255, blue: 18/255, alpha: 1)
    /// `panel` 的 NSColor 版 —— 标题栏拖动手柄 `WindowDragHandle` 的实色底（0x17171A）。
    nonisolated static let panelNSColor = NSColor(srgbRed: 23/255, green: 23/255, blue: 26/255, alpha: 1)

    // 描边 —— 白色低 alpha，叠在任意深色面上都是一道发亮的细线。
    nonisolated static let border     = Color.white.opacity(0.09)
    nonisolated static let borderHi   = Color.white.opacity(0.12)

    // 文本 —— 主 / 次 / 三 / 四级。
    nonisolated static let text       = Color(hex: 0xEDEDEE)
    nonisolated static let text2      = Color.white.opacity(0.58)
    nonisolated static let text3      = Color.white.opacity(0.40)
    nonisolated static let text4      = Color.white.opacity(0.30)

    // 强调（设计稿固定蓝，不跟随系统强调色）。
    nonisolated static let accent     = Color(hex: 0x3B82F6)

    // hover / 选中行底 —— 设计稿 `.u-row` 的白色微 alpha。
    nonisolated static let rowHover    = Color.white.opacity(0.025)
    nonisolated static let rowSelected = Color.white.opacity(0.055)

    // 连接状态色（设计稿 workspace StatusBadge）。
    nonisolated static let connected    = Color(hex: 0x73C991)
    nonisolated static let connecting   = Color(hex: 0xE2C08D)
    nonisolated static let disconnected = Color(hex: 0xCC6633)
    nonisolated static let failed       = Color(hex: 0xF14C4C)

    // 状态栏（Telemetry 风）逐指标语义色。
    nonisolated static let mPlatform = Color(hex: 0x7CC7FF)
    nonisolated static let mEndpoint = Color(hex: 0x9AA7B5)   // endpoint / 时间戳共用
    nonisolated static let mUptime   = Color(hex: 0x34D399)
    nonisolated static let mLoad     = Color(hex: 0xFB7185)
    nonisolated static let mCPU      = Color(hex: 0x2DD4BF)
    nonisolated static let mMem      = Color(hex: 0xFBBF24)
    nonisolated static let mDisk     = Color(hex: 0xF97316)

    /// 等宽字体 —— 设计稿 host/IP/keybind/文件树用。设计稿首选 JetBrains Mono，
    /// 回退 SF Mono/Menlo；这里直接用系统等宽（即设计稿 fallback 链），不打包字体。
    nonisolated static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
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

extension WS {
    /// 把连接状态的语义色调（`StatusTint`，全 app 共用的中性映射）翻译成工作区
    /// 设计稿的状态色。只在工作区里用，故不污染 `StatusTint.color`（那条走系统色）。
    nonisolated static func color(for tint: StatusTint) -> Color {
        switch tint {
        case .success: return connected
        case .warning: return connecting
        case .caution: return disconnected
        case .error:   return failed
        case .neutral: return text3
        }
    }
}

/// 设计稿 workspace 标题栏里的连接状态胶囊：圆点 + 文案，外裹细描边的 capsule。
/// 复用 `ConnectionStatusDisplay` 做 state → (色调, 文案) 映射。
struct WSStatusPill: View {
    let state: TerminalSession.ConnectionState

    var body: some View {
        let display = ConnectionStatusDisplay(state: state)
        let dot = WS.color(for: display.tint)
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(display.label)
                .font(.system(size: 11))
                .foregroundStyle(WS.text2)
        }
        .padding(.leading, 7)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .overlay(Capsule().strokeBorder(WS.border, lineWidth: 1))
    }
}
