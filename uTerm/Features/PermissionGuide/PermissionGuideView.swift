import AppKit
import SwiftUI
import UDesignKit

/// 授权引导窗口：uTerm 用到的系统权限集中在一处，逐项说明用途、显示当前状态、一键去授权。
/// 第一次启动自动弹一次（见 `PermissionGuideWindow.shouldPresentAtLaunch`），之后从「uTerm › 授权引导…」打开。
///
/// 版式：标题栏画在画布上，下面整块内容是**一张卡**（四周留 `cardInset`），收尾栏在卡内最下方。
/// 卡的圆角下沿和下面那条画布明确告诉人「到底了」——旧版内容平铺到窗口下沿，底栏像被屏幕截断，总让人想往下滚。
/// 每项用途压成一行（补充说明放悬停提示），五项全出加重启提示也远低于 13 寸屏的可用高度。
struct PermissionGuideView: View {
    @State private var model: PermissionGuideModel
    @Environment(\.dismiss) private var dismiss

    init(model: PermissionGuideModel = PermissionGuideModel(environment: .live)) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            PermissionGuideTitleBar()
            // 最多五项，内容本身就放得下，不套 ScrollView；窗口高度跟着内容走（Scene 上是 .contentSize）。
            VStack(spacing: 0) {
                header
                section("常用", kinds: [.notifications, .localNetwork])
                section("远程控制", hint: "只有让手机查看或操作这台 Mac 时才需要",
                        kinds: [.screenCapture, .accessibility])
                if model.needsRelaunch {
                    relaunchNotice
                }
                if model.visibleKinds.contains(.loginItem) {
                    section("后台运行", kinds: [.loginItem])
                }
                UDPaneDivider(.horizontal)
                    .padding(.top, 14)
                footer
            }
            .udCard()
            .padding([.horizontal, .bottom], UD.Layout.cardInset)
        }
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .background(UD.pageBg)
        .contentSizedUnderTitleBar()
        .background(WorkspaceWindowChrome(serverName: "授权引导", background: WS.canvasNSColor))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        // 从系统设置切回来时重新读一遍（屏幕录制 / 辅助功能在本进程里通常仍是旧值，要重启才变）。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ULogo(size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("让 uTerm 用上全部功能")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(UD.text)
                Text("都可以先跳过，以后从菜单「uTerm › 授权引导…」随时回来。")
                    .font(.system(size: 12))
                    .foregroundStyle(UD.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PermissionGuideMetrics.inset)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private func section(_ title: LocalizedStringKey, hint: LocalizedStringKey? = nil,
                         kinds: [PermissionKind]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(UD.text3)
                    .accessibilityAddTraits(.isHeader)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text3)
                }
            }
            .padding(.horizontal, PermissionGuideMetrics.inset)
            .padding(.top, 16)
            .padding(.bottom, 2)
            ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                if index > 0 {
                    // 分隔线从文字起点开始，图标列不切开，一组读起来是一块。
                    UDPaneDivider(.horizontal)
                        .padding(.leading, PermissionGuideMetrics.textLeading)
                        .padding(.trailing, PermissionGuideMetrics.inset)
                }
                PermissionGuideRow(kind: kind, status: model.status(of: kind),
                                   request: { Task { await model.request(kind) } },
                                   openSettings: { model.openSettings(kind) })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 紧跟在「远程控制」两项下面：重启只跟这两项有关。
    private var relaunchNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(UD.caution)
            Text("在「系统设置」里打开「屏幕录制」或「辅助功能」后，要重新启动 uTerm 才生效。")
                .font(.system(size: 12))
                .foregroundStyle(UD.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            UDButton(title: "重新启动", style: .primary, height: PermissionGuideMetrics.buttonHeight) {
                model.relaunch()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UD.caution.opacity(0.1)))
        .padding(.horizontal, PermissionGuideMetrics.inset - 8)
        .padding(.top, 6)
    }

    /// 收尾栏：卡内最后一块，上面一条分隔线；左边是进度，右边是唯一的「完成」。
    private var footer: some View {
        HStack(spacing: 12) {
            PermissionProgress(granted: model.grantedCount, total: model.visibleKinds.count)
            Spacer()
            UDButton(title: "完成", style: .primary) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, PermissionGuideMetrics.inset - 4)
        .frame(height: 52)
    }
}

private enum PermissionGuideMetrics {
    /// 卡内左右边距。
    static let inset: CGFloat = 20
    static let iconSize: CGFloat = 28
    static let iconSpacing: CGFloat = 12
    /// 行内文字的起点（分隔线从这里开始）。
    static let textLeading: CGFloat = inset + iconSize + iconSpacing
    /// 行内按钮比标准 32 矮一档，行高由两行文字决定，不被按钮撑高。
    static let buttonHeight: CGFloat = 28
}

/// 一项权限：图标、名称、状态、一行用途，右侧是这一态下能做的事。
private struct PermissionGuideRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: PermissionGuideMetrics.iconSpacing) {
            Image(systemName: kind.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UD.accent)
                .frame(width: PermissionGuideMetrics.iconSize, height: PermissionGuideMetrics.iconSize)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UD.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(kind.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(UD.text)
                    PermissionStatusChip(status: status)
                }
                Text(kind.purpose)
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(kind.detail ?? "")
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, PermissionGuideMetrics.inset)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
    }

    @ViewBuilder private var actions: some View {
        let height = PermissionGuideMetrics.buttonHeight
        switch status {
        case .checking, .granted:
            EmptyView()
        case .notAsked:
            UDButton(title: "允许", style: .primary, height: height, action: request)
        case .notGranted where kind.takesEffectAfterRelaunch:
            // 横排，不叠两层：叠起来会把这一行撑得比别的行高一截。
            HStack(spacing: 10) {
                UDButton(title: "打开系统设置", style: .link, height: height, action: openSettings)
                UDButton(title: "授权", style: .primary, height: height, action: request)
            }
        case .notGranted, .needsRelaunch:
            UDButton(title: "打开系统设置", style: .secondary, height: height, action: openSettings)
        }
    }
}

