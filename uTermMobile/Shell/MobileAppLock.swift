import SwiftUI
import UIKit
import LocalAuthentication

/// iOS 应用锁：开启「Face ID / 触控 ID 解锁」后，冷启动与「从后台回到前台」都要先验证身份。
///
/// 复用与 macOS 共享的 `AppLockModel` 状态机（`requireAuthAtLaunch` 决定是否上锁、按机器能力
/// 选策略、指纹被锁退回设备密码）；这里只补 iOS 特有的三件事：
///  - 回到后台即重新上锁（`relock()`）、回前台再触发一次验证；
///  - 用移动端 `M` 设计令牌画锁屏界面（macOS 的 `AppLockGate` 用 `UD*` 组件，已被 target 排除）；
///  - 识别当前机器的生物识别类型，给设置开关与锁屏文案/图标。

/// 当前机器的生物识别类型 → 展示用文案与图标名。
enum MobileBiometry {
    static func describe() -> (title: String, icon: String) {
        let ctx = LAContext()
        // 必须先 canEvaluatePolicy 一次，biometryType 才会被填充。
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID:  return ("Face ID", "faceid")
        case .touchID: return ("触控 ID", "touchid")
        default:       return ("生物识别", "lock")
        }
    }

    /// 设置里打开应用锁前先验证一次：既确认设备可用（有生物识别或已设密码），
    /// 也取得用户授权——避免开关一拨就把下次启动锁死却无从解锁。返回收敛后的结果。
    static func confirmEnable() async -> AuthOutcome {
        let auth = SystemBiometricAuthenticator()
        let policy: LAPolicy
        if case .biometrics = auth.availability() {
            policy = .deviceOwnerAuthenticationWithBiometrics
        } else {
            policy = .deviceOwnerAuthentication
        }
        return await auth.authenticate(policy: policy, reason: "开启 uTerm 应用锁")
    }
}

extension View {
    /// 顺 `MobileLaunchRoot` 的修饰链接入应用锁：锁屏遮罩 + 场景相位重锁。
    func mobileAppLockGate(_ model: AppLockModel) -> some View {
        modifier(MobileAppLockGate(model: model))
    }
}

private struct MobileAppLockGate: ViewModifier {
    let model: AppLockModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("requireAuthAtLaunch") private var requireAuth = false
    @State private var lockWindow = MobileLockWindow()

    func body(content: Content) -> some View {
        // 内容**留在视图树里**，只是藏起来、不收触摸：改前上锁时把整棵内容树卸掉，
        // 根视图持有的会话工作区随之销毁——开着应用锁时，切去别的 App 再回来所有终端 /
        // 文件标签全没了；那条路径也不经过 close()，SSH 连接与 host-key 等待都悬在半空。
        //
        // 安全边界不靠卸载：锁屏画在独立的高层窗口里（`MobileLockWindow`），盖住本窗口的
        // 一切，包括已弹出的抽屉 / 全屏覆盖；内容同时置透明、去掉触摸与无障碍（SwiftTerm 的
        // UIView 不守 ZStack 顺序，只靠叠一层盖不住它），窗口建好之前的那一帧也看不到底下。
        ZStack {
            content
                .opacity(model.isUnlocked ? 1 : 0)
                .allowsHitTesting(model.isUnlocked)
                .accessibilityHidden(!model.isUnlocked)
            // 树内也留一份锁屏：独立窗口万一没建起来（冷启动场景还没连上），这里兜底。
            if !model.isUnlocked {
                MobileLockCover(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: model.isUnlocked)
        .onChange(of: model.isUnlocked, initial: true) { _, unlocked in
            if unlocked {
                lockWindow.hide()
            } else {
                lockWindow.show(model: model, colorScheme: colorScheme)
            }
        }
        .onChange(of: colorScheme) { _, scheme in lockWindow.update(colorScheme: scheme) }
        // 冷启动首验：didStart guard 让它与下面的 .active 分支去重，只跑一次。
        .task { await model.startInitialAuthIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            guard requireAuth else { return }
            switch phase {
            case .background:
                // 离开 App 即上锁；回前台时由 .active 分支再触发验证。
                model.relock()
            case .active:
                // relock 已重置 guard，从后台回来这里能再次触发；冷启动则被 guard 挡掉。
                if !model.isUnlocked {
                    Task { await model.startInitialAuthIfNeeded() }
                }
            default:
                break
            }
        }
    }
}

/// 锁屏所在的独立窗口：层级高于 App 主窗口及其上的所有弹出物（系统验证弹窗仍在它之上）。
@MainActor
final class MobileLockWindow {
    private var windows: [UIWindow] = []

    func show(model: AppLockModel, colorScheme: ColorScheme) {
        // 收起键盘：键盘窗口层级比我们高，不收会悬在锁屏上。
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        guard windows.isEmpty else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = UIHostingController(rootView: MobileLockCover(model: model)
                .environment(\.mAccent, M.accent)
                .tint(M.accent))
            window.rootViewController?.view.backgroundColor = .clear
            window.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
            window.isHidden = false
            windows.append(window)
        }
    }

    func update(colorScheme: ColorScheme) {
        for window in windows { window.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light }
    }

    func hide() {
        let closing = windows
        windows = []
        guard !closing.isEmpty else { return }
        UIView.animate(withDuration: 0.22, animations: {
            for window in closing { window.alpha = 0 }
        }, completion: { _ in
            for window in closing { window.isHidden = true }
        })
    }
}

/// 锁屏遮罩：铺满、不透明背景盖住底下的主机列表 / 终端；ULogo + 生物识别图标 +
/// 状态文案 +「解锁」按钮（取消 / 失败后重触发）。系统验证弹窗浮在它之上。
struct MobileLockCover: View {
    let model: AppLockModel

    /// 生物识别类型在进程内不会变；每次重算 body 都 `canEvaluatePolicy` 一次是同步 IPC。
    private let biometry = MobileBiometry.describe()

    var body: some View {
        ZStack {
            M.bg.ignoresSafeArea()
            VStack(spacing: 20) {
                ULogo(size: 72)
                MIcon(name: biometry.icon, size: 34, color: M.accent)
                Text(message)
                    .font(M.sans(15))
                    .foregroundStyle(M.text2)
                    .multilineTextAlignment(.center)
                if case .authenticating = model.state {
                    ProgressView().tint(M.accent)
                } else {
                    MBtn(title: "解锁", icon: "lock") {
                        Task { await model.authenticate() }
                    }
                }
            }
            .padding(40)
            // Duo 状态栏在右侧一列时按整块屏幕居中。
            .mCentersOnScreen()
        }
    }

    private var message: String {
        switch model.state {
        case .unlocked:        return ""
        case .authenticating:  return "正在验证身份…"
        case .locked:          return "uTerm 已锁定"
        case .failed(let msg): return msg
        }
    }
}
