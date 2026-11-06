import Foundation
import SwiftData

/// 两端 `App.init` 共用的启动引导。iOS 与 macOS **相同的步骤与先后顺序只写在这里**；
/// 平台专属步骤留在各自入口（`uTermApp` / `MobileApp`），插在 `startCore` 与 `finishCore` 之间。
///
/// 顺序（两端一致，改之前先读每步的理由——首装卡启动屏、CloudKit 初始化失败都和顺序有关）：
///
/// 1. `CloudKitSyncMonitor.start()`：**必须早于建容器**，CloudKit 可能在容器初始化期间就发出
///    setup / import 事件，晚订阅就漏掉第一轮（设置页的同步状态与日志都靠它）。
/// 2. 建 `ModelContainer`：容器怎么建是平台的事（mac 失败即 fatal，iOS 回退纯本地），由调用方传工厂。
/// 3. 建 `SharedPreferencesSync`（只建不启动，见第 6 步）。
/// 4. 建 `LANSyncCoordinator` 并按角色做启动激活（`startForAppLaunch()`）：发送端（Mac）立即搜索；
///    接收端（移动端）只在启用过时监听——首次启动不弹「本地网络」授权。
///
///    —— 平台专属步骤（mac：关窗口自动合并 Tab、清旧文件 / 旧钥匙串条目、首帧外观）——
///
/// 5. 建 `AppLockModel`：读 `requireAuthAtLaunch`（缺键默认值两端相反，见 `AppLockPreference`）。
/// 6. `preferences.startForAppLaunch()`：在第一个 scene body 求值前把 iCloud KVS 的标量偏好拉下来，
///    `AccentState` 这类只在初始化时读一次 UserDefaults 的服务才拿得到同步后的值。
///
/// `StartupMaintenance.run` 不在这里：两端时机与条件不同（mac 排在命令行接口等 mac 专属服务之后、且测试宿主
/// 里不跑；iOS 紧跟第 6 步、测试宿主里也跑），各自入口保留原样。
@MainActor
enum AppBootstrap {
    /// 第 1–4 步的产物，入口把它们分别装进各自的 `@State`。
    struct Core {
        let cloudKitSync: CloudKitSyncMonitor
        let modelContainer: ModelContainer
        let preferences: SharedPreferencesSync
        let lanSync: LANSyncCoordinator
    }

    /// 第 1–4 步。`cloudKitSync` / `preferences` / `lanDefaults` 只为测试注入，生产调用用默认值。
    static func startCore(
        lanRole: LANSyncRole,
        makeContainer: () -> ModelContainer,
        cloudKitSync: CloudKitSyncMonitor = CloudKitSyncMonitor(),
        preferences: @autoclosure () -> SharedPreferencesSync = SharedPreferencesSync(),
        lanDefaults: UserDefaults = .standard
    ) -> Core {
        cloudKitSync.start()
        let container = makeContainer()
        let preferences = preferences()
        let lan = LANSyncCoordinator(
            role: lanRole,
            preferences: preferences,
            dataStore: LANSyncDataStore(container: container),
            defaults: lanDefaults)
        lan.startForAppLaunch()
        return Core(cloudKitSync: cloudKitSync, modelContainer: container,
                    preferences: preferences, lanSync: lan)
    }

    /// 第 5–6 步：建应用锁，再拉共享偏好。返回的锁模型由入口装进 `@State`；
    /// 锁屏遮罩与首次验证由各 Scene 上的锁门（mac `.appLockGate` / iOS `.mobileAppLockGate`）驱动。
    static func finishCore(
        _ core: Core,
        authenticator: BiometricAuthenticator = SystemBiometricAuthenticator(),
        defaults: UserDefaults = .standard
    ) -> AppLockModel {
        let lock = AppLockModel(
            authenticator: authenticator,
            requireAuthAtLaunch: AppLockPreference.isEnabled(in: defaults))
        core.preferences.startForAppLaunch()
        return lock
    }
}
