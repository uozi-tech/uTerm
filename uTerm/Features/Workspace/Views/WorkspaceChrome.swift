import SwiftUI
import AppKit

enum ServerChromeTitle {
    nonisolated static func serverTitle(serverName: String, groupName: String?) -> String {
        let group = groupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !group.isEmpty else { return serverName }
        return "\(serverName) · \(group)"
    }

    nonisolated static func sftpWindowTitle(serverName: String, groupName: String?) -> String {
        "SFTP — \(serverTitle(serverName: serverName, groupName: groupName))"
    }
}

/// 自绘工作区标题栏（替代系统 toolbar）——彻底脱离系统 Liquid Glass。
/// 38px 扁平 UD.panel 条 + 底部 1px 描边：左侧让位窗口红绿灯后放「文件」开关，
/// 居中服务器名 + 连接状态胶囊，右侧 Agent 开关。
struct WorkspaceTitleBar: View {
    let serverName: String
    let session: TerminalSession?
    /// 当前服务器活跃隧道数（>0 时在端口转发按钮右上角叠计数徽章）。
    let activeForwardCount: Int
    let onToggleSidebar: () -> Void
    let onToggleInspector: () -> Void
    /// 打开本服务器的端口转发管理窗口。
    let onOpenForwarding: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            // 居中：服务器名 + 状态胶囊
            HStack(spacing: 10) {
                Text(serverName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(serverName)
                if let session {
                    WSStatusPill(state: session.connectionState)
                }
            }

            // 两侧图标簇（Cursor 式，叠在居中内容之上，各自靠边）。
            HStack(spacing: 2) {
                // 让位窗口红绿灯（标准位 ~x13–68）。
                Color.clear.frame(width: 68)
                WSIconButton(systemName: "sidebar.leading",
                             help: "显示/隐藏文件（⌘⌥1）",
                             action: onToggleSidebar)
                Spacer()
                // 右侧图标簇：Agent 聊天气泡 + 端口转发 + 设置齿轮（对齐 Cursor 右上）。
                WSIconButton(systemName: "bubble.left",
                             help: "显示/隐藏 Agent（⌘⌥2）",
                             action: onToggleInspector)
                // 端口转发：有活跃隧道时右上角叠计数徽章（ZStack .topTrailing + 小偏移，
                // 避免徽章溢出 38px 栏；clipping 关掉让徽章可探出按钮命中框外）。
                ZStack(alignment: .topTrailing) {
                    WSIconButton(systemName: "arrow.left.arrow.right",
                                 help: "端口转发",
                                 action: onOpenForwarding)
                    if activeForwardCount > 0 {
                        UDCountBadge(activeForwardCount, accent: true)
                            .scaleEffect(0.72)
                            .offset(x: 6, y: -5)
                            .allowsHitTesting(false)
                    }
                }
                WSIconButton(systemName: "gearshape",
                             help: "设置（⌘,）",
                             action: onOpenSettings)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        // WindowDragHandle 既画 UD.panel 实色底，又充当窗口拖动手柄：标题栏空白处
        // 按下拖动 = 移动窗口（取代整窗 isMovableByWindowBackground）。其上的按钮 /
        // 红绿灯是更靠前的控件，点击/拖拽会被它们自身消费，不会落到手柄。
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }
}

/// 标题栏 / 列头用的小图标按钮（WS 配色，hover 提亮 + 圆角底）。
struct WSIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13))
                .foregroundStyle(hover ? UD.text : UD.text3)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? UD.rowHover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        // 纯图标按钮：用 help 文案兜底无障碍标签（去掉「（⌘…）」快捷键后缀更干净）。
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// help 文案去掉括号内快捷键提示，作为 VoiceOver 念读的用途标签。
    private var accessibilityLabel: String {
        if let range = help.range(of: "（") {
            return String(help[..<range.lowerBound])
        }
        return help
    }
}

