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

    let modelContainer: ModelContainer = MobileModelContainer.make()

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            MobileLaunchRoot(appearance: appearance)
        }
        .modelContainer(modelContainer)
    }
}

/// 启动外壳：先盖一层「星空之上」开屏（`SplashView`），短暂停留后淡出露出主界面。
/// 开屏始终暗色（自带固定品牌色），不受 `appearancePreference` 影响。
private struct MobileLaunchRoot: View {
    let appearance: AppearancePreference
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
    }
}
