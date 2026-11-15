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
        /// 在它现有的模式里切到要的 2 倍模式。
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

    /// 开流前：无显示器的 Mac 建（或改）一块按 `viewerPixels` 来的 2 倍虚拟屏，等它就绪再返回（最多 3 秒）。
    /// 接着真显示器时不动。
    static func ensureHiDPI(viewerPixels: (width: Int, height: Int)? = nil, pointScale: Double? = nil) async {
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
        guard let (main, current, count) = await awakeMainDisplay() else {
            AppLogger.notice("远程桌面：主屏 3 秒内没醒来或读不到模式，没准备虚拟屏", category: RemoteLog.category)
            return
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
        await RemoteDisplayWake.wake(display: CGMainDisplayID())
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
    private static func selectHiDPIMode(_ id: CGDirectDisplayID, size: VirtualSize) {
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
    private static func makeVirtualDisplay(size: VirtualSize, maxPixels: (width: Int, height: Int)) -> NSObject? {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type else { return nil }
        let descriptor = descriptorClass.init()
        descriptor.setValue(String(localized: "uTerm 远程显示器"), forKey: "name")
        descriptor.setValue(maxPixels.width, forKey: "maxPixelsWide")
        descriptor.setValue(maxPixels.height, forKey: "maxPixelsHigh")
        // 27 英寸 16:9 的物理尺寸：系统按它算像素密度，配合 2 倍模式显示为视网膜。不随尺寸变：
        // 物理尺寸大得离谱时 WindowServer 不收（Lumen 的注释）。
        descriptor.setValue(NSValue(size: NSSize(width: 597, height: 336)), forKey: "sizeInMillimeters")
        // 厂商、型号、序列号固定：系统按它们认出「还是那块屏」，记得上面的窗口摆法。
        descriptor.setValue(virtualVendor, forKey: "vendorID")
        descriptor.setValue(virtualModel, forKey: "productID")
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
