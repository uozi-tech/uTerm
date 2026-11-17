import UDesignKit
import SwiftUI
import AppKit

enum ServerChromeTitle {
    nonisolated static func serverTitle(serverName: String, groupName: String?) -> String {
        let group = groupName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !group.isEmpty else { return serverName }
        return "\(serverName) · \(group)"
    }

    nonisolated static func sftpWindowTitle(serverName: String, groupName: String?) -> String {
        windowTitle(serverTitle(serverName: serverName, groupName: groupName), kind: "SFTP")
    }

    nonisolated static func terminalWindowTitle(serverName: String, groupName: String?) -> String {
        windowTitle(serverTitle(serverName: serverName, groupName: groupName), kind: "终端")
    }

    nonisolated static func portForwardWindowTitle(serverName: String, groupName: String?) -> String {
        windowTitle(serverTitle(serverName: serverName, groupName: groupName), kind: "端口转发")
    }

    nonisolated static func parallelRunWindowTitle(commandName: String?) -> String {
        windowTitle(commandName ?? "", kind: "并行执行")
    }

    nonisolated static func localShellWindowTitle(tabTitle: String?) -> String {
        windowTitle(tabTitle ?? "", kind: "本机终端")
    }

    /// Dock 菜单、「窗口」菜单和调度中心列出的窗口标题：内容在前、窗口类型在后，
    /// 同一台服务器开多个窗口时也分得清。没有内容时只显示类型。
    private nonisolated static func windowTitle(_ subject: String, kind: String) -> String {
        subject.isEmpty ? kind : "\(subject) — \(kind)"
    }
}

/// 自绘标题栏里标题文字的颜色，跟系统标题一致：窗口在前台（key 或 main）用主文字色，退到后台变灰。
/// 不用强调色：强调色只给选中态和可点的控件。
private struct WindowTitleForeground: ViewModifier {
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        content.foregroundStyle(controlActiveState == .inactive ? UD.text3 : UD.text)
    }
}

extension View {
    func windowTitleForeground() -> some View { modifier(WindowTitleForeground()) }
}

/// 只写窗口标题，给会随内容变化的标题用。不走 `WorkspaceWindowChrome`：它每次更新都要
/// 重排红绿灯、遍历视图树去玻璃，跟不上 shell 标题的变化频率。
struct WindowTitleBinding: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { TitleView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? TitleView else { return }
        view.title = title
        view.apply()
    }

    final class TitleView: NSView {
        var title = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window, !title.isEmpty, window.title != title else { return }
            window.title = title
        }
    }
}

/// 自绘工作区标题栏（替代系统 toolbar）——彻底脱离系统 Liquid Glass。
/// 38px 高，分区方案 v3：直接画在窗口画布（`UD.pageBg`）上，无底色、无分隔线。
/// 左侧让位窗口红绿灯后放「文件」开关，居中服务器名 + 连接状态胶囊，右侧 Agent 开关。
struct WorkspaceTitleBar: View {
    let serverName: String
    let session: TerminalSession?
    /// 当前服务器活跃隧道数（>0 时在端口转发按钮右上角叠计数徽章）。
    let activeForwardCount: Int
    /// Agent inspector 是否已展开；用于让标题栏开关呈现选中态。
    let inspectorPresented: Bool
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
                    .windowTitleForeground()
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let session {
                    WSStatusPill(state: session.connectionState)
                }
            }
            // 纯展示，不参与命中测试：否则会截走标题栏空白处的双击（缩放）/ 拖动（见 WindowDragHandle）。
            .allowsHitTesting(false)

            // 两侧图标簇（Cursor 式，叠在居中内容之上，各自靠边）。
            HStack(spacing: 2) {
                // 让位窗口红绿灯（标准位 ~x13–68）。
                Color.clear.frame(width: 68)
                WSIconButton(systemName: "sidebar.leading",
                             help: "显示/隐藏文件（⌥⌘1）",
                             action: onToggleSidebar)
                Spacer()
                // 右侧图标簇：Agent 聊天气泡 + 端口转发 + 设置齿轮（对齐 Cursor 右上）。
                WSIconButton(systemName: inspectorPresented ? "bubble.left.fill" : "bubble.left",
                             help: inspectorPresented ? "隐藏 Agent（⌥⌘2）" : "显示 Agent（⌥⌘2）",
                             selected: inspectorPresented,
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
        // WindowDragHandle 既画画布色实底，又充当窗口拖动手柄：标题栏空白处
        // 按下拖动 = 移动窗口（取代整窗 isMovableByWindowBackground）。其上的按钮 /
        // 红绿灯是更靠前的控件，点击/拖拽会被它们自身消费，不会落到手柄。
        .background(WindowDragHandle(fill: WS.canvasNSColor))
    }
}

