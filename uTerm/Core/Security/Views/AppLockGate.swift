import SwiftUI

/// 把应用锁挂到任意 Scene 根视图：未解锁时**不挂载受保护内容**，只展示
/// `LockCoverView`，并触发一次启动验证（多窗口由 `AppLockModel` 内 guard 收敛）。
///
/// 不能用 `content.overlay { ... }`：overlay 只是视觉遮挡，底层 `WelcomeView.task`
/// 仍会在验证前执行，包括恢复上次窗口、读取凭据和启动 SSH 转发。条件挂载让应用锁
/// 成为真正的执行边界，而不只是遮罩。
struct AppLockGate: ViewModifier {
    let model: AppLockModel   // @Observable：在 body 里读 isUnlocked 即建立依赖

    func body(content: Content) -> some View {
        ZStack {
            if model.isUnlocked {
                content
                    .transition(.opacity)
            } else {
                LockCoverView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.isUnlocked)
        .task { await model.startInitialAuthIfNeeded() }
    }
}

extension View {
    /// 顺现有 `.modifier(AppAppearanceSync).modifier(LocaleOverride)` 链接入应用锁。
    func appLockGate(_ model: AppLockModel) -> some View {
        modifier(AppLockGate(model: model))
    }
}

/// 锁屏遮罩：铺满、不透明背景（`UD.bg`）盖住底下的服务器列表 / 终端；
/// ULogo + 状态文案 + 「解锁」按钮（取消 / 失败后重触发）。系统验证弹窗浮在它之上。
private struct LockCoverView: View {
    let model: AppLockModel

    var body: some View {
        ZStack {
            UD.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                ULogo(size: 72)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(UD.text2)
                if case .authenticating = model.state {
                    UDIndeterminateBar()
                        .frame(width: 84)
                } else {
                    UDButton(title: "解锁", style: .primary, systemImage: "lock.open") {
                        Task { await model.authenticate() }
                    }
                }
            }
            .padding(40)
        }
    }

    private var message: String {
        switch model.state {
        case .unlocked:                 return ""
        case .authenticating:           return "正在验证身份…"
        case .locked:                   return "uTerm 已锁定"
        case .failed(let msg):          return msg
        }
    }
}