/// 让自绘标题栏的空白处充当**窗口拖动手柄**：仅在本 NSView 命中区按下并拖动才移动
/// 窗口。取代窗口级 `isMovableByWindowBackground`——后者把整窗背景都变成拖动区，连
/// `WorkspaceColumns` 的列分隔条、`SplitterHandle` 的终端分屏手柄都被 AppKit 抢成
/// 「拖窗口」，导致无法调宽。标题栏上的按钮 / 红绿灯是更靠前的控件，点击会被它们
/// 自身消费，不会落到手柄；故只有标题栏空白处拖动才移窗。顺带画上 `UD.panel` 实色
/// 底（取代原 `.background(UD.panel)`）——若再叠一层 SwiftUI 色块会遮挡命中、夺走拖动。
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.wantsLayer = true
        view.layer?.backgroundColor = WS.panelNSColor.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            // 双击标题栏遵循系统「双击标题栏时」偏好（最小化 / 缩放 / 不操作）。
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.miniaturize(nil)
                case "None":     break
                default:         window.zoom(nil)   // 缺省 = Maximize/Zoom
                }
                return
            }
            window.performDrag(with: event)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = WS.panelNSColor.cgColor
            }
        }
    }
}

/// 把工作区 `NSWindow` 配成**自绘扁平深色窗口**：透明标题栏 + full-size content +
/// 红绿灯浮在自绘标题栏上、标题栏可拖动移动窗口（WindowDragHandle，非整窗背景）；
/// 不透明 WS 底色、深色外观。
/// 已无系统 toolbar / NavigationSplitView，理论上不存在系统材质；仍保留一次
/// `NSVisualEffectView` 去玻璃遍历做兜底。
struct WorkspaceWindowChrome: NSViewRepresentable {
    let serverName: String

    func makeNSView(context: Context) -> NSView { ChromeView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ChromeView else { return }
        view.serverName = serverName
        view.apply()
    }

    final class ChromeView: NSView {
        var serverName = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // 透明标题栏 / full-size content 有时首帧后才完全生效，补一刀。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        func apply() {
            guard let window else { return }
            window.appearance = nil   // 跟随 NSApp.appearance（AppAppearanceSync 驱动）
            window.isOpaque = true
            window.backgroundColor = WS.bgNSColor
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            // 不让整窗背景可拖：否则 WorkspaceColumns 的列分隔条 / SplitterHandle 的
            // 终端分屏手柄被 AppKit 抢成「拖窗口」，导致无法调宽。改由标题栏里的
            // WindowDragHandle 单独承担拖窗（见下）。
            window.isMovableByWindowBackground = false
            if !serverName.isEmpty { window.title = serverName }   // 供窗口菜单 / 调度中心
            Self.centerTrafficLights(window)
            // 兜底：清掉任何残留系统材质（正常情况下没有）。
            var root: NSView? = window.contentView
            while let parent = root?.superview { root = parent }
            if let root { Self.deglass(root) }
        }

        /// 自绘标题栏统一高度——所有自绘标题栏（workspace / SFTP / welcome / keys / settings）
        /// 都用 38，红绿灯按此居中后与栏内自绘元素同处一条水平线。
        static let selfDrawnTitleBarHeight: CGFloat = 38

        /// 把窗口红绿灯垂直居中到自绘标题栏高度。系统默认把它们按标准 ~28px 标题栏居中，
        /// 比 38px 自绘栏里居中的图标 / 文字高约 5px，造成「红绿灯与自绘元素不在一条线」
        /// （user 反馈）。这里按 38px 重设其 `frame.origin.y`（幂等，每次 `apply()` 重设）。
        private static func centerTrafficLights(_ window: NSWindow) {
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type),
                      let container = button.superview else { continue }
                // 容错：superview 必须是标准标题栏视图（高约 28）。若不是（高度异常），
                // 不动按钮——避免把红绿灯算到窗口中间/外面。
                guard container.bounds.height < 60 else { continue }
                // AppKit 左下原点：container 顶边贴窗口顶，从顶往下 height/2 处放按钮中心。
                let y = container.bounds.height - selfDrawnTitleBarHeight / 2 - button.frame.height / 2
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y))
            }
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
