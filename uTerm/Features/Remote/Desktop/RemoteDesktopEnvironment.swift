import AppKit
import CoreGraphics
import Foundation
import Observation

/// 远程桌面在 Mac 上依赖的外部能力：开关、授权、显示器、采集、注入。
///
/// 生产用 `live`（ScreenCaptureKit + CGEvent + 设置开关）；测试换成合成画面与记录器，
/// 其余（服务端、连接、发送端、编码、链路）与生产完全同一份代码。
struct RemoteDesktopEnvironment {
    var isEnabled: @MainActor () -> Bool
    /// 两项授权查询是 async：系统要同步问 tccd，各 15–40 ms，`live` 放到后台线程跑。
    var screenCaptureAuthorized: @MainActor () async -> Bool
    var canPostEvents: @MainActor () async -> Bool
    /// 要看的显示器（nil = 主显示器）。
    var display: @MainActor (_ requested: UInt32?) -> RemoteDesktopDisplay?
    var makeSource: @MainActor (_ display: RemoteDesktopDisplay, _ width: Int, _ height: Int, _ tenBit: Bool)
        -> any RemoteDesktopFrameSource
    var makeInjector: @MainActor (_ display: RemoteDesktopDisplay) -> any RemoteDesktopInputSink
    /// Mac 光标的全局坐标（在连接队列上轮询）。
    var cursorLocation: (@Sendable () -> CGPoint?)?
    /// Mac 的系统剪贴板（拷贝的文字回传手机）。nil = 不回传。
    var clipboard: (any RemoteDesktopClipboardSource)? = nil

    /// 没接入设置时（测试里只测终端的那些用例）：桌面一律关闭。
    static let disabled = RemoteDesktopEnvironment(
        isEnabled: { false }, screenCaptureAuthorized: { false }, canPostEvents: { false }, display: { _ in nil },
        makeSource: { _, _, _, _ in fatalError("远程桌面未启用") }, makeInjector: { _ in fatalError("远程桌面未启用") },
        cursorLocation: nil)

    static func live(settings: RemoteControlSettings) -> RemoteDesktopEnvironment {
        RemoteDesktopEnvironment(
            isEnabled: { settings.isDesktopEnabled },
            screenCaptureAuthorized: { await RemoteDesktopPermissions.screenCaptureGranted() },
            canPostEvents: { await RemoteDesktopPermissions.postEventsGranted() },
            display: { requested in RemoteDesktopEnvironment.display(id: requested ?? CGMainDisplayID()) },
            makeSource: { display, width, height, tenBit in
                ScreenCaptureFrameSource(display: display, width: width, height: height, tenBit: tenBit)
            },
            makeInjector: { display in RemoteEventInjector(display: display) },
            cursorLocation: { CGEvent(source: nil)?.location },
            clipboard: RemoteSystemClipboard())
    }