/// 标题栏 / 列头用的小图标按钮（WS 配色，hover 提亮 + 圆角底）。
struct WSIconButton: View {
    let systemName: String
    let help: String
    var selected = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13))
                .foregroundStyle(selected ? UD.accent : (hover ? UD.text : UD.text3))
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? UD.accentTint : (hover ? UD.rowHover : .clear))
                )
        }
        .buttonStyle(.udPlain)
        .onHover { hover = $0 }
        .help(help)
        // 纯图标按钮：用 help 文案兜底无障碍标签（去掉「（⌘…）」快捷键后缀更干净）。
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// help 文案去掉括号内快捷键提示，作为 VoiceOver 念读的用途标签。
    private var accessibilityLabel: String {
        if let range = help.range(of: "（") {
            return String(help[..<range.lowerBound])
        }
        return help
    }
}

/// 画布上的标签（分区方案 v3，SFTP 标签条与本机终端窗口共用）。激活 = `.udCard()` 同款的卡色胶囊
///（卡面 + 1pt 细轮廓 + 日间轻投影），表示「它就是下面那张卡」，所以底色传下面那张卡的颜色；未激活透明，
/// 悬停 `panelHover`；关闭按钮只在激活 / 悬停时出现。
///
/// 选中用 `.onTapGesture` 而不是外层 `Button`：macOS 上 `Button` 套 `Button` 时外层吞掉
/// 内层关闭按钮的点击（同 `UDPreviewTab` 的处理）。
struct WSCanvasTab<Leading: View>: View {
    let name: String
    let active: Bool
    /// 激活胶囊的底色 = 下面内容卡的颜色（SFTP 是 `UD.panel`，终端是终端底色）。
    var activeFill: Color = UD.panel
    var closeHelp = "关闭标签页"
    let onSelect: () -> Void
    let onClose: () -> Void
    @ViewBuilder let leading: (_ active: Bool) -> Leading

    @State private var hovered = false
    @State private var closeHovered = false
    @Environment(\.colorScheme) private var scheme

