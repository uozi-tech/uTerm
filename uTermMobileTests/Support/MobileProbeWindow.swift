import SwiftUI
import UIKit

/// iOS 探针的建窗夹具 —— 对应桌面 `uTermTests/Support/ProbeWindow.swift`
/// （uTerm commit `2791b0b5`，那份又抄自 uTable `bba891b`）。
///
/// **不是逐行移植**：两个平台的「真窗口」含义差得远。桌面那份要解决的问题在 iOS 上
/// 有的不存在、有的换了形态：
///
/// - **不用躲用户的鼠标**。桌面探针得把窗口做成 `alphaValue = 0` 的屏内窗、再断言
///   `blindsRealMouse`，否则真光标会点亮 `.onHover` 把读数染红（桌面那份顶部有整整
///   一节实测数据）。模拟器里没有会飘进来的真光标，SwiftUI iOS 也没有 `.onHover`
///   这条路径 —— 所以 `blindsRealMouse` / `fakedMouseLocation` / `mouseBlindOrigin`
///   **整套都没搬**。iOS 侧的对应问题是**触摸合成**，见 `MobileProbeRig` 的滚动驱动。
/// - **不用留 `terminationAnchor`**。`uTermApp` 是纯 SwiftUI `WindowGroup`，最后一个
///   窗口一消失宿主进程就 `exit(0)`；`MobileApp` 走 `UIApplicationMain`，宿主
///   `UIWindow` 由系统 scene 持有，我们建的窗拆光也不会让进程没。
/// - **`isolateHostWindows` 换成压层级而不是卸窗**。桌面那边直接 `orderOut` 宿主窗口；
///   iOS 上拆掉宿主窗口会连带带走 SwiftData 的 `ModelContainer` 环境（README 坑⑤），
///   所以 `isolateHost` 只把宿主窗口的 `windowLevel` 压到我们下面，`closeAll()` 复原。
///
/// ## 三档摆法（语义对齐桌面）
///
/// | 档 | iOS 做法 | 给谁用 |
/// |---|---|---|
/// | `.offScreen` | frame 挪到屏幕右侧 20000pt 外，`isHidden = false` | 判据是**结构 / 几何**的用例（`UIView` 计数、`contentSize`、行矩形） |
/// | `.transparentOnScreen` | 屏内原位，`alpha = 0`，`windowLevel = .normal + 100` | 判据是**时间**的性能探针（默认档） |
/// | `.visibleOnScreen` | 屏内原位，`alpha = 1`，同上层级 | 判据依赖**真实可见性**的用例（像素截图取证、人肉看） |
///
/// 三档的实测差异（本机 iPhone 17 Pro 模拟器）记在 `README.md` 的「三档 A/B」一节，
/// 复量走 `ProbeRigSelfTests.testPlacementABIsRecorded`。**结论与桌面很不一样，
/// 别照抄桌面那份的推论**：
///
/// - 结构与几何三档**完全一致**（`views=6`、`content=22000`、`scrollable=21300`、
///   `travelled=3068`，两轮一模一样）。
/// - **`.offScreen` 也截得到像素**（三档 `ink` 都是 0.0262，一位不差）。
///   这一条与桌面的直觉相反，也与本文件早先写的假设相反 —— 它是量出来的：
///   `drawHierarchy(afterScreenUpdates:)` 在 iOS 上会自己驱动一次离屏更新，
///   窗口在不在可见区不影响。所以像素判据三档都能用。
/// - **时间读数三档分不出来**。六轮 A/B 里单帧 p50 的排序每轮都在换
///   （offscreen 0.78–2.09ms / transparent 1.20–2.16ms / visible 1.02–1.90ms，
///   均值 1.58 / 1.72 / 1.53），`CADisplayLink` 拍数比恒 0.98–1.00。
///   **桌面那条「屏外会让计时读数崩塌」的结论在 iOS 上不成立**，别照抄 ——
///   桌面屏外能掉到理想拍数的一半、超预算帧从 0% 跳到 22%，这里什么都没发生。
///   六轮明细见 `README.md`「三档 A/B」。
///
/// **iOS 27 起有两条不再成立**（2026-10-12 复量，README「iOS 27 复量」）：系统只给
/// **可见**窗口的滚动视图挂滚动边缘效果，于是 `alpha = 1` 的两档比 `alpha = 0` 的默认档
/// 多 4 个系统视图（`recursiveViewCount()` 已不数它们，三档仍是 6）、`ink` 也更高
/// （0.0847 对 0.0259 —— 那道渐隐模糊是真的画出来的）。默认档截到的是**没有**边缘效果
/// 的画面。时间读数三档仍然分不出来。
///
/// 所以 iOS 的默认档取 `.transparentOnScreen` 不是因为它更快，而是因为：
/// ① 与桌面同名同义，两边探针读起来是一件事；② 屏上看不见东西。
/// `.offScreen` 三档里唯一真正的区别是窗口不参与合成 —— 想彻底排除合成器干扰时用它。
///
/// 逃生阀：`TEST_RUNNER_UTERM_MOBILE_PROBE_PLACEMENT=offscreen|transparent|visible`
/// 把所有窗口强制成同一档（`xcodebuild` 会把 `TEST_RUNNER_` 前缀剥掉再注入宿主进程）。
/// 日常别开 —— 上面那张表就是靠它量出来的。
@MainActor
enum MobileProbeWindow {

