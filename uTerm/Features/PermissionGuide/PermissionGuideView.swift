import AppKit
import SwiftUI
import UDesignKit

/// 授权引导窗口：uTerm 用到的系统权限集中在一处，逐项说明用途、显示当前状态、一键去授权。
/// 第一次启动自动弹一次（见 `PermissionGuideWindow.shouldPresentAtLaunch`），之后从「uTerm › 授权引导…」打开。
struct PermissionGuideView: View {
    @State private var model = PermissionGuideModel(environment: .live)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            PermissionGuideTitleBar()
            // 最多五项，内容本身就放得下，不套 ScrollView；窗口高度跟着内容走（Scene 上是 .contentSize）。
            VStack(alignment: .leading, spacing: 24) {
                header
                section(title: "常用", hint: nil, kinds: [.notifications, .localNetwork])
                section(title: "远程控制", hint: "只有让手机查看或操作这台 Mac 时才需要。",
                        kinds: [.screenCapture, .accessibility])
                if model.needsRelaunch {
                    relaunchBanner
                }
                if model.visibleKinds.contains(.loginItem) {
                    section(title: "后台运行", hint: nil, kinds: [.loginItem])
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            footer
        }
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .background(UD.bg)
        .contentSizedUnderTitleBar()
        .background(WorkspaceWindowChrome(serverName: "授权引导"))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        // 从系统设置切回来时重新读一遍（屏幕录制 / 辅助功能在本进程里通常仍是旧值，要重启才变）。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ULogo(size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text("让 uTerm 用上全部功能")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(UD.text)
                Text("下面这些权限要你在 macOS 里亲自点头。都可以先跳过，用不到的功能不必打开，以后从菜单「uTerm › 授权引导…」随时回来。")
                    .font(.system(size: 12))
                    .foregroundStyle(UD.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section(title: String, hint: String?, kinds: [PermissionKind]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
            VStack(spacing: 0) {
                ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                    if index > 0 { UDPaneDivider(.horizontal) }
                    PermissionGuideRow(kind: kind, status: model.status(of: kind),
                                       request: { Task { await model.request(kind) } },
                                       openSettings: { model.openSettings(kind) })
                }
            }
            .udCard()
        }
    }

    private var relaunchBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(UD.caution)
            Text("在系统设置里打开屏幕录制或辅助功能后，要重新启动 uTerm 才生效。")
                .font(.system(size: 12))
                .foregroundStyle(UD.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            UDButton(title: "重新启动", style: .primary) { model.relaunch() }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UD.caution.opacity(0.1)))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("已就绪 \(model.grantedCount) / \(model.visibleKinds.count)")
                .font(.system(size: 12))
                .foregroundStyle(UD.text3)
                .monospacedDigit()
            Spacer()
            UDButton(title: "完成", style: .primary) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }
}

/// 一项权限：图标、名称、状态、用途，右侧是这一态下能做的事。
private struct PermissionGuideRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(UD.accent)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UD.accentSoft))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(kind.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(UD.text)
                    PermissionStatusChip(status: status)
                }
                Text(kind.purpose)
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.text3)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
    }

    @ViewBuilder private var actions: some View {
        switch status {
        case .checking, .granted:
            EmptyView()
        case .notAsked:
            UDButton(title: "允许", style: .primary, action: request)
        case .notGranted where kind.takesEffectAfterRelaunch:
            VStack(alignment: .trailing, spacing: 4) {
                UDButton(title: "授权", style: .primary, action: request)
                UDButton(title: "打开系统设置", style: .link, height: 20, action: openSettings)
            }
        case .notGranted, .needsRelaunch:
            UDButton(title: "打开系统设置", style: .secondary, action: openSettings)
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
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
    }
}

private struct PermissionGuideTitleBar: View {
    var body: some View {
        Text("授权引导")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(UD.text)
            // 纯展示，不参与命中测试：否则会截走标题栏空白处的双击（缩放）/ 拖动。
            .allowsHitTesting(false)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(WindowDragHandle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(UD.border).frame(height: 1)
            }
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

    var purpose: String {
        switch self {
        case .notifications:
            return "终端里的命令跑完、或程序在等你输入时，标签不在眼前也能提醒你。"
        case .localNetwork:
            return "Mac 与 iPhone / iPad 之间的局域网同步、用手机远程控制这台 Mac 都要用到。连局域网里的服务器时，系统会以「uTerm 终端」的名义另问一次。"
        case .screenCapture:
            return "让配对过的手机看到这台 Mac 的屏幕。macOS 会定期请你重新确认。"
        case .accessibility:
            return "让手机操作这台 Mac 的鼠标和键盘。没有这项时，远程桌面只能看不能动。"
        case .loginItem:
            return "你开了「登录时在后台启动」，还差系统批准这一步。"
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
