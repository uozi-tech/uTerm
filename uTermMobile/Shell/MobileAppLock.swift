import SwiftUI
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
    @AppStorage("requireAuthAtLaunch") private var requireAuth = false

    func body(content: Content) -> some View {
        ZStack {
            if model.isUnlocked {
                content
                    .transition(.opacity)
            } else {
                // 不仅盖住内容，还要让内容离开视图树：否则锁定期间终端/Agent 的
                // task 仍可继续运行，应用锁只剩视觉效果。
                MobileLockCover(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: model.isUnlocked)
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

/// 锁屏遮罩：铺满、不透明背景盖住底下的主机列表 / 终端；ULogo + 生物识别图标 +
/// 状态文案 +「解锁」按钮（取消 / 失败后重触发）。系统验证弹窗浮在它之上。
private struct MobileLockCover: View {
    let model: AppLockModel

    var body: some View {
        let biometry = MobileBiometry.describe()
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