    // MARK: - 摆法

    enum Placement: String, Equatable, CaseIterable {
        /// 屏幕之外。判据是结构 / 几何时用它。
        /// （实测**像素也拿得到** —— `drawHierarchy` 不挑窗口在不在屏上。）
        case offScreen
        /// 屏内但 `alpha = 0`。判据是时间时用它（默认）。
        case transparentOnScreen
        /// 真的看得见。判据依赖真实可见性时用它。
        case visibleOnScreen

        /// 一行短名，打日志用。
        var short: String {
            switch self {
            case .offScreen: return "offscreen"
            case .transparentOnScreen: return "transparent"
            case .visibleOnScreen: return "visible"
            }
        }
    }

    /// 探针窗口的层级：`.normal + 100`。压在宿主窗口之上，又低于系统警告框。
    static let level = UIWindow.Level(UIWindow.Level.normal.rawValue + 100)

    /// `isolateHost` 时宿主窗口被压到的层级。
    static let hostLevel = UIWindow.Level(UIWindow.Level.normal.rawValue - 100)

    /// `.offScreen` 档的位移量：往屏幕右侧推这么远。
    /// 往右而不是往左：负 origin 的 `UIWindow` 在某些 scene 上会被 clamp 回 0。
    static let offScreenOffset: CGFloat = 20_000

    /// 复量 A/B 用的逃生阀。见类型注释。
    static var forcedPlacement: Placement? {
        switch ProcessInfo.processInfo.environment["UTERM_MOBILE_PROBE_PLACEMENT"] {
        case "offscreen": return .offScreen
        case "transparent": return .transparentOnScreen
        case "visible": return .visibleOnScreen
        default: return nil
        }
    }

    // MARK: - 建窗 / 拆窗

    /// 本进程里由 `make(...)` 建出来、还没拆的窗口。`closeAll()` 拿它兜底。
    private static var created: [UIWindow] = []

    /// 宿主窗口 → **本进程第一次看到它时**的 `windowLevel`。
    ///
    /// 曾经这里记的是「上一次压之前的层级」（每轮 `isolateHost` 重记一次、`closeAll()`
    /// 消费掉）。那样只要有任何一条用例漏了复原，下一条用例就会把残值 `hostLevel`
    /// 当成「原值」记进来，两条用例的复原目标从此打架 —— 全量跑一次红的根因就是它
    /// （`MobileFixturesTests` 走 `close(_:)` 逐扇拆窗、从不复原宿主，之后
    /// `ProbeRigSelfTests.testCloseAllTearsDownAndRestoresHost` 量到的「mount 前」
    /// 已经是 -100，而 `closeAll()` 把它恢复成了真正的原值 0）。
    ///
    /// 现在改成**只记一次**：某扇窗第一次进 `isolateHostWindows` 时把当时的层级
    /// 存下来，之后无论被压多少轮都不再更新，复原永远回到进程启动时的那个值。
    /// 于是「压 → 复原」是幂等的，任何顺序、任何漏拆都不会让原值漂移。
    private struct HostLevelMemo {
        /// 弱引用：宿主窗口的生命周期归 scene 管，夹具不该把它钉住。
        weak var window: UIWindow?
        let originalLevel: UIWindow.Level
    }
    private static var hostLevelMemos: [HostLevelMemo] = []