    /// 与 `.udCard()` 的卡片细轮廓同值（暗夜白 6% / 日间黑 6%）。
    private static var cardRing: Color { UD.dyn(.white(0.06), .black(0.06)) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        HStack(spacing: 8) {
            leading(active)
            Text(name)
                .font(UD.mono(12))
                .foregroundStyle(active ? UD.text : (hovered ? UD.text2 : UD.text3))
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(closeHovered ? UD.text
                                     : (active || hovered ? UD.text3 : Color.clear))
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(closeHovered ? UD.panelHover : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.udPlain)
            .onHover { closeHovered = $0 }
            .help(closeHelp)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background {
            if active {
                shape.fill(activeFill)
                    .overlay(shape.strokeBorder(Self.cardRing, lineWidth: 1))
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.04), radius: 1, x: 0, y: 1)
            } else if hovered {
                shape.fill(UD.panelHover)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

/// 关掉 AppKit 的「窗口移动时按屏幕布局调整位置」。
///
/// 这个配置默认开启：窗口换屏时，AppKit 经 `-[NSWindow _setFrameAfterMove:]` →
/// `_adjustWindowFrame:forMoveFromScreen:toScreen:` 把窗口挪到它在目标屏记住的位置。
/// 用户正在拖动时也一样，而系统拖动按增量继续，光标与窗口的相对位置就一直错开，严重时
/// 光标落到窗口外。AppKit 首次用到时才读取并缓存，所以要在创建任何窗口之前调用。
enum WindowMoveBehavior {
    nonisolated static let screenLayoutAdjustKey = DefaultsKey.screenLayoutAdjustOnWindowMove

    nonisolated static func disableScreenLayoutAdjustment() {
        UserDefaults.standard.register(defaults: [screenLayoutAdjustKey: false])
    }
}

/// 把窗口顶部的系统标题栏带从 WindowServer 的拖动区里摘掉，窗口只能经 `WindowDragHandle`
/// 拖动。必须挂在窗口根视图的最外层（比 `.background` 铺的底色更靠外）。
///
/// 不摘的后果：透明标题栏的顶部约 32pt 归 WindowServer 管，按下就开始移窗，早于 mouseDown。
/// 手柄的 `performDrag` 再叠上来，AppKit 就收不到拖动开始（日志里的 `Window move completed
/// without beginning`），于是拖动中每约 100ms 把旧位置约束后写回窗口。快速跨屏时这一下写回
/// 把窗口拽开，之后系统按增量继续拖，光标和窗口的相对位置就永久错开了。
///
/// 为什么不靠手柄自己声明可命中形状：SwiftUI 把窗口里所有可命中内容的并集当防拖动区，这个
/// 并集一旦包含整个窗口（`NSHostingView` 的 `preventionRegionCoversEntireWindow`），结果
/// 就作废、按「没有防拖动区」处理。uTerm 的窗口铺满了可命中内容，正好触发。这里在根部直接
/// 声明这个类别的形状，子视图不再参与并集，判断也就不会触发。
///
/// `0x100` 是 `ContentShapeKinds.windowDragPreventionUnderTitlebar` 的值（私有符号，macOS
/// 27.2 实测），用的是公开的 `init(rawValue:)`。系统改了这个值只会退回旧的跳动，不会崩；
/// `WindowDragRegionTests` 会报出来。
struct TitlebarDragRegion: ViewModifier {
    private static let preventionUnderTitlebar = ContentShapeKinds(rawValue: 0x100)

    func body(content: Content) -> some View {
        content.contentShape(Self.preventionUnderTitlebar, Band())
    }

    /// 根视图的坐标从安全区顶部算起，标题栏带在 y < 0 那一侧。往上多留足够高度，往下多盖
    /// 10pt 防标题栏高度有出入；形状只影响拖动区，不影响点击。
    private nonisolated struct Band: Shape {
        nonisolated func path(in rect: CGRect) -> Path {
            Path(CGRect(x: 0, y: -100, width: rect.width, height: 110))
        }
    }
}

/// 让自绘标题栏的空白处充当**窗口拖动手柄**：仅在本 NSView 命中区按下并拖动才移动
/// 窗口。取代窗口级 `isMovableByWindowBackground`——后者把整窗背景都变成拖动区，连
/// `WorkspaceColumns` 的列分隔条、`SplitterHandle` 的终端分屏手柄都被 AppKit 抢成
/// 「拖窗口」，导致无法调宽。标题栏上的按钮 / 红绿灯是更靠前的控件，点击会被它们
/// 自身消费，不会落到手柄；故只有标题栏空白处拖动才移窗。顺带画上 `UD.panel` 实色
/// 底（取代原 `.background(UD.panel)`）——若再叠一层 SwiftUI 色块会遮挡命中、夺走拖动。
///
/// 标题栏里的**纯展示内容**（居中标题文字、状态胶囊等）必须 `.allowsHitTesting(false)`：
/// 带 `.help` 的 `Text`、带 `Capsule` 底的胶囊都会被 SwiftUI 判为可命中，宿主视图随即
/// 截走 mouseDown，`DragView` 收不到 —— 表现为「双击标题栏文字不缩放、按住文字拖不动窗口」
/// （2026-09-09 在 1.10.3 实测：双击空白处缩放正常，双击服务器名 / 状态胶囊无反应）。
struct WindowDragHandle: NSViewRepresentable {
    /// 手柄实色底。旧分区窗口用 `UD.panel`（默认）；分区方案 v3 的窗口（标题栏在画布上）
    /// 传 `WS.canvasNSColor`。
    var fill: NSColor = WS.panelNSColor

    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.fill = fill
        view.wantsLayer = true
        view.layer?.backgroundColor = fill.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        var fill: NSColor = WS.panelNSColor
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            // 双击标题栏遵循系统「双击标题栏时」偏好（最小化 / 缩放 / 不操作）。
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: DefaultsKey.appleActionOnDoubleClick) {
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
                layer?.backgroundColor = fill.cgColor
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
    /// 写进 `NSWindow.title`；传空串表示标题另有来源（见 `WindowTitleBinding`）。
    let serverName: String
    /// 窗口钉色。旧分区窗口 = `UD.bg`（默认）；分区方案 v3 的窗口传 `WS.canvasNSColor`，
    /// 与 SwiftUI 根视图的 `UD.pageBg` 同值。
    var background: NSColor = WS.bgNSColor

    func makeNSView(context: Context) -> NSView { ChromeView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ChromeView else { return }
        view.serverName = serverName
        view.background = background
        view.apply()
    }

    final class ChromeView: NSView {
        var serverName = ""
        var background: NSColor = WS.bgNSColor

        /// 当前窗口上的通知观察者（换窗口时摘掉重挂）。
        private var windowObservers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeTitlebarRelayout()
            apply()
            // 透明标题栏 / full-size content 有时首帧后才完全生效，补一刀。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                MainActor.assumeIsolated { self?.apply() }
            }
        }

        func apply() {
            guard let window else { return }
            // 禁用 AppKit 原生窗口 Tab：uTerm 已有自己的终端标签，系统 Tab 只会重复一层
            // chrome。先收起可能由窗口恢复带回来的 Tab Bar，再禁止本窗口参与后续合并。
            if window.tabbedWindows != nil {
                window.toggleTabBar(nil)
            }
            window.tabbingMode = .disallowed
            window.appearance = nil   // 跟随 NSApp.appearance（AppAppearanceSync 驱动）
            window.isOpaque = true
            window.backgroundColor = background
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            // 不让整窗背景可拖：否则 WorkspaceColumns 的列分隔条 / SplitterHandle 的
            // 终端分屏手柄被 AppKit 抢成「拖窗口」，导致无法调宽。改由标题栏里的
            // WindowDragHandle 单独承担拖窗（见下）。
            window.isMovableByWindowBackground = false
            if !serverName.isEmpty { window.title = serverName }   // 供窗口菜单 / 调度中心
            Self.scheduleTrafficLightCentering(in: window)
            // 兜底：清掉任何残留系统材质（正常情况下没有）。
            var root: NSView? = window.contentView
            while let parent = root?.superview { root = parent }
            if let root { Self.deglass(root) }
        }

        /// AppKit 在窗口变成 / 失去 key、改尺寸、进出全屏、换屏时会重新布局标准按钮，把红绿灯
        /// 复位到系统默认的 ~32px 居中，比 38px 自绘栏里的图标高约 3pt（实测截图差 6.5px@2x，
        /// user 反馈「红绿灯往下一点，与 icon 一致」）。只在 apply() 时居中一次挡不住这些复位，
        /// 所以在这些时机都再排一次居中（幂等，异步到 AppKit 那轮布局之后）。
        private func observeTitlebarRelayout() {
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers.removeAll()
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
            ]
            windowObservers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated {
                        guard let window else { return }
                        Self.scheduleTrafficLightCentering(in: window)
                    }
                }
            }
        }

        /// 自绘标题栏统一高度——所有自绘标题栏（workspace / SFTP / welcome / keys / settings）
        /// 都用 38，红绿灯按此居中后与栏内自绘元素同处一条水平线。
        static let selfDrawnTitleBarHeight: CGFloat = 38

        /// 标题栏配置会让 AppKit 在下一轮 run loop 重新布局标准按钮；若在 `apply()` 里
        /// 立即改 frame，位置会被恢复成系统默认值。等该轮布局完成后再居中，并先 flush
        /// 尚未执行的布局，确保最终写入的 frame 不再被本轮配置覆盖。
        private static func scheduleTrafficLightCentering(in window: NSWindow) {
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                centerTrafficLights(window)
            }
        }

        /// 把窗口红绿灯垂直居中到自绘标题栏高度。系统默认把它们按标准 ~32px 标题栏居中，
        /// 比 38px 自绘栏里居中的图标 / 文字高约 3px，造成「红绿灯与自绘元素不在一条线」
        /// （user 反馈）。这里按 38px 重设其 `frame.origin.y`（幂等）。
        private static func centerTrafficLights(_ window: NSWindow) {
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type),
                      let container = button.superview else { continue }
                // 容错：superview 必须是标准标题栏视图（当前系统高约 32）。若不是（高度异常），
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
