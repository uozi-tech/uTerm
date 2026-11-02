import SwiftUI
import SwiftData
import UIKit

/// uTerm iOS / iPadOS 入口。
///
/// 复用 macOS 端的 Core 模型 + SSH/SFTP/Agent 服务（见 `uTermMobile` target 的
/// 共享文件成员），UI 为按设计稿 `uTerm iOS · iPadOS.html` 重写的原生 SwiftUI：
/// 紧凑态（iPhone）底部标签 + 推进导航；常规态（iPad）NavigationSplitView。
@main
struct MobileApp: App {
    /// 仅用于向 APNs 注册远程通知（CloudKit 静默推送的送达前提，见 `MobileAppDelegate`）。
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate

    @AppStorage("appearancePreference")
    private var appearancePreferenceRaw: String = AppearancePreference.system.rawValue

    @State private var lock: AppLockModel
    /// CloudKit 同步可观测器：订阅镜像事件，喂 AppLogger + 给设置页同步状态。
    @State private var cloudKitSync = CloudKitSyncMonitor()
    /// 普通偏好：本机 UserDefaults 为准，经 iCloud KVS 跨设备保底，局域网同步另按快照传输。
    @State private var sharedPreferences = SharedPreferencesSync()
    @State private var lanSync: LANSyncCoordinator

    let modelContainer: ModelContainer

    init() {
        // 必须在创建 SwiftData 容器之前订阅：CloudKit 可能在容器初始化期间就发出 setup / import 事件。
        let sync = CloudKitSyncMonitor()
        sync.start()
        _cloudKitSync = State(initialValue: sync)
        modelContainer = MobileModelContainer.make()

        let preferences = SharedPreferencesSync()
        _sharedPreferences = State(initialValue: preferences)
        let lan = LANSyncCoordinator(
            role: .receiver, preferences: preferences,
            dataStore: LANSyncDataStore(container: modelContainer))
        // 局域网监听要「本地网络」授权；没用过局域网同步的人不该一启动就被弹窗问。只有看到过
        // 设置 › 局域网接收（或早就配过配对码）的才在启动时开始监听，见 LANSyncActivation。
        if LANSyncActivation.isActivated { lan.start() }
        _lanSync = State(initialValue: lan)

        // 应用锁：读 requireAuthAtLaunch（缺键视作「关」——iOS 默认不锁，由设置开启）。
        // 用 object as? Bool 而非 UserDefaults.bool，避免缺键时 false 与「显式关」混淆。
        let requireAuth = (UserDefaults.standard.object(forKey: "requireAuthAtLaunch") as? Bool) ?? false
        _lock = State(initialValue: AppLockModel(
            authenticator: SystemBiometricAuthenticator(),
            requireAuthAtLaunch: requireAuth))
        // Pull shared scalar preferences before the first scene body is evaluated.
        preferences.start()
        StartupMaintenance.run(container: modelContainer)
    }

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            MobileLaunchRoot(appearance: appearance, lock: lock)
                .environment(lanSync)
                .environment(cloudKitSync)
                .task {
                    sharedPreferences.start()
                }
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
        // 量状态栏 / 屏幕圆角的实际位置，下发给整棵树（含应用锁、全屏覆盖层）。见 MChromeGeometry。
        .mMeasuresChrome()
    }
}

/// 极简 App 委托：唯一职责是启动时向 APNs 注册远程通知。
///
/// SwiftData 的 CloudKit 镜像（`NSPersistentCloudKitContainer`）靠 CloudKit 静默推送，
/// 才能做到「对端一改、本端即拉」；而推送要送达 App，必须先 `registerForRemoteNotifications()`
/// 让设备拿到 APNs token。收到推送后由容器内部处理并触发 import——**无需**我们实现
/// `didReceiveRemoteNotification`，这里只负责注册并记录注册结果。
///
/// 前置条件（缺任一都会注册失败 / 收不到推送，同步即退化为「仅前台拉取」）：
/// - entitlements 的 `aps-environment`（Push Notifications 能力）
/// - Info.plist `UIBackgroundModes` 含 `remote-notification`
/// - App ID 在开发者后台已开启 Push 能力
@MainActor
final class MobileAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        AppLogger.info("远程通知已注册，CloudKit 同步推送就绪", category: "sync")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // 常见原因：未配 aps-environment / App ID 未开 Push / 模拟器无 APNs。
        // 注册失败时 CloudKit 退回「仅启动 / 前台拉取」，同步变迟钝但不致命。
        AppLogger.warn("远程通知注册失败，CloudKit 将退化为前台同步：\(error.localizedDescription)", category: "sync")
    }
}