    /// 记下某扇宿主窗口的原始层级 —— 已经记过的**不覆盖**。
    private static func rememberOriginalLevel(of window: UIWindow) {
        hostLevelMemos.removeAll { $0.window == nil }
        guard !hostLevelMemos.contains(where: { $0.window === window }) else { return }
        hostLevelMemos.append(HostLevelMemo(window: window, originalLevel: window.windowLevel))
    }

    /// 本进程第一次看到这扇宿主窗口时的层级。没被 `isolateHost` 碰过则为 nil。
    /// 自证测试拿它当断言目标。
    static func originalHostLevel(of window: UIWindow) -> UIWindow.Level? {
        hostLevelMemos.first { $0.window === window }?.originalLevel
    }

    /// 把所有被 `isolateHost` 压过的宿主窗口恢复到**进程内首见**的层级。幂等。
    static func restoreHostWindows() {
        for memo in hostLevelMemos {
            guard let window = memo.window else { continue }
            window.windowLevel = memo.originalLevel
        }
        hostLevelMemos.removeAll { $0.window == nil }
    }

    /// 建一个 `UIWindow`，挂上 `UIHostingController(rootView:)`，按 `placement` 摆好。
    ///
    /// - Parameters:
    ///   - size: 内容尺寸。传 `nil` 用当前 scene 的屏幕尺寸（真实档）。
    ///     **探针一般要写死**：iPhone 与 iPad 的可视行数差三倍，写死才能跨机器比。
    ///   - placement: 见 `Placement`。默认 `.transparentOnScreen`（计时探针档）。
    ///   - isolateHost: 把宿主窗口压到 `hostLevel`（不拆），默认开。
    ///   - rootView: 被测视图。
    /// - Returns: 窗口 + 承载它的 hosting controller（hosting controller 的
    ///   `view` 才是量 `UIView` 数 / `hitTest` 的根）。
    static func make<V: View>(size: CGSize? = nil,
                              placement: Placement = .transparentOnScreen,
                              isolateHost: Bool = true,
                              rootView: V) -> (window: UIWindow, host: UIHostingController<V>) {
        let placement = forcedPlacement ?? placement
        let scene = activeScene()
        let contentSize: CGSize
        if let size {
            contentSize = size
        } else if let scene {
            contentSize = scene.screen.bounds.size
        } else {
            contentSize = CGSize(width: 390, height: 844)
        }

        let host = UIHostingController(rootView: rootView)
        host.view.frame = CGRect(origin: .zero, size: contentSize)
        // 关掉安全区插入：探针要的是「这么大一块内容有多贵」，不是「刘海占了多少」。
        // 不关的话不同模拟器（有无灵动岛）会给出不同的可视行数，档与档之间没法比。
        host.safeAreaRegions = []
        host.view.backgroundColor = .white

        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: contentSize))
        }
        window.frame = CGRect(origin: origin(for: placement, scene: scene), size: contentSize)
        window.windowLevel = level
        window.alpha = placement == .transparentOnScreen ? 0 : 1
        // 探针自己驱动滚动（`setContentOffset` / `scrollRectToVisible`），不需要
        // 真触摸；关掉交互免得模拟器上飘进来的点击改变读数。`.visibleOnScreen`
        // 是给人看 / 给真手势用的，那档留着。
        window.isUserInteractionEnabled = placement == .visibleOnScreen
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        // `makeKeyAndVisible()` 会把 frame 重设成 scene 的 coordinateSpace 全屏，
        // 所以离屏这一档必须在它之后再落一次原点（与桌面 `setFrameOrigin` 同理）。
        window.frame = CGRect(origin: origin(for: placement, scene: scene), size: contentSize)

        created.append(window)
        if isolateHost { isolateHostWindows(keeping: [window]) }
        logPlacementOnce(window, placement)
        return (window, host)
    }

    /// 按摆法算窗口原点。
    private static func origin(for placement: Placement, scene: UIWindowScene?) -> CGPoint {
        switch placement {
        case .offScreen:
            let width = scene?.screen.bounds.width ?? 430
            return CGPoint(x: width + offScreenOffset, y: 0)
        case .transparentOnScreen, .visibleOnScreen:
            return .zero
        }
    }

    /// 宿主自带的窗口里跑着真实应用逻辑（SplashView / SwiftData 容器 / CloudKit 监听），
    /// 盖在探针窗口上会污染读数。桌面那份直接 `orderOut`；iOS 上**不能拆** ——
    /// 拆掉会连带带走 SwiftData 的 `ModelContainer` 环境（README 坑⑤）。
    /// 这里只把它们压到 `hostLevel`，拆掉最后一扇探针窗时按**首见层级**复原。
    ///
    /// 不再按「当前层级 != hostLevel」过滤：那个过滤条件的本意是「别把自己压过的
    /// 值当原值记第二遍」，但记忆改成只记一次之后它就多余了，而且它会漏掉一种情况 ——
    /// 上一条用例漏了复原时，这一条压根不会把窗口重新登记，谁也不负责把它抬回去。
    static func isolateHostWindows(keeping kept: [UIWindow]) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where !kept.contains(window) && !created.contains(window) {
                rememberOriginalLevel(of: window)
                window.windowLevel = hostLevel
            }
        }
    }

    /// 拆一扇窗。`rootViewController = nil` 必须显式做：只置 `isHidden` 的话
    /// hosting controller 与它的图层后备存储会跟着窗口一起被 scene 拖着不放，
    /// 下一档的 footprint 读数就带着上一档的账。
    ///
    /// 拆掉**最后一扇**探针窗时顺手复原宿主层级 —— 逐扇拆窗也是一条合法退出路径
    /// （`MobileProbeRig.close()`、夹具自证用例都走它），不能只有 `closeAll()` 负责复原。
    static func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene = nil
        created.removeAll { $0 === window }
        if created.isEmpty { restoreHostWindows() }
    }

    /// 拆掉本进程里所有由 `make(...)` 建的窗，并复原被 `isolateHost` 压过的宿主窗口。
    ///
    /// **每条探针用例开头写 `defer { MobileProbeWindow.closeAll() }`** —— 不要覆写
    /// `tearDown()`：`XCTestCase.tearDown()` 是 `nonisolated` 的，Swift 6 语言模式下
    /// 从那里碰 `@MainActor` 成员一律判成数据竞争（README「隔离」一节）。
    static func closeAll() {
        for window in created { close(window) }
        created.removeAll()
        // 一扇探针窗都没建过时 `close(_:)` 不会被调到，这里兜一次；复原是幂等的。
        restoreHostWindows()
    }

    /// 还没拆的探针窗口数。自证用（拆窗漏了会让下一档带上一档的账）。
    static var openWindowCount: Int { created.count }

    // MARK: - 环境

    /// 当前前台的 `UIWindowScene`。测试宿主启动后必然有一个；取不到时
    /// `make` 退回无 scene 的窗口（仍能布局，只是拿不到真实屏幕尺寸/刷新率）。
    static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// 屏幕的最大刷新率（Hz）。心跳/单帧的「理想值」按它换算，
    /// 别写死 60 —— 模拟器跟着宿主 Mac 的显示器走，ProMotion 上是 120。
    static func maximumFramesPerSecond() -> Int {
        activeScene()?.screen.maximumFramesPerSecond ?? 60
    }

    /// 单帧预算（ms）= `1000 / maxFPS`。60Hz → 16.67ms，120Hz → 8.33ms。
    ///
    /// **跨机器比「超预算比例」之前先看这个数**：同一份代码在 60Hz 模拟器上
    /// 超预算 0%、在 120Hz 上可能就有几个点，因为分母换了。所以探针同时打
    /// 一个按 120Hz 固定的 8.33ms 比例（`ProbeBudget.strictMS`）当跨机器可比的粗尺。
    static func frameBudgetMS() -> Double { 1000.0 / Double(maximumFramesPerSecond()) }

    /// 窗口 frame 是否真的落在屏幕之外。探针里可以直接断言它。
    static func isOffScreen(_ window: UIWindow) -> Bool {
        guard let screen = window.windowScene?.screen else { return false }
        return !screen.bounds.intersects(window.frame)
    }

    /// 一句话描述窗口状态，出问题时贴进日志比猜快。
    static func describe(_ window: UIWindow) -> String {
        let scene = window.windowScene
        return String(format: "frame=(%.0f,%.0f %.0fx%.0f) offscreen=%@ level=%.0f alpha=%.2f "
                      + "hidden=%@ key=%@ scene=%@ maxFPS=%d budget=%.2fms",
                      window.frame.minX, window.frame.minY,
                      window.frame.width, window.frame.height,
                      isOffScreen(window) ? "yes" : "NO",
                      window.windowLevel.rawValue, window.alpha,
                      window.isHidden ? "yes" : "no",
                      window.isKeyWindow ? "yes" : "no",
                      scene == nil ? "nil" : String(describing: scene!.activationState),
                      maximumFramesPerSecond(), frameBudgetMS())
    }

    private static var didLogPlacement = false

    /// 每个测试进程打一行就够了 —— 只是为了回看这轮的摆法。
    private static func logPlacementOnce(_ window: UIWindow, _ placement: Placement) {
        guard !didLogPlacement else { return }
        didLogPlacement = true
        print("[MobileProbeWindow] placement=\(placement.short) \(describe(window))")
    }
}

