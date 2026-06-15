import SwiftUI
import SwiftData

/// uTerm iOS / iPadOS 入口。
///
/// 复用 macOS 端的 Core 模型 + SSH/SFTP/Agent 服务（见 `uTermMobile` target 的
/// 共享文件成员），UI 为按设计稿 `uTerm iOS · iPadOS.html` 重写的原生 SwiftUI：
/// 紧凑态（iPhone）底部标签 + 推进导航；常规态（iPad）NavigationSplitView。
@main
struct MobileApp: App {
    @AppStorage("appearancePreference")
    private var appearancePreferenceRaw: String = AppearancePreference.system.rawValue

    @State private var lock: AppLockModel

    let modelContainer: ModelContainer = MobileModelContainer.make()

    init() {
        // 应用锁：读 requireAuthAtLaunch（缺键视作「关」——iOS 默认不锁，由设置开启）。
        // 用 object as? Bool 而非 UserDefaults.bool，避免缺键时 false 与「显式关」混淆。
        let requireAuth = (UserDefaults.standard.object(forKey: "requireAuthAtLaunch") as? Bool) ?? false
        _lock = State(initialValue: AppLockModel(
            authenticator: SystemBiometricAuthenticator(),
            requireAuthAtLaunch: requireAuth))
    }

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            MobileLaunchRoot(appearance: appearance, lock: lock)
        }
        .modelContainer(modelContainer)
    }
}

/// 启动外壳：先盖一层「星空之上」开屏（`SplashView`），短暂停留后淡出露出主界面。
/// 开屏始终暗色（自带固定品牌色），不受 `appearancePreference` 影响。
private struct MobileLaunchRoot: View {
    let appearance: AppearancePreference
    let lock: AppLockModel
    @State private var showSplash = true

    var body: some View {
        ZStack {
            MobileRootView()
                .preferredColorScheme(appearance.colorScheme)
                .tint(M.accent)

            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(10)
                    .task {
                        // 尽量短：一瞬品牌过场，极短停留后立即淡出，不拖慢进入。
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        withAnimation(.easeOut(duration: 0.25)) { showSplash = false }
                    }
            }
        }
        // 应用锁挂在整栈最外层：上锁时遮罩盖住开屏与主界面，系统验证弹窗浮于其上。
        .mobileAppLockGate(lock)
    }
}
