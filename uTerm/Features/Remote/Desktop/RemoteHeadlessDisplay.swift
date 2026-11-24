import AppKit
import CoreGraphics
import Foundation
import ObjectiveC

/// 没接显示器的 Mac：系统给一块占位屏（厂商号 'unkn'、型号 'virt'），只有 1920×1080 的 1 倍模式，远程看过去
/// 文字又粗又糊。远程桌面开流前把它换成视网膜的：
///
/// - 建一块**按看的那台设备的宽高比**来的 2 倍虚拟屏（私有类 `CGVirtualDisplay`，沙盒里可用，调研 §16；
///   做法同 Sunshine 的 macOS 分支 Lumen）：宽高比对得上，不再把 16:9 的屏塞进 16:10 或手机的框里留黑边。
///   手机报来的比例是它放画面的那块画布的（顶栏下面），不是整块屏幕的。
///   点数按看的设备自己的点数来（它报的像素除以它的像素倍数）：MacBook、iPad、带外接屏的 Mac 看到的桌面和
///   自己的屏幕一样大，像素正好等于视频尺寸，采集直接出 4:2:0、不用再缩。太小的设备（Duo、手机）等比放大到
///   1280×800 点的下限（窗口、菜单栏放得下），采集比视频大，由采集源再缩一截。原先下限是 1920×1080，Duo 上
///   成了 1920×1241 点，界面只有手机上一半大（2026-11-15 user：按设备的尺寸、适当放大）。
///   它一出现，系统就撤掉占位屏，它成为唯一的主屏。
/// - 换了一台设备来看：新尺寸没超过这块屏建时定的上限就只换模式（同一块屏、同一个显示器号，窗口留在原处，
///   系统只按新尺寸把放不下的挪进来）；超了才拆掉重建。
/// - 最后一个人走了：等一会儿（`releaseGrace`）还没人来再拆，免得断线重连、换设备接管时窗口来回搬。
///   接上真显示器时立刻拆掉，不然那块看不见的屏会成为扩展屏，窗口和光标都能跑进去。
/// - 建不了虚拟屏（系统不支持）时退回老办法：占位屏自己带同点数的 2 倍模式就用公开 API 换过去。
///
/// 接着真显示器（或不止一块屏）时一律不碰。
///
/// 系统「屏幕共享」以高性能模式连着时，它会建一块独占的虚拟屏（厂商号 'aapl'、型号 0x1234）：别的显示器
/// （包括我们的虚拟屏）一律被断开，而那块屏 ScreenCaptureKit 又采不到。这时什么都做不了，只能如实告诉对方。
@MainActor
enum RemoteHeadlessDisplay {
    /// 'unkn'：无显示器时系统占位屏的厂商号；型号是 'virt'。
    nonisolated static let placeholderVendor: UInt32 = 0x756E_6B6E
    nonisolated static let placeholderModel: UInt32 = 0x7669_7274
    /// 系统「屏幕共享」建的独占虚拟屏：厂商号 'aapl'、型号 0x1234。
    nonisolated static let screenSharingVendor: UInt32 = 0x6161_706C
    nonisolated static let screenSharingModel: UInt32 = 0x1234
    /// 我们建的虚拟屏的厂商号与型号（序列号固定 1）：系统按它们认出「还是那块屏」。
    nonisolated static let virtualVendor: UInt32 = 0x7554
    nonisolated static let virtualModel: UInt32 = 0x0001
    /// 不知道看的设备多大时（老客户端）虚拟屏的点数：与占位屏一样。
    nonisolated static let defaultPoints = (width: 1920, height: 1080)
    /// 虚拟屏点数的下限与上限：太小了窗口和菜单栏放不下，太大的像素 WindowServer 不收。
    /// 下限 1280×800（老款 13 寸 MacBook 的大小）：Duo 内屏 → 1280×828，iPhone 横屏 → 约 2020×800。
    nonisolated static let minimumPoints = (width: 1280, height: 800)
    /// 老的主控端不报像素倍数（`RemoteDesktopStartRequest.pointScale`）：照原来的规则，按 2 倍算、下限 1920×1080。
    nonisolated static let legacyMinimumPoints = (width: 1920, height: 1080)
    nonisolated static let maximumPoints = (width: 3840, height: 2160)
    /// 建屏时像素上限至少给到这么大：之后换一台不超过它的设备来看只换模式、不重建。
    /// 5120×2880：盖住 5K 屏的 Mac、iPad 13（约 2920×2064）、MacBook（3024×1964…）、iPhone 横屏（约 4040×1600；
    /// 老的主控端按老下限是约 4694×2160）。
    nonisolated static let minimumMaxPixels = (width: 5120, height: 2880)
    /// 主屏是不归本进程管的 uTerm 虚拟屏时，等它被系统撤掉最多多久（见 `ensureHiDPI`）。实测醒来后 23 ms 就撤。
    nonisolated static let orphanWithdrawalLimit: Duration = .milliseconds(600)
    /// 最后一个人走后多久拆虚拟屏。
    nonisolated static let releaseGrace: Duration = .seconds(30)

    /// 虚拟屏的一种尺寸：点数，像素是它的 2 倍。
    nonisolated struct VirtualSize: Equatable, Sendable {
        var width: Int
        var height: Int
        var pixelWidth: Int { width * 2 }
        var pixelHeight: Int { height * 2 }
    }

    /// 已建的虚拟屏：现在的尺寸和建时定的像素上限。
    nonisolated struct VirtualState: Equatable, Sendable {
        var size: VirtualSize
        var maxPixelWidth: Int
        var maxPixelHeight: Int
    }