/// 跨机器可比的固定预算。
enum ProbeBudget {
    /// 120Hz 的单帧预算。`MobileProbeWindow.frameBudgetMS()` 随机器变，
    /// 这个不变 —— 两份报告要对上「超预算比例」时用它。
    static let strictMS: Double = 8.33
}

/// `CADisplayLink` 拍数计数器。
///
/// 桌面探针用「8ms `Task.sleep` 循环收到几拍」当心跳；iOS 有真正的
/// `CADisplayLink`，直接数系统实际交付了几帧，比 sleep 循环更贴近体感。
/// 两者都留：`Task.sleep` 拍数量的是「主线程还愿不愿意回来」，
/// `CADisplayLink` 拍数量的是「渲染循环还在不在跑」。
@MainActor
final class DisplayLinkCounter {
    private var link: CADisplayLink?
    private(set) var ticks = 0
    /// 每两拍之间的间隔（ms）。p95 高 = 掉帧。
    private(set) var intervals: [Double] = []
    /// `onTick` 里那段活儿自己的耗时（ms）。驱动滚动时它就是「单帧主线程成本」。
    private(set) var workMS: [Double] = []
    /// 系统报的标称帧间隔（ms，取第一拍的 `link.duration`）。
    /// ProMotion 上 `maximumFramesPerSecond` 是 120，但 link 实际可能被降频跑 ——
    /// 报告里要写这个数，别只写屏幕的 maxFPS。
    private(set) var nominalIntervalMS: Double = 0
    /// 实际生效的 `preferredFrameRateRange`（min/max/preferred，Hz）。
    private(set) var rateRange: CAFrameRateRange = .default
    private var last: CFTimeInterval = 0
    /// 每拍回调里跑一次的活儿（例如推进滚动位置）。
    ///
    /// 显式标 `@MainActor`：回调体里必然要碰 `UIScrollView` / `UIView`，
    /// 而 target 默认隔离是 `nonisolated`，不标的话闭包被当成非隔离的，
    /// Swift 6 语言模式下里面每一句都判成数据竞争。
    var onTick: (@MainActor () -> Void)?

