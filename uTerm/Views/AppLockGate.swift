import SwiftUI

/// 把锁屏遮罩挂到任意 Scene 根视图：未解锁时 overlay 一层不透明 `LockCoverView`，
/// 并在视图出现时触发一次启动验证（多窗口由 `AppLockModel` 内 guard 收敛为只跑一次）。
///
/// 注：首验跑在首个出现窗口的 `.task` 上。冷启动时 Welcome 窗口常驻，故安全；
/// 本期「仅冷启动」不处理「验证中途关掉唯一窗口」这种极端情形（YAGNI）。
struct AppLockGate: ViewModifier {
    let model: AppLockModel   // @Observable：在 body 里读 isUnlocked 即建立依赖

    func body(content: Content) -> some View {
        content
            .overlay {
                if !model.isUnlocked {
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
                    ProgressView().controlSize(.small)
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
