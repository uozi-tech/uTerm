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
    /// 开流前整理显示器：无显示器的 Mac 建一块按看的设备像素（与方向无关）和它的像素倍数来的 2 倍虚拟屏
    ///（`RemoteHeadlessDisplay`）。`pointScale` 为 nil 是老的主控端没报。
    var prepareDisplays: @MainActor (_ viewerPixels: (width: Int, height: Int), _ pointScale: Double?) async -> Void
        = { _, _ in }
    /// 看过屏幕的设备连上来时先把显示器准备好（无显示器的 Mac 预建虚拟屏，见 `RemoteHeadlessDisplay.prewarm`）。
    var prewarmDisplays: @MainActor (_ viewerPixels: (width: Int, height: Int), _ pointScale: Double?) async -> Void
        = { _, _ in }
    /// 有没有人在看桌面：没人了虚拟屏过一会儿拆掉，又有人来就留着。
    var displaysInUse: @MainActor (_ inUse: Bool) -> Void = { _ in }
    /// 此刻接着的全部显示器（主显示器在前）。
    var listDisplays: @MainActor () -> [RemoteDesktopDisplaySummary] = { [] }
    /// 此刻能单独看的窗口，最前面的在前。
    var listWindows: @MainActor () -> [RemoteDesktopWindowSummary] = { [] }
    /// 只看一个窗口时的采集目标（把窗口当成一块「显示器」，`windowID` 不为 nil）和窗口标题。窗口没了返回 nil。
    var window: @MainActor (_ id: UInt32) -> (display: RemoteDesktopDisplay, title: String)? = { _ in nil }
    /// 把窗口提到最前（要「辅助功能」授权）。点击只会落到最上面的窗口上，被盖住的窗口点不到。
    var raiseWindow: @MainActor (_ id: UInt32) async -> Void = { _ in }
    /// 输入按进程投递时开流前用：同一个 App 有别的窗口叠在它上面才提，而且不激活 App（见 `RemoteDesktopWindows.surface`）。
    var surfaceWindow: @MainActor (_ id: UInt32) async -> Void = { _ in }
    /// 这个窗口的 App 此刻是不是当前 App。窗口已经没了也算是（没有可提的东西）。
    var windowAppIsFront: @MainActor (_ id: UInt32) -> Bool = { _ in true }
    /// 把窗口调成这么大（点，要「辅助功能」授权）。返回改之前的位置，没改返回 nil。
    var fitWindow: @MainActor (_ id: UInt32, _ size: CGSize) async -> CGRect? = { _, _ in nil }
    /// 把调过大小的窗口放回原来的位置和大小。
    var restoreWindow: @MainActor (_ id: UInt32, _ frame: CGRect) async -> Void = { _, _ in }
    var makeSource: @MainActor (_ display: RemoteDesktopDisplay, _ width: Int, _ height: Int, _ tenBit: Bool)
        -> any RemoteDesktopFrameSource
    /// `independent`：只看一个窗口时主控端要了「独立键鼠」——输入直接投给窗口所在的进程，不动 Mac 上的指针。
    var makeInjector: @MainActor (_ display: RemoteDesktopDisplay, _ independent: Bool) -> any RemoteDesktopInputSink
    /// Mac 光标的全局坐标（在连接队列上轮询）。
    var cursorLocation: (@Sendable () -> CGPoint?)?
    /// 光标形状的指纹（便宜，每 100 ms 调一次）与图（贵，指纹变了才调）。nil = 不发形状。
    var cursorSignature: (@MainActor () -> Int?)? = nil
    var cursorImage: (@MainActor () -> RemoteDesktopCursorImage?)? = nil
    /// Mac 的系统剪贴板（拷贝的文字回传手机）。nil = 不回传。
    var clipboard: (any RemoteDesktopClipboardSource)? = nil
    /// 锁屏状态、唤醒、远程解锁与帘幕。nil = 这台 Mac 不支持远程解锁（不声明 `desktop-unlock` 能力）。
    var makeScreenController: (@MainActor () -> any RemoteScreenController)? = nil
    /// 用户是否打开了「允许远程解锁」。关着时不声明 `desktop-unlock` 能力、也拒绝解锁请求。
    var isUnlockEnabled: @MainActor () -> Bool = { false }
    /// 开流前点亮显示器并等它醒来：息屏时 ScreenCaptureKit 列不出睡着的显示器，采集会起不来。测试里不做事。
    var wakeDisplay: @MainActor (_ id: CGDirectDisplayID) async -> Void = { _ in }
    /// 用户是否打开了「允许传输声音」。
    var isAudioEnabled: @MainActor () -> Bool = { false }
    /// 系统声音的来源。nil = 这台 Mac 不送声音。
    var makeAudioSource: (@MainActor (_ display: RemoteDesktopDisplay) -> any RemoteAudioSource)? = nil

    /// 没接入设置时（测试里只测终端的那些用例）：桌面一律关闭。
    static let disabled = RemoteDesktopEnvironment(
        isEnabled: { false }, screenCaptureAuthorized: { false }, canPostEvents: { false }, display: { _ in nil },
        makeSource: { _, _, _, _ in fatalError("远程桌面未启用") }, makeInjector: { _, _ in fatalError("远程桌面未启用") },
        cursorLocation: nil)

    static func live(settings: RemoteControlSettings) -> RemoteDesktopEnvironment {
        RemoteDesktopEnvironment(
            isEnabled: { settings.isDesktopEnabled },
            screenCaptureAuthorized: { await RemoteDesktopPermissions.screenCaptureGranted() },
            canPostEvents: { await RemoteDesktopPermissions.postEventsGranted() },
            display: { requested in RemoteDesktopEnvironment.display(id: requested ?? CGMainDisplayID()) },
            prepareDisplays: { viewer, scale in
                await RemoteHeadlessDisplay.ensureHiDPI(viewerPixels: viewer, pointScale: scale)
            },
            prewarmDisplays: { viewer, scale in
                await RemoteHeadlessDisplay.prewarm(viewerPixels: viewer, pointScale: scale)
            },
            displaysInUse: { inUse in
                if inUse { RemoteHeadlessDisplay.cancelRelease() } else { RemoteHeadlessDisplay.scheduleRelease() }
            },
            listDisplays: { RemoteDesktopEnvironment.activeDisplays() },
            listWindows: { RemoteDesktopWindows.list() },
            window: { id in
                RemoteDesktopWindows.target(id: id).map { ($0.display, $0.entry.title.isEmpty ? $0.entry.app : $0.entry.title) }
            },
            raiseWindow: { id in
                // 同步等辅助功能接口（对方卡住时最多 1 秒），不占主线程。
                _ = await Task.detached { RemoteDesktopWindows.raise(id: id) }.value
            },
            surfaceWindow: { id in
                await Task.detached { RemoteDesktopWindows.surface(id: id) }.value
            },
            windowAppIsFront: { id in RemoteDesktopWindows.appIsFront(id: id) },
            // 屏幕放得下就原地调；放不下先挪到虚拟屏上（`RemoteWindowStage`）。还原时放回原处，虚拟屏随后拆掉。
            fitWindow: { id, size in await RemoteWindowStage.fit(id: id, size: size) },
            restoreWindow: { id, frame in
                await Task.detached { RemoteDesktopWindows.restore(id: id, frame: frame) }.value
                RemoteWindowStage.restored(id: id)
            },
            makeSource: { display, width, height, tenBit in
                ScreenCaptureFrameSource(display: display, width: width, height: height, tenBit: tenBit)
            },
            makeInjector: { display, independent in RemoteEventInjector.live(display: display, independent: independent) },
            cursorLocation: { CGEvent(source: nil)?.location },
            cursorSignature: { RemoteSystemCursor.signature() },
            cursorImage: { RemoteSystemCursor.image() },
            clipboard: RemoteSystemClipboard(),
            makeScreenController: { LiveRemoteScreenController() },
            isUnlockEnabled: { settings.isDesktopUnlockEnabled },
            wakeDisplay: { id in await RemoteDisplayWake.wake(display: id) },
            isAudioEnabled: { settings.isDesktopAudioEnabled },
            makeAudioSource: { display in ScreenCaptureAudioSource(displayID: display.id) })
    }

    /// 接着的显示器，主显示器在前。名字取系统给的（「内建视网膜显示器」、外接显示器的型号）。
    static func activeDisplays() -> [RemoteDesktopDisplaySummary] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            return RemoteDesktopDisplaySummary(id: id, name: names[id] ?? String(localized: "显示器 \(id)"),
                                               width: bounds.width, height: bounds.height, isMain: id == main)
        }
        .sorted { $0.isMain && !$1.isMain }
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