    /// - Parameter preferred: 想要的帧率区间。默认 `.default`（跟随系统）。
    ///   要把 ProMotion 钉在 120Hz 就传 `CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)`。
    func start(preferred: CAFrameRateRange = .default) {
        ticks = 0
        intervals.removeAll()
        workMS.removeAll()
        nominalIntervalMS = 0
        last = 0
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = preferred
        // `.common` 而非默认 mode：测试里主 runloop 会进 tracking/modal 模式，
        // 默认 mode 的 link 在那期间静默停摆，拍数直接腰斩，看起来像卡顿。
        link.add(to: .main, forMode: .common)
        rateRange = link.preferredFrameRateRange
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// 一行诊断：实际拍率 vs 屏幕 maxFPS。
    func describe() -> String {
        String(format: "ticks=%d nominal=%.2fms(%.0fHz) range=[%.0f,%.0f]p%.0f interval-p95=%.2fms",
               ticks, nominalIntervalMS,
               nominalIntervalMS > 0 ? 1000 / nominalIntervalMS : 0,
               rateRange.minimum, rateRange.maximum, rateRange.preferred ?? 0,
               ProbeMetrics.percentile(intervals, 0.95))
    }

    @objc private func tick(_ link: CADisplayLink) {
        if nominalIntervalMS == 0 { nominalIntervalMS = link.duration * 1000 }
        if last > 0 { intervals.append((link.timestamp - last) * 1000) }
        last = link.timestamp
        ticks += 1
        guard let onTick else { return }
        let start = CFAbsoluteTimeGetCurrent()
        onTick()
        workMS.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
}