    nonisolated enum VirtualChange: Equatable, Sendable {
        case keep
        /// 同一块屏换个模式。
        case switchMode
        /// 新尺寸超过上限：拆掉重建。
        case rebuild
    }

    /// 看的设备要的像素（与方向无关）→ 虚拟屏的点数。Mac 的屏总是横的：长边做宽。点数先取那台设备自己的
    /// 点数（像素除以它的像素倍数 `pointScale`），哪一边不到下限就整体等比放大到够（宽高比照旧，不拉变形），
    /// 再夹在上限之内；不知道多大（nil）时与占位屏同大。`pointScale` 为 nil（老的主控端）按 2 倍、老下限算。
    nonisolated static func virtualSize(viewerPixels: (width: Int, height: Int)?, pointScale: Double? = nil) -> VirtualSize {
        guard let viewerPixels, viewerPixels.width > 0, viewerPixels.height > 0 else {
            return VirtualSize(width: defaultPoints.width, height: defaultPoints.height)
        }
        let scale = pointScale.map { $0.isFinite ? min(4, max(1, $0)) : 2 } ?? 2
        let minimumPoints = pointScale == nil ? legacyMinimumPoints : minimumPoints
        let long = Double(max(viewerPixels.width, viewerPixels.height)) / scale
        let short = Double(min(viewerPixels.width, viewerPixels.height)) / scale
        let grow = max(1, Double(minimumPoints.width) / long, Double(minimumPoints.height) / short)
        return VirtualSize(width: min(maximumPoints.width, Int((long * grow).rounded())),
                           height: min(maximumPoints.height, Int((short * grow).rounded())))
    }

    /// 建屏时的像素上限：至少 `minimumMaxPixels`，要的更大就按要的。
    nonisolated static func maxPixels(for size: VirtualSize) -> (width: Int, height: Int) {
        (max(minimumMaxPixels.width, size.pixelWidth), max(minimumMaxPixels.height, size.pixelHeight))
    }

    /// 已有虚拟屏、又来了一台要 `wanted` 的设备：不动、换模式还是重建。
    nonisolated static func change(from current: VirtualState, to wanted: VirtualSize) -> VirtualChange {
        if current.size == wanted { return .keep }
        return wanted.pixelWidth <= current.maxPixelWidth && wanted.pixelHeight <= current.maxPixelHeight
            ? .switchMode : .rebuild
    }

    nonisolated struct Mode: Equatable, Sendable {
        var width: Int
        var height: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var usable = true
    }

    nonisolated enum Plan: Equatable, Sendable {
        case none
        /// 换成占位屏自己的 2 倍模式（`available` 里的下标）。
        case switchMode(Int)
        /// 建一块 2 倍虚拟屏。
        case createVirtual
        /// 主屏是 uTerm 自己的虚拟屏，可这个进程手上没有它：上一个远控进程建的，进程结束了屏却没撤
        ///（2026-11-15/16 真机两次实测：换包、重启远控进程后它都留着）。改不了它的设置，只能用公开接口
        /// 在它现有的模式里切到要的 2 倍模式。睡着时放掉的那种醒来就会被撤，`ensureHiDPI` 先等它撤，
        /// 等不到才走这里。
        case adoptOrphan
    }

    /// 无显示器的 Mac 该怎么变清晰。只看唯一一块在线、非内建的占位屏。能建虚拟屏就建（它按看的设备的像素来，
    /// 占位屏自己的 2 倍模式只有 16:9 一种）；建不了时，当前 1 倍、又带同点数 2 倍模式的就换过去。
    nonisolated static func plan(vendor: UInt32, model: UInt32, builtin: Bool, onlineDisplays: Int,
                                 current: Mode, available: [Mode], canCreateVirtual: Bool = true) -> Plan {
        guard onlineDisplays == 1, !builtin else { return .none }
        if vendor == virtualVendor, model == virtualModel { return .adoptOrphan }
        guard vendor == placeholderVendor, model == placeholderModel else { return .none }
        if canCreateVirtual { return .createVirtual }
        if let index = hiDPIUpgrade(current: current, available: available) { return .switchMode(index) }
        return .none
    }

    /// 现在是 1 倍时，同点数的 2 倍模式在 `available` 里的下标；已经是 2 倍或没有这样的模式时为 nil。
    nonisolated static func hiDPIUpgrade(current: Mode, available: [Mode]) -> Int? {
        guard current.pixelWidth == current.width else { return nil }
        return available.firstIndex { mode in
            mode.usable && mode.width == current.width && mode.height == current.height
                && mode.pixelWidth == 2 * mode.width && mode.pixelHeight == 2 * mode.height
        }
    }

    /// 虚拟屏建好 / 换了模式之后，该切到的那个 2 倍模式在 `available` 里的下标；已经是它、或者没有它时为 nil。
    ///
    /// 设置里只给了一个模式，系统却会按物理尺寸自己生成一串缩放模式，再挑一个当默认：点数大的（1920×1230）
    /// 默认就是 2 倍，点数小的会挑同像素的 1 倍模式（2026-11-16 mini：要 1280×828 点，系统给的是 2560×1656 点
    /// 的 1 倍，界面小一半）。所以建屏后明确切过去。
    nonisolated static func hiDPIMode(for size: VirtualSize, current: Mode, available: [Mode]) -> Int? {
        func matches(_ mode: Mode) -> Bool {
            mode.width == size.width && mode.height == size.height
                && mode.pixelWidth == size.pixelWidth && mode.pixelHeight == size.pixelHeight
        }
        guard !matches(current) else { return nil }
        return available.firstIndex { $0.usable && matches($0) }
    }