/// 被控端（别的设备看 / 控制这台 Mac）的授权去哪里查、向谁申请。
///
/// 远控进程在服务时（App 里的 `RemoteHostServer.agent` 不为 nil），远程桌面的采集与注入都在它那里做，授权也要按它算：
/// 屏幕录制 tccd 会归到 uTerm 名下，「辅助功能」（PostEvent）却只认远控进程自己的身份——系统设置里另有一项
/// 「uTerm 远程控制」要打开。所以这时问远控进程、由它申请；屏幕录制仍由 App 申请（记在 uTerm 名下，系统框由前台的
/// App 弹更自然）。没有远控进程时问本进程。
enum RemoteHostPermissionSource {
    /// 问一次远控进程最多等多久。它没回话（刚被重启、正在换版本）就按没问到算。
    static let agentReplyTimeout: Duration = .seconds(2)

    /// 被控端此刻的授权。远控进程刚重启、还没连上时隔一会儿再问；一直问不到（远控关着、版本太旧）就退回本进程的结果。
    static func current(agent: (any RemoteHostAgentLink)?,
                        retryDelay: Duration = .milliseconds(500), attempts: Int = 6,
                        replyTimeout: Duration = agentReplyTimeout,
                        local: () async -> RemoteHostAgentPermissions = localPermissions) async -> RemoteHostAgentPermissions {
        if let agent {
            for attempt in 0..<max(attempts, 1) {
                switch await ask(agent, .desktopPermissions, timeout: replyTimeout) {
                case .answered(let permissions):
                    return permissions
                case .unsupported:
                    AppLogger.notice("远控进程不认得授权查询（旧版本），改看 uTerm 本身的授权", category: RemoteLog.category)
                    return await local()
                case .unreachable:
                    if attempt + 1 < attempts { try? await Task.sleep(for: retryDelay) }
                }
            }
            AppLogger.notice("问不到远控进程的授权状态，改看 uTerm 本身的授权", category: RemoteLog.category)
        }
        return await local()
    }

