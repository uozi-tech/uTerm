import SwiftUI
import Sparkle

/// SwiftUI-friendly wrapper around `SPUStandardUpdaterController`.
///
/// Spec 07 in-app 集成。生命周期：`uTermApp` 持有一个 `@State` 实例；
/// `init` 时启动 Sparkle 的 auto-check 定时器（per setting）。
///
/// 暴露的所有 property 都是 SwiftUI 友好的：`@Observable` 让 SwiftUI 在
/// 绑定的 view 触达对应 getter 时自动建立依赖。`@MainActor` 因 Sparkle
/// 接口需要主线程。
///
/// 注意：Sparkle 不通过 SwiftUI 通知机制发布内部状态变化；`lastUpdateCheckDate`
/// 等会在 Sparkle 完成 check 后改变，但 SwiftUI 不会自动重渲染。可接受 v1
/// 瑕疵；后续 spec 加 KVO bridge 修。
@MainActor
@Observable
final class AppUpdater {
    private let controller: SPUStandardUpdaterController
    private let updaterDelegate = AppUpdaterDelegate()

    init() {
        // startingUpdater: true → Sparkle init 后立即启动 auto-check timer
        // delegate 只用来知道「要重启装更新了」：这时退出不用问用户本机终端怎么办。
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
    }

    /// Bind 到 SettingsView 的 Toggle。Sparkle 持久化此值到 UserDefaults
    /// (key: `SUEnableAutomaticChecks`)。
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// 上次成功 check 的时间；nil = 从未 check 过（首次启动）。
    var lastUpdateCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }

    /// `false` 当 Sparkle 当前正在进行 check（防 double-click）。
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    /// 触发用户手动 check。Sparkle 默认 UI driver 弹窗向用户报结果。
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 当前 app 版本字符串，与 AboutSettingsView 同模式（spec 01）。
    /// 读 Info.plist 的 CFBundleShortVersionString + CFBundleVersion。
    /// 静态 helper 复用模式，便于测试 mock。
    static var currentVersionString: String {
        currentVersionString(from: Bundle.main.infoDictionary)
    }

    static func currentVersionString(from info: [String: Any]?) -> String {
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "v\(short) (\(build))"
    }
}

nonisolated private final class AppUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { LocalShellQuitPolicy.shared.isRelaunchingForUpdate = true }
    }
}