    /// 显示器的全局点坐标与原生像素尺寸。
    static func display(id: CGDirectDisplayID) -> RemoteDesktopDisplay? {
        let bounds = CGDisplayBounds(id)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let mode = CGDisplayCopyDisplayMode(id)
        let pixelWidth = mode?.pixelWidth ?? Int(bounds.width)
        let pixelHeight = mode?.pixelHeight ?? Int(bounds.height)
        return RemoteDesktopDisplay(id: id, bounds: bounds, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}

/// 远程桌面要的两项系统授权：屏幕录制（看）与辅助功能 / PostEvent（控制）。
///
/// 调研 §3.7 的 S1 实测结论决定了这里的写法：
/// - 授权结果**缓存在进程里**：用户在系统设置里打开开关后，本进程的 `CGPreflight…` 仍然返回 false，
///   注入也无效，必须重启 uTerm。所以界面上不靠轮询判断，而是明说「授权后需重启」并给按钮。
/// - `CGRequestPostEventAccess()` 一调用，系统自己就会往 TCC 写一条 `PostEvent = Denied`（相当于在
///   列表里登记一个关着的开关），这是正常行为。所以只在用户点「授权」时才调，不在启动时调。
/// - 两个 `CGPreflight…` 每次都同步等 tccd，实测 15–38 ms、不缓存。所以只给 async 版本，在后台线程上跑，
///   免得有人在主线程上（尤其是视图的初值表达式里）直接读。
enum RemoteDesktopPermissions {
    static func screenCaptureGranted() async -> Bool {
        await Task.detached { CGPreflightScreenCaptureAccess() }.value
    }

    static func postEventsGranted() async -> Bool {
        await Task.detached { CGPreflightPostEventAccess() }.value
    }

    /// 弹系统授权框（第一次）或什么都不做（已经拒绝过，只能去设置里开）。返回当前进程内的结果。
    ///
    /// 两个 `CGRequest…` 都同步等 tccd 把系统授权框处理完才返回，放在主线程上整个 app 会卡住
    /// （授权引导点「授权」即卡死）。所以和 preflight 一样放到后台线程。
    @discardableResult
    static func requestScreenCapture() async -> Bool {
        await timedRequest("屏幕录制") { CGRequestScreenCaptureAccess() }
    }

    @discardableResult
    static func requestPostEvents() async -> Bool {
        await timedRequest("辅助功能") { CGRequestPostEventAccess() }
    }

    private static func timedRequest(_ name: String, _ body: @escaping @Sendable () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        let granted = await Task.detached(operation: body).value
        let elapsed = ContinuousClock.now - start
        AppLogger.info("授权请求「\(name)」耗时 \(elapsed)，结果 \(granted)", category: "permissions")
        return granted
    }

    static func openScreenCaptureSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 重新启动 uTerm（授权在新进程里才生效）：先拉起一个新实例，再退出自己。
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    AppLogger.info("重新启动 uTerm 失败：\(error.localizedDescription)", category: RemoteLog.category)
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}

/// 设置页上展示的授权状态。进程内的值不会因为用户在系统设置里改了开关而变（见上），
/// 所以「已请求过但还没生效」单独记一笔，用来提示重启。
///
/// 不在 `init` 里查：它是设置页的 `@State` 初值，SwiftUI 每次重建视图都会再跑一遍初值表达式，
/// 在那里等 tccd 会让设置窗口每次刷新都卡几十毫秒。由视图在 `.task` 里调 `refresh()`。
@MainActor
@Observable
final class RemoteDesktopPermissionState {
    private(set) var screenCapture = false
    private(set) var postEvents = false
    /// 第一次查询回来之前不显示授权按钮，免得已授权的用户先看到一闪而过的「授权」。
    private(set) var isLoaded = false
    /// 用户在这次运行里点过「授权」：系统设置里打开之后要重启才生效。
    private(set) var requestedThisRun = false
    /// 切回前台和点按钮都会触发查询，可能叠在一起；只认最后一次发起的结果。
    @ObservationIgnored private var generation = 0

    func refresh() async {
        generation += 1
        let current = generation
        async let screen = RemoteDesktopPermissions.screenCaptureGranted()
        async let post = RemoteDesktopPermissions.postEventsGranted()
        let (screenGranted, postGranted) = await (screen, post)
        guard current == generation else { return }
        // 值没变就不写：`@Observable` 对同值赋值也会通知，整页会白白重算。
        if screenCapture != screenGranted { screenCapture = screenGranted }
        if postEvents != postGranted { postEvents = postGranted }
        if !isLoaded { isLoaded = true }
    }

    /// 系统授权框自带「打开系统设置」，这里不再另开设置页，免得两个窗口叠在一起。
    func requestScreenCapture() {
        requestedThisRun = true
        Task {
            await RemoteDesktopPermissions.requestScreenCapture()
            await refresh()
        }
    }

    func requestPostEvents() {
        requestedThisRun = true
        Task {
            await RemoteDesktopPermissions.requestPostEvents()
            await refresh()
        }
    }
}