    /// 申请「辅助功能」：有远控进程时由它申请（等系统授权框处理完才回）；问不到时退回本进程。
    static func requestPostEvents(agent: (any RemoteHostAgentLink)?,
                                  local: () async -> Void = { await RemoteDesktopPermissions.requestPostEvents() }) async {
        if let agent, let reply = await agent.send(.requestPostEvents), reply.ok { return }
        await local()
    }

    /// 本进程的授权（没有远控进程，或问不到它时）。
    static func localPermissions() async -> RemoteHostAgentPermissions {
        async let screen = RemoteDesktopPermissions.screenCaptureGranted()
        async let post = RemoteDesktopPermissions.postEventsGranted()
        return await RemoteHostAgentPermissions(screenCapture: screen, postEvents: post)
    }

    private enum Answer: Sendable {
        case answered(RemoteHostAgentPermissions)
        /// 回了话但解不开：远控进程是不认得这条命令的旧版本。
        case unsupported
        /// 没连着，或超时没回。
        case unreachable
    }

    /// `send` 在连接断掉时要等它自己的长超时（130 秒）才回，界面等不了这么久，这里另设一个短的。
    private static func ask(_ agent: any RemoteHostAgentLink, _ command: RemoteHostAgentCommand,
                            timeout: Duration) async -> Answer {
        let reply: RemoteHostAgentCommandReply? = await withCheckedContinuation { continuation in
            let once = RemoteOnce<RemoteHostAgentCommandReply?>(continuation)
            Task { once.resume(await agent.send(command)) }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
        }
        guard let reply else { return .unreachable }
        guard reply.ok, let data = reply.data,
              let permissions = RemoteHostAgentJSON.decode(RemoteHostAgentPermissions.self, from: data) else {
            return .unsupported
        }
        return .answered(permissions)
    }
}

/// 设置页上展示的授权状态。进程内的值不会因为用户在系统设置里改了开关而变（见上），
/// 所以「已请求过但还没生效」单独记一笔，用来提示重启。
///
/// 不在 `init` 里查：它是设置页的 `@State` 初值，SwiftUI 每次重建视图都会再跑一遍初值表达式，
/// 在那里等 tccd 会让设置窗口每次刷新都卡几十毫秒。由视图在 `.task` 里调 `refresh()`。
///
/// 查的是被控端的授权（`RemoteHostPermissionSource`）：远控进程在服务时问它，否则问本进程。
@MainActor
@Observable
final class RemoteDesktopPermissionState {
    private(set) var screenCapture = false
    private(set) var postEvents = false
    /// 第一次查询回来之前不显示授权按钮，免得已授权的用户先看到一闪而过的「授权」。
    private(set) var isLoaded = false
    /// 用户在这次运行里点过「授权」：系统设置里打开之后要重启才生效。
    private(set) var requestedThisRun = false
    /// 远控进程（没有时为 nil）。由视图在查询前交进来：`RemoteHostServer.agent` 在 App 启动后才接上。
    @ObservationIgnored var agent: (any RemoteHostAgentLink)?
    /// 切回前台和点按钮都会触发查询，可能叠在一起；只认最后一次发起的结果。
    @ObservationIgnored private var generation = 0

    func refresh() async {
        generation += 1
        let current = generation
        let permissions = await RemoteHostPermissionSource.current(agent: agent)
        guard current == generation else { return }
        // 值没变就不写：`@Observable` 对同值赋值也会通知，整页会白白重算。
        if screenCapture != permissions.screenCapture { screenCapture = permissions.screenCapture }
        if postEvents != permissions.postEvents { postEvents = permissions.postEvents }
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
            await RemoteHostPermissionSource.requestPostEvents(agent: agent)
            await refresh()
        }
    }
}