    /// 系统「屏幕共享」的独占虚拟屏正在线：这时屏幕采集一定找不到显示器。
    nonisolated static func screenSharingHoldsDisplay() -> Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).contains {
            CGDisplayVendorNumber($0) == screenSharingVendor && CGDisplayModelNumber($0) == screenSharingModel
        }
    }

    /// 建出来的虚拟屏。持有它，屏幕就在；放掉它，屏幕就撤。
    private static var virtualDisplay: NSObject?
    /// 本进程此刻管着一块顶替占位屏的虚拟屏（这台 Mac 没接显示器）。
    static var ownsVirtualDisplay: Bool { virtualDisplay != nil }
    private static var virtualDisplayID: CGDirectDisplayID = 0
    private static var virtualState: VirtualState?
    private static var watchesReconfiguration = false
    /// 最后一个人走后排着的拆屏。又有人来看就取消。
    private static var pendingRelease: Task<Void, Never>?

    /// 虚拟屏在线时出现了别的真显示器：该把虚拟屏拆掉。占位屏与「屏幕共享」的独占屏不算（前者在虚拟屏
    /// 在时不出现，后者会把虚拟屏暂时断开、走了还会接回来）。
    nonisolated static func realDisplayAppeared(ours: CGDirectDisplayID,
                                                online: [(id: CGDirectDisplayID, vendor: UInt32, model: UInt32)])
        -> Bool {
        online.contains { display in
            display.id != ours
                && !(display.vendor == placeholderVendor && display.model == placeholderModel)
                // 上一个远控进程留下的那块（见 `Plan.adoptOrphan`）不是真显示器。
                && !(display.vendor == virtualVendor && display.model == virtualModel)
                // 窗口模式自己建的那块（`RemoteWindowStage`）也不是真显示器。
                && !(display.vendor == virtualVendor && display.model == RemoteWindowStage.model)
                && !(display.vendor == screenSharingVendor && display.model == screenSharingModel)
        }
    }

    private static func onlineDisplays() -> [(id: CGDirectDisplayID, vendor: UInt32, model: UInt32)] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { ($0, CGDisplayVendorNumber($0), CGDisplayModelNumber($0)) }
    }

    /// 接上了真显示器：拆掉虚拟屏。
    private static func releaseIfRealDisplayAppeared() {
        guard virtualDisplay != nil, realDisplayAppeared(ours: virtualDisplayID, online: onlineDisplays()) else {
            return
        }
        dropVirtualDisplay()
        AppLogger.info("远程桌面：接上了显示器，拆掉 2 倍虚拟屏", category: RemoteLog.category)
    }

    private static func dropVirtualDisplay() {
        virtualDisplay = nil
        virtualDisplayID = 0
        virtualState = nil
    }

    /// 又有人在看了：取消排着的拆屏。
    static func cancelRelease() {
        pendingRelease?.cancel()
        pendingRelease = nil
    }

    /// 没人看了：过 `releaseGrace` 还没人来就拆掉虚拟屏（系统接回 1 倍占位屏）。没建虚拟屏时什么都不做。
    static func scheduleRelease(after grace: Duration = releaseGrace) {
        pendingRelease?.cancel()
        guard virtualDisplay != nil else { return }
        pendingRelease = Task { @MainActor in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, virtualDisplay != nil else { return }
            pendingRelease = nil
            dropVirtualDisplay()
            AppLogger.info("远程桌面：没人看了，拆掉虚拟屏", category: RemoteLog.category)
        }
    }

    private static func watchReconfiguration() {
        guard !watchesReconfiguration else { return }
        watchesReconfiguration = true
        CGDisplayRegisterReconfigurationCallback(Self.reconfigured, nil)
    }

    /// 显示器配置变了（接上了真显示器）。回调在主线程的 run loop 上来，但不保证；拆屏放回主线程做。
    /// 必须是 nonisolated：内联写在本类型（`@MainActor`）里的闭包会被推断成主线程隔离、进入时检查执行者，
    /// 哪天系统在别的线程上调它就会崩（同远程桌面声音的播放回调，ebd13a48）。
    nonisolated static let reconfigured: CGDisplayReconfigurationCallBack = { _, flags, _ in
        guard flags.contains(.addFlag) || flags.contains(.enabledFlag) else { return }
        Task { @MainActor in RemoteHeadlessDisplay.releaseIfRealDisplayAppeared() }
    }

    /// 正在做的那次 `ensureHiDPI`。一次只做一个：预建（`prewarm`）还没做完时开流来了，排在它后面，免得两边各建一块屏。
    private static var preparing: Task<Void, Never>?

    /// 开流前：无显示器的 Mac 建（或改）一块按 `viewerPixels` 来的 2 倍虚拟屏，等它就绪再返回（最多 3 秒）。
    /// 接着真显示器时不动。
    static func ensureHiDPI(viewerPixels: (width: Int, height: Int)? = nil, pointScale: Double? = nil) async {
        let previous = preparing
        let task = Task { @MainActor in
            await previous?.value
            await prepare(viewerPixels: viewerPixels, pointScale: pointScale)
        }
        preparing = task
        await task.value
    }

    /// 只看在线的显示器（不叫醒它）：是不是一块无显示器时的占位屏或 uTerm 自己的虚拟屏。
    nonisolated static func looksHeadless(_ online: [(id: CGDirectDisplayID, vendor: UInt32, model: UInt32)]) -> Bool {
        guard online.count == 1, let only = online.first else { return false }
        return (only.vendor == placeholderVendor && only.model == placeholderModel)
            || (only.vendor == virtualVendor && only.model == virtualModel)
    }

    /// 看过屏幕的设备又连上来：无显示器的 Mac 按它上次要的尺寸先把虚拟屏准备好，等它点开屏幕时不用再等
    /// 叫醒、撤屏、建屏这几百毫秒（2026-11-16 mini：冷开屏「准备显示器」361 ms）。接着真显示器、或者不止一块屏时
    /// 什么都不做（也不叫醒屏幕）。之后没人开流的话，照常由调用方排上拆屏。
    static func prewarm(viewerPixels: (width: Int, height: Int), pointScale: Double?) async {
        guard looksHeadless(onlineDisplays()) else { return }
        await ensureHiDPI(viewerPixels: viewerPixels, pointScale: pointScale)
    }

    private static func prepare(viewerPixels: (width: Int, height: Int)?, pointScale: Double?) async {
        cancelRelease()
        releaseIfRealDisplayAppeared()
        let wanted = virtualSize(viewerPixels: viewerPixels, pointScale: pointScale)
        if let state = virtualState, virtualDisplay != nil {
            switch change(from: state, to: wanted) {
            case .keep:
                return
            case .switchMode:
                if await switchVirtualMode(to: wanted) { return }
                // 换不过去（系统不收这个模式）：重建。
                dropVirtualDisplay()
                await createVirtualDisplay(size: wanted)
                return
            case .rebuild:
                dropVirtualDisplay()
                await waitForPlaceholder()
                await createVirtualDisplay(size: wanted)
                return
            }
        }
        // 拆掉虚拟屏后占位屏会睡着；睡着的屏读不到模式，原先这里直接放弃、不建虚拟屏，开流去采一块睡着的屏，
        // 手机上报「没有可用的屏幕」，再连一次才好（2026-11-09 mini：拆屏一分钟后再连，准备显示器 2 ms 就返回）。
        // 先叫醒，等系统报出主屏的模式再判断。
        guard var (main, current, count) = await awakeMainDisplay() else {
            AppLogger.notice("远程桌面：主屏 3 秒内没醒来或读不到模式，没准备虚拟屏", category: RemoteLog.category)
            return
        }
        // 主屏是 uTerm 的虚拟屏、可这个进程手上没有它：多半是睡着时被放掉的（本进程没人看了拆屏时它睡着，
        // 或建它的进程结束了），系统要等它醒来才真正撤掉。醒来那一刻它还报在线、醒着，二十来毫秒后才被撤、
        // 换回新号的占位屏（2026-11-16 mini：0x15 醒来后 23 ms 被撤；照它判断去「接手」，开流采的是一块已经
        // 没了的屏，手机 2.4 秒后报「找不到要采集的显示器」再重试）。先等一下，撤了就按新的主屏判断。
        if CGDisplayVendorNumber(main) == virtualVendor, CGDisplayModelNumber(main) == virtualModel,
           await waitForWithdrawal(of: main), let settled = await awakeMainDisplay() {
            AppLogger.notice("远程桌面：放掉的虚拟屏醒来后撤了，按新的主屏准备", category: RemoteLog.category)
            (main, current, count) = settled
        }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(main, options) as? [CGDisplayMode]) ?? []
        switch plan(vendor: CGDisplayVendorNumber(main), model: CGDisplayModelNumber(main),
                    builtin: CGDisplayIsBuiltin(main) != 0, onlineDisplays: Int(count),
                    current: mode(current), available: modes.map(mode),
                    canCreateVirtual: NSClassFromString("CGVirtualDisplay") != nil) {
        case .none:
            return
        case .adoptOrphan:
            AppLogger.notice("远程桌面：主屏是上一个远控进程留下的虚拟屏（\(CGDisplayPixelsWide(main))×\(CGDisplayPixelsHigh(main))），"
                             + "接着用，切到 \(wanted.width)×\(wanted.height) 点的 2 倍", category: RemoteLog.category)
            selectHiDPIMode(main, size: wanted)
        case .switchMode(let index):
            switchMode(main, to: modes[index])
        case .createVirtual:
            if await createVirtualDisplay(size: wanted) { return }
            // 建不了：退回占位屏自己的 2 倍模式（有的话）。
            if let index = hiDPIUpgrade(current: mode(current), available: modes.map(mode)) {
                switchMode(main, to: modes[index])
            }
        }
    }

    /// 叫醒主屏，等它醒着、读得到模式（最多约 3 秒）。返回主屏、它的模式和在线屏数；等不到时 nil。
    private static func awakeMainDisplay() async -> (CGDirectDisplayID, CGDisplayMode, UInt32)? {
        // 这里只为读占位屏的模式，不采它（接着就换成虚拟屏），不用等它能被采集。
        await RemoteDisplayWake.wake(display: CGMainDisplayID(), untilCapturable: false)
        for attempt in 0..<30 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }
            var count: UInt32 = 0
            CGGetOnlineDisplayList(0, nil, &count)
            let main = CGMainDisplayID()
            guard count > 0, CGDisplayIsAsleep(main) == 0, let mode = CGDisplayCopyDisplayMode(main) else {
                if attempt % 10 == 9 { RemoteDisplayWake.nudge() }
                continue
            }
            return (main, mode, count)
        }
        return nil
    }

    /// 等 `display` 从在线的显示器里撤掉（最多 `orphanWithdrawalLimit`）。撤了返回 true；一直在就是真留下来的那块。
    private static func waitForWithdrawal(of display: CGDirectDisplayID) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + orphanWithdrawalLimit
        while clock.now < deadline {
            if !onlineDisplays().contains(where: { $0.id == display }) || CGMainDisplayID() != display { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    /// 拆了旧屏要等系统把占位屏接回来，再建新的；不然两块屏的配置变化叠在一起，窗口会被搬两遍（最多 2 秒）。
    private static func waitForPlaceholder() async {
        for _ in 0..<40 {
            let main = CGMainDisplayID()
            if CGDisplayVendorNumber(main) == placeholderVendor, CGDisplayModelNumber(main) == placeholderModel { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func switchMode(_ display: CGDirectDisplayID, to target: CGDisplayMode) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        guard CGConfigureDisplayWithDisplayMode(config, display, target, nil) == .success,
              CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            CGCancelDisplayConfiguration(config)
            AppLogger.info("远程桌面：没能把无显示器的占位屏换成 2 倍", category: RemoteLog.category)
            return
        }
        AppLogger.info("远程桌面：无显示器，占位屏换成 \(target.width)×\(target.height) 的 2 倍模式",
                       category: RemoteLog.category)
    }

    @discardableResult
    private static func createVirtualDisplay(size: VirtualSize) async -> Bool {
        let limit = maxPixels(for: size)
        guard let display = makeVirtualDisplay(size: size, maxPixels: limit) else {
            AppLogger.info("远程桌面：无显示器，没能建 \(size.pixelWidth)×\(size.pixelHeight) 的虚拟屏（系统不支持？）",
                           category: RemoteLog.category)
            return false
        }
        virtualDisplay = display
        let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
        virtualDisplayID = id
        virtualState = VirtualState(size: size, maxPixelWidth: limit.width, maxPixelHeight: limit.height)
        watchReconfiguration()
        // 系统要一会儿才撤掉占位屏、把虚拟屏设成主屏；在那之前开流会采到旧屏。
        var waited = 0
        while CGMainDisplayID() != id, waited < 60 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        let ready = CGMainDisplayID() == id
        AppLogger.notice("远程桌面：无显示器，建了 \(size.width)×\(size.height) 点（\(size.pixelWidth)×\(size.pixelHeight) 像素）的虚拟屏"
                         + (ready ? "" : "（还没成为主屏）"), category: RemoteLog.category)
        selectHiDPIMode(id, size: size)
        return true
    }

    /// 把虚拟屏切到 `size` 的 2 倍模式（见 `hiDPIMode`）。已经是了就不动。
    fileprivate static func selectHiDPIMode(_ id: CGDirectDisplayID, size: VirtualSize) {
        guard let current = CGDisplayCopyDisplayMode(id) else { return }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        guard let index = hiDPIMode(for: size, current: mode(current), available: modes.map(mode)) else {
            if current.pixelWidth != 2 * current.width {
                AppLogger.notice("远程桌面：虚拟屏现在是 \(current.width)×\(current.height) 点的 1 倍，找不到 \(size.width)×\(size.height) 点的 2 倍模式",
                                 category: RemoteLog.category)
            }
            return
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        guard CGConfigureDisplayWithDisplayMode(config, id, modes[index], nil) == .success,
              CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            CGCancelDisplayConfiguration(config)
            AppLogger.notice("远程桌面：虚拟屏没能从 \(current.width)×\(current.height) 点切到 \(size.width)×\(size.height) 点的 2 倍",
                             category: RemoteLog.category)
            return
        }
        AppLogger.notice("远程桌面：虚拟屏从 \(current.width)×\(current.height) 点（\(current.pixelWidth) 像素宽）切到 \(size.width)×\(size.height) 点的 2 倍",
                         category: RemoteLog.category)
    }

    /// 同一块虚拟屏换个模式：显示器号不变，窗口留在这块屏上。等系统报出新的像素尺寸再返回（最多 3 秒）。
    private static func switchVirtualMode(to size: VirtualSize) async -> Bool {
        guard let display = virtualDisplay, let settings = virtualSettings(size: size),
              applySettings(settings, to: display) else {
            AppLogger.info("远程桌面：虚拟屏换不到 \(size.width)×\(size.height) 点", category: RemoteLog.category)
            return false
        }
        virtualState?.size = size
        let id = virtualDisplayID
        var waited = 0
        while waited < 60 {
            if let mode = CGDisplayCopyDisplayMode(id), mode.pixelWidth == size.pixelWidth,
               mode.pixelHeight == size.pixelHeight { break }
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        AppLogger.notice("远程桌面：虚拟屏换成 \(size.width)×\(size.height) 点（\(size.pixelWidth)×\(size.pixelHeight) 像素）"
                         + (waited < 60 ? "" : "（系统还没报出新尺寸）"), category: RemoteLog.category)
        selectHiDPIMode(id, size: size)
        return true
    }

    /// 经 ObjC 运行时建 `CGVirtualDisplay`：描述符 → 显示器 → 设置（hiDPI + 一个模式）。任何一步对不上返回 nil。
    fileprivate static func makeVirtualDisplay(size: VirtualSize, maxPixels: (width: Int, height: Int),
                                               name: String = String(localized: "uTerm 远程显示器"),
                                               model: UInt32 = virtualModel) -> NSObject? {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type else { return nil }
        let descriptor = descriptorClass.init()
        descriptor.setValue(name, forKey: "name")
        descriptor.setValue(maxPixels.width, forKey: "maxPixelsWide")
        descriptor.setValue(maxPixels.height, forKey: "maxPixelsHigh")
        // 27 英寸 16:9 的物理尺寸：系统按它算像素密度，配合 2 倍模式显示为视网膜。不随尺寸变：
        // 物理尺寸大得离谱时 WindowServer 不收（Lumen 的注释）。
        descriptor.setValue(NSValue(size: NSSize(width: 597, height: 336)), forKey: "sizeInMillimeters")
        // 厂商、型号、序列号固定：系统按它们认出「还是那块屏」，记得上面的窗口摆法。
        descriptor.setValue(virtualVendor, forKey: "vendorID")
        descriptor.setValue(model, forKey: "productID")
        descriptor.setValue(1, forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        let alloc = NSSelectorFromString("alloc")
        let initDisplay = NSSelectorFromString("initWithDescriptor:")
        guard displayClass.instancesRespond(to: initDisplay),
              let allocated = (displayClass as AnyObject).perform(alloc)?.takeUnretainedValue(),
              // init 系列返回的是 +1：按 retained 接，放掉 `virtualDisplay` 时它才真的释放、屏幕才撤。
              let display = allocated.perform(initDisplay, with: descriptor)?.takeRetainedValue() as? NSObject,
              let settings = virtualSettings(size: size), applySettings(settings, to: display)
        else { return nil }
        return display
    }

    /// 一个模式的设置：hiDPI，模式按点给（像素是 2 倍，受建屏时的像素上限约束）。
    private static func virtualSettings(size: VirtualSize) -> NSObject? {
        guard let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type else { return nil }
        let alloc = NSSelectorFromString("alloc")
        let initMode = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let modeMethod = class_getInstanceMethod(modeClass, initMode),
              let modeAllocated = (modeClass as AnyObject).perform(alloc)?.takeUnretainedValue() else { return nil }
        typealias InitMode = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>
        let mode = unsafeBitCast(method_getImplementation(modeMethod), to: InitMode.self)(
            modeAllocated, initMode, UInt(size.width), UInt(size.height), 60).takeRetainedValue()
        let settings = settingsClass.init()
        settings.setValue(2, forKey: "hiDPI")
        settings.setValue([mode], forKey: "modes")
        return settings
    }

    private static func applySettings(_ settings: NSObject, to display: NSObject) -> Bool {
        guard let displayClass = NSClassFromString("CGVirtualDisplay"),
              let applyMethod = class_getInstanceMethod(displayClass, NSSelectorFromString("applySettings:")) else {
            return false
        }
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        return unsafeBitCast(method_getImplementation(applyMethod), to: Apply.self)(
            display, NSSelectorFromString("applySettings:"), settings)
    }

    private static func mode(_ mode: CGDisplayMode) -> Mode {
        Mode(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
             usable: mode.isUsableForDesktopGUI())
    }
}

// MARK: - 窗口模式：屏幕放不下时的虚拟屏

/// 窗口模式下，主控端要的窗口大小这台 Mac 的屏幕放不下时（14 寸内建屏 1512×982 点放不下 1426×1003 点的窗口，
/// 竖握时要的 1003×1426 点更放不下），建一块够大的 2 倍虚拟屏，把窗口挪上去再调大小；不看了把窗口放回原处、
/// 拆掉虚拟屏（2026-11-18 user 要的）。
///
/// 和 `RemoteHeadlessDisplay` 的那块不是一回事：那块是没接显示器时顶替占位屏当主屏；这块是接着真显示器时多出来的
/// 一块扩展屏，只放正在被看的窗口，摆在所有显示器的右边。型号不同（`model`），两边互不相认。没接显示器的 Mac
/// 已经有一块按主控端大小建的虚拟屏，不再另建。
///
/// 2026-11-17 探针（macOS 27.2.1）：沙盒里能建；接着真屏时新屏会把别的屏的坐标挤开，建好后要用
/// `CGConfigureDisplayOrigin` 摆到右边；2 倍模式两边都要约 512 点以上。
/// 2026-11-18 探针（同一台，只接内建屏）：
/// - 刚建好落在 **1 倍**模式（要 1426×1486 点，得到的是 2852×2972 点、每点 1 像素），而且这时显示模式还读不到
///   （`CGDisplayCopyDisplayMode` 是空的，空转 3 秒也一样）。**先提交一次显示器配置**（摆位置那次），约 0.4 秒后
///   模式才读得到，这时再切 2 倍才切得上。顺序反了就一直是 1 倍，窗口放上去比不挪还糊。
/// - 切成 2 倍后：`NSScreen` 马上就有，倍数 2，菜单栏高 30 点，可用范围 1426×1456。内建屏的位置没被挤动。
/// - 拆屏 = 对象真正释放。释放后别的进程 2 秒内就看不到它了，但**本进程里 `CGDisplayIsOnline` 还一直报在线**，
///   不能拿它判断拆没拆掉。建屏那几步里有 autorelease 的引用，不包在自动释放池里对象就放不掉。
///
/// 坐在 Mac 前的人会看到这个窗口从屏幕上消失（它在那块看不见的屏上），不看了才回来；这期间鼠标也可能跑进去。
@MainActor
enum RemoteWindowStage {
    nonisolated static let model: UInt32 = 0x0002
    /// 给菜单栏留的高度（点）：窗口不能和菜单栏重叠。
    nonisolated static let menuBarReserve = 60
    /// 虚拟屏每边至少这么多点（2 倍模式的下限之上留些余量）。
    nonisolated static let minimumSide = 640
    /// 最后一个窗口放回去之后多久拆。
    nonisolated static let releaseGrace: Duration = .seconds(3)

    /// 这块屏幕的可用范围放不放得下要的窗口大小。
    nonisolated static func needsStage(fit: CGSize, visible: CGSize) -> Bool {
        fit.width > visible.width + 1 || fit.height > visible.height + 1
    }

    /// 放得下 `fit` 的虚拟屏该多大：正方形加菜单栏的高度，横着竖着的窗口都放得下，转屏时不用重建。
    nonisolated static func stageSize(for fit: CGSize) -> RemoteHeadlessDisplay.VirtualSize {
        let limit = RemoteHeadlessDisplay.maximumPoints
        let side = (max(minimumSide, Int(max(fit.width, fit.height).rounded(.up))) + 1) & ~1
        return RemoteHeadlessDisplay.VirtualSize(width: min(limit.width, side),
                                                 height: min(limit.height, side + menuBarReserve))
    }

    /// 已建的这块放不放得下。
    nonisolated static func holds(_ fit: CGSize, in size: RemoteHeadlessDisplay.VirtualSize) -> Bool {
        Int(fit.width.rounded(.up)) <= size.width && Int(fit.height.rounded(.up)) <= size.height - menuBarReserve
    }

    private static var display: NSObject?
    private static var displayID: CGDirectDisplayID = 0
    private static var size: RemoteHeadlessDisplay.VirtualSize?
    /// 现在放在这块屏上的窗口。
    private static var staged: Set<UInt32> = []
    private static var releaseTask: Task<Void, Never>?

    /// 原地调大小时窗口该放在哪儿：左上角不动；按这个大小会伸出可用范围（下边过了程序坞、右边出了屏幕）就往上 / 往左
    /// 挪到刚好放得下。左上角不动地调，系统会把窗口截在可用范围的下沿：2026-11-24 Duo 横握要 1426×1003 点，
    /// 窗口上沿在 y=354，得到的是 1426×880，手机上画面上下各留一条黑边。都是全局坐标（左上角原点，点）。
    nonisolated static func inPlaceFrame(window: CGRect, fit: CGSize, visible: CGRect) -> CGRect {
        let width = fit.width.rounded(), height = fit.height.rounded()
        var x = window.minX, y = window.minY
        if x + width > visible.maxX { x = max(visible.minX, visible.maxX - width) }
        if y + height > visible.maxY { y = max(visible.minY, visible.maxY - height) }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 把窗口调成 `fit`（点）：屏幕放得下就原地调；放不下就挪到虚拟屏上再调。返回动它之前的位置，没动返回 nil。
    static func fit(id: UInt32, size fit: CGSize) async -> CGRect? {
        guard let entry = RemoteDesktopWindows.entry(id: id) else { return nil }
        if !(staged.contains(id) && display != nil) {
            let visible = visibleFrame(around: entry.bounds)
            guard !RemoteHeadlessDisplay.ownsVirtualDisplay, let visible, needsStage(fit: fit, visible: visible.size) else {
                return await fitInPlace(entry, size: fit, visible: visible)
            }
        }
        guard await ensure(for: fit), let area = usableArea() else {
            AppLogger.notice("远程桌面：屏幕放不下 \(Int(fit.width))×\(Int(fit.height)) 点的窗口，虚拟屏又没建成，只能在原来的屏幕上尽量调",
                             category: RemoteLog.category)
            return await fitInPlace(entry, size: fit, visible: visibleFrame(around: entry.bounds))
        }
        releaseTask?.cancel()
        releaseTask = nil
        staged.insert(id)
        let target = CGRect(x: area.minX, y: area.minY, width: min(fit.width, area.width).rounded(),
                            height: min(fit.height, area.height).rounded())
        let placed = await Task.detached { RemoteDesktopWindows.place(id: id, frame: target) }.value
        return placed ? entry.bounds : nil
    }

    /// 窗口放回原处了：这块屏上没有别的窗口就过一会儿拆掉。
    static func restored(id: UInt32) {
        guard staged.remove(id) != nil, staged.isEmpty, display != nil else { return }
        releaseTask?.cancel()
        releaseTask = Task {
            try? await Task.sleep(for: releaseGrace)
            guard !Task.isCancelled, staged.isEmpty else { return }
            drop()
        }
    }

    private static func drop() {
        guard display != nil else { return }
        // 包在池里：对象上挂着 autorelease 的引用时，光置空放不掉，屏就撤不了。
        autoreleasepool { display = nil }
        displayID = 0
        size = nil
        AppLogger.notice("远程桌面：窗口模式用的虚拟屏拆掉了", category: RemoteLog.category)
    }

    /// 在窗口所在的屏幕上把它调成 `fit`：伸出可用范围时连位置一起改（`inPlaceFrame`），否则左上角不动。
    /// 返回动它之前的位置，没动返回 nil。
    private static func fitInPlace(_ entry: RemoteDesktopWindows.Entry, size fit: CGSize, visible: CGRect?) async -> CGRect? {
        let id = entry.id
        let original: CGRect?
        let target = visible.map { inPlaceFrame(window: entry.bounds, fit: fit, visible: $0) }
        if let target, target.origin != entry.bounds.origin {
            let placed = await Task.detached { RemoteDesktopWindows.place(id: id, frame: target) }.value
            original = placed ? entry.bounds : nil
        } else {
            original = await Task.detached { RemoteDesktopWindows.resize(id: id, to: fit) }.value
        }
        // 没调成要的大小（App 的最小 / 最大尺寸、系统截掉）记一笔：手机上画面会留黑边，排查时先看这一行。
        if let after = RemoteDesktopWindows.entry(id: id)?.bounds,
           abs(after.width - fit.width.rounded()) > 1 || abs(after.height - fit.height.rounded()) > 1 {
            AppLogger.notice("远程桌面：窗口要调成 \(Int(fit.width))×\(Int(fit.height)) 点，实际 \(Int(after.width))×\(Int(after.height))，"
                             + "在 (\(Int(after.minX)), \(Int(after.minY)))", category: RemoteLog.category)
        }
        return original
    }

    /// 窗口所在那块屏幕的可用范围（去掉菜单栏和程序坞），全局坐标（左上角原点，点）。
    private static func visibleFrame(around bounds: CGRect) -> CGRect? {
        // AppKit 的坐标以主屏左下角为原点、向上为正，换成和 `CGWindowList` 一样的左上角原点。
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var best: (area: CGFloat, frame: CGRect)?
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let overlap = CGDisplayBounds(number.uint32Value).intersection(bounds)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            let visible = screen.visibleFrame
            let frame = CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
            if best == nil || area > best!.area { best = (area, frame) }
        }
        return best?.frame
    }

    /// 虚拟屏上能放窗口的范围（全局坐标，左上角原点）。系统还没把它报成 `NSScreen` 时按预留的菜单栏高度估。
    private static func usableArea() -> CGRect? {
        guard display != nil, displayID != 0 else { return nil }
        let bounds = CGDisplayBounds(displayID)
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        guard let screen else {
            return CGRect(x: bounds.minX, y: bounds.minY + CGFloat(menuBarReserve), width: bounds.width,
                          height: bounds.height - CGFloat(menuBarReserve))
        }
        // AppKit 的坐标左下角原点：可用范围上沿离屏幕上沿多远就是菜单栏多高。
        let top = screen.frame.maxY - screen.visibleFrame.maxY
        let left = screen.visibleFrame.minX - screen.frame.minX
        return CGRect(x: bounds.minX + left, y: bounds.minY + top, width: screen.visibleFrame.width,
                      height: screen.visibleFrame.height)
    }

    /// 备好一块放得下 `fit` 的虚拟屏。已有的不够大就拆了重建。
    private static func ensure(for fit: CGSize) async -> Bool {
        // 不问 `CGDisplayIsOnline`：本进程里它报的是旧值（见类型注释）。对象还在手里就是还在。
        if display != nil, let size, holds(fit, in: size) { return true }
        if display != nil { drop() }
        let wanted = stageSize(for: fit)
        guard holds(fit, in: wanted) else { return false }
        // 新屏一出现，系统会把别的屏的位置挤开：先记下，建好再摆回去。
        let others = onlineDisplays().map { ($0, CGDisplayBounds($0).origin) }
        let limit = RemoteHeadlessDisplay.maxPixels(for: wanted)
        let name = String(localized: "uTerm 窗口模式")
        var created: NSObject?
        var id: CGDirectDisplayID = 0
        autoreleasepool {
            created = RemoteHeadlessDisplay.makeVirtualDisplay(size: wanted, maxPixels: limit, name: name, model: model)
            id = (created?.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0
        }
        guard let created, id != 0 else { return false }
        display = created
        displayID = id
        size = wanted
        var waited = 0
        while CGDisplayIsOnline(id) == 0, waited < 40 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        guard CGDisplayIsOnline(id) != 0 else {
            drop()
            return false
        }
        // 先摆位置（提交一次显示器配置），模式才读得到；读到了再切 2 倍，等它生效（探针：前后约 0.5 秒）。
        arrange(stage: id, others: others)
        var isHiDPI = false
        waited = 0
        while waited < 60 {
            if let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 {
                if mode.width == wanted.width, mode.pixelWidth == 2 * mode.width {
                    isHiDPI = true
                    break
                }
                if waited % 4 == 0 { RemoteHeadlessDisplay.selectHiDPIMode(id, size: wanted) }
            }
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        guard isHiDPI else {
            // 每点只有 1 个像素的屏，窗口放上去比留在原来的屏上还糊：不用它。
            AppLogger.notice("远程桌面：窗口模式的虚拟屏没切上 2 倍模式，拆掉，窗口留在原来的屏幕上", category: RemoteLog.category)
            drop()
            return false
        }
        // 等系统把它报成 NSScreen（菜单栏多高要问它），最多约 1.5 秒。
        waited = 0
        while waited < 30, !NSScreen.screens.contains(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        let bounds = CGDisplayBounds(id)
        AppLogger.notice("远程桌面：屏幕放不下要的窗口，建了 \(wanted.width)×\(wanted.height) 点的虚拟屏，摆在 x=\(Int(bounds.minX))",
                         category: RemoteLog.category)
        return true
    }

    /// 别的屏放回原来的位置，虚拟屏摆到它们的右边。
    private static func arrange(stage: CGDirectDisplayID, others: [(CGDirectDisplayID, CGPoint)]) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        var right: CGFloat = 0
        for (id, origin) in others where CGDisplayIsOnline(id) != 0 {
            CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
            right = max(right, origin.x + CGDisplayBounds(id).width)
        }
        CGConfigureDisplayOrigin(config, stage, Int32(right), 0)
        if CGCompleteDisplayConfiguration(config, .forSession) != .success { CGCancelDisplayConfiguration(config) }
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }
}