/// 「已就绪 n / m」配一排小格，一眼看出还差几项。
private struct PermissionProgress: View {
    let granted: Int
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                ForEach(0..<total, id: \.self) { index in
                    Capsule()
                        .fill(index < granted ? UD.success : UD.fillMed)
                        .frame(width: 14, height: 4)
                }
            }
            .accessibilityHidden(true)
            Text("已就绪 \(granted) / \(total)")
                .font(.system(size: 12))
                .foregroundStyle(granted == total ? UD.success : UD.text3)
                .monospacedDigit()
        }
    }
}

private struct PermissionStatusChip: View {
    let status: PermissionStatus

    var body: some View {
        // 检测中也只画静态圆点：本地网络在断网时会一直停在检测中，转圈会让整窗每帧重绘。
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(status == .granted ? UD.success : UD.text2)
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(Capsule().fill(UD.fillFaint))
    }

    private var label: String {
        switch status {
        case .checking: return "检测中"
        case .notAsked: return "未询问"
        case .granted: return "已允许"
        case .notGranted: return "未允许"
        case .needsRelaunch: return "重启后生效"
        }
    }

    private var tint: Color {
        switch status {
        case .checking, .notAsked: return UD.text3
        case .granted: return UD.success
        case .notGranted: return UD.warning
        case .needsRelaunch: return UD.caution
        }
    }
}

extension View {
    /// 自绘标题栏、窗口高度随内容（`.windowResizability(.contentSize)`）时代替 `.ignoresSafeArea(.container, edges: .top)`。
    ///
    /// 窗口按「内容 + 顶部安全区」定高，内容却顶进了安全区，底下就会空出一条安全区高的白边（实测 32pt）。
    /// 把这段高度从底部扣回来，窗口正好等于内容。
    func contentSizedUnderTitleBar() -> some View {
        modifier(ContentSizedUnderTitleBar())
    }
}

private struct ContentSizedUnderTitleBar: ViewModifier {
    @State private var topInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .padding(.bottom, -topInset)
            .ignoresSafeArea(.container, edges: .top)
            .background(TitleBarHeightReader { topInset = $0 })
    }
}

/// 从窗口读标题栏高度（`frame` 减 `contentLayoutRect`），不从 SwiftUI 几何量。
///
/// 在这个视图上量 `safeAreaInsets.top` 是自指的：底部扣回 t 之后量到的是 (标题栏 + t) / 2，
/// 每轮只把误差减半，要约 55 轮才收敛到 32；窗口一改尺寸读数又归零重来。真窗口里它一直收敛不完，
/// 主线程 100% 卡在 SwiftUI 更新里（授权引导窗口启动即弹，整个 app 卡死）。窗口的标题栏高度与内容无关，
/// 读一次就是终值。
private struct TitleBarHeightReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: (CGFloat) -> Void
        private var reported: CGFloat?
        private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        private func report() {
            guard let window else { return }
            let height = window.frame.height - window.contentLayoutRect.height
            guard height != reported else { return }
            reported = height
            // 不在 AppKit / SwiftUI 布局过程中改 SwiftUI 状态。
            DispatchQueue.main.async { [onChange] in onChange(height) }
        }
    }
}


/// 标题栏直接画在画布上：不铺底色、不画分隔线（分区方案 v3.3），和下面的内容卡靠底色差分开。
private struct PermissionGuideTitleBar: View {
    var body: some View {
        Text("授权引导")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(UD.text)
            // 纯展示，不参与命中测试：否则会截走标题栏空白处的双击（缩放）/ 拖动。
            .allowsHitTesting(false)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(WindowDragHandle(fill: WS.canvasNSColor))
    }
}

private extension PermissionKind {
    var title: String {
        switch self {
        case .notifications: return "通知"
        case .localNetwork: return "本地网络"
        case .screenCapture: return "屏幕录制"
        case .accessibility: return "辅助功能"
        case .loginItem: return "后台登录项"
        }
    }

    /// 一行讲清用途；放不下的补充放 `detail`（悬停提示）。
    var purpose: String {
        switch self {
        case .notifications:
            return "命令执行完毕或程序等待输入时，即使标签页不在前台也能通知你。"
        case .localNetwork:
            return "局域网同步、用手机远程控制这台 Mac 都要用到。"
        case .screenCapture:
            return "让配对过的手机看到这台 Mac 的屏幕。"
        case .accessibility:
            return "让手机操作这台 Mac 的鼠标和键盘；没有这项授权时手机只能查看。"
        case .loginItem:
            return "你已打开「登录后在后台启动」，还需要系统批准。"
        }
    }

    var detail: String? {
        switch self {
        case .localNetwork:
            return "Mac 与 iPhone / iPad 之间同步要用。连接局域网里的主机时，系统会以「uTerm 终端」的名义再问一次。"
        case .screenCapture:
            return "macOS 会定期要求重新确认。"
        case .notifications, .accessibility, .loginItem:
            return nil
        }
    }

    var symbol: String {
        switch self {
        case .notifications: return "bell.badge"
        case .localNetwork: return "network"
        case .screenCapture: return "rectangle.dashed.badge.record"
        case .accessibility: return "accessibility"
        case .loginItem: return "power"
        }
    }
}
