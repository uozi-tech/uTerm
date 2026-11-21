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

    @AppStorage(DefaultsKey.appearancePreference)
    private var appearancePreferenceRaw: String = AppearancePreference.system.rawValue

    @State private var lock: AppLockModel
    /// CloudKit 同步可观测器：订阅镜像事件，喂 AppLogger + 给设置页同步状态。
    @State private var cloudKitSync = CloudKitSyncMonitor()
    /// 普通偏好：本机 UserDefaults 为准，经 iCloud KVS 跨设备保底，局域网同步另按快照传输。
    @State private var sharedPreferences = SharedPreferencesSync()
    @State private var lanSync: LANSyncCoordinator
    /// 远控：配对过的 Mac 及其连接。不会自己开始浏览（要「本地网络」授权），
    /// 等用户在主机页点「控制我的 Mac 上的终端」。测试宿主不碰真实的 iCloud 钥匙串。
    @State private var remoteMacs = RemoteMacDirectory.mobile(relayStore: TestHostEnvironment.isActive ? nil : RemoteRelayConfigStore())
    /// 「我的设备」（设备组）：前台时一直读名册，别的设备想加入时弹输码单子（`RemoteGroupJoinHandler`）。全 App 一个。
    @State private var deviceGroupService = RemoteDeviceGroupService()
    /// 订阅（uTerm Pro）。门禁在 `MobileStore` 的各个「开始用」入口上；测试宿主里视为已订阅。
    @State private var subscriptions = SubscriptionStore.live()
    @Environment(\.scenePhase) private var scenePhase

    let modelContainer: ModelContainer

    init() {
        // 两端共用的启动引导第 1–4 步（CloudKit 订阅 → 容器 → 偏好 → 局域网接收端），顺序见 `AppBootstrap`。
        // 接收端只有看到过 设置 › 局域网接收（或早就配过配对码）的才在启动时开始监听，首次启动不弹「本地网络」授权。
        let core = AppBootstrap.startCore(lanRole: .receiver, makeContainer: MobileModelContainer.make)
        _cloudKitSync = State(initialValue: core.cloudKitSync)
        modelContainer = core.modelContainer
        _sharedPreferences = State(initialValue: core.preferences)
        _lanSync = State(initialValue: core.lanSync)

        // 第 5–6 步：应用锁（iOS 缺键视作「关」，由设置开启，见 `AppLockPreference`）→ 拉共享偏好。
        _lock = State(initialValue: AppBootstrap.finishCore(core))
        StartupMaintenance.run(container: modelContainer)
        if !TestHostEnvironment.isActive {
            RemoteLegacyRoster.withdrawLocalDevice()
            RemoteLegacyDevices.retireLocalLeftovers()
        }
        LaunchTiming.initFinished()
    }

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearancePreferenceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            MobileLaunchRoot(appearance: appearance, lock: lock)
                .modifier(RemoteRelayLinkHandler())
                .modifier(RemotePairingLinkHandler())
                .modifier(RemoteGroupJoinHandler())
                .environment(lanSync)
                .environment(remoteMacs)
                .environment(deviceGroupService)
                // 只在前台读名册；退到后台就停，回来接着。测试宿主里不跑（名册在内存，跑了也只会干扰用例）。
                .onChange(of: scenePhase, initial: true) { _, phase in
                    guard !TestHostEnvironment.isActive else { return }
                    if phase == .active { deviceGroupService.start(hosts: remoteMacs) } else if phase == .background { deviceGroupService.stop() }
                }
                .environment(cloudKitSync)
                .environment(subscriptions)
                .mobileSubscriptionPaywall(subscriptions)
                .task {
                    sharedPreferences.startForAppLaunch()
                    subscriptions.start()
                }
        }
        .modelContainer(modelContainer)
    }
}

/// 启动外壳：先盖一层「星空之上」开屏（`SplashView`），短暂停留后淡出露出主界面。
/// 开屏分昼 / 夜两版，跟系统外观走（与系统启动屏同档），不受 `appearancePreference` 影响。
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
        // 挂在最外层：开了应用锁时首屏是锁屏，同样算数，不把验证耗时混进启动时间。
        .onAppear { LaunchTiming.firstScreenAppeared() }
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
