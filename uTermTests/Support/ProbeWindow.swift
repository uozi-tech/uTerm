import AppKit

// 抄自 uTable commit bba891b（`git -C <workspace>/uTable log -1 --format=%h -- uTableTests/ProbeWindow.swift`）。
//
// 移植到 uTerm 时的改动（只做编译所需的最小改动）：
// 1. `uTermTests` target 的 `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`（uTable 的
//    测试 target 是 `MainActor`），所以整个 `enum ProbeWindow` 显式标了 `@MainActor`
//    —— 里面每一处都在碰 `NSWindow` / `NSScreen`。
// 2. 逃生阀环境变量前缀 `UTABLE_` → `UTERM_`。
// 其余（三档摆法、`Unconstrained`、`blindsRealMouse`）与 uTable 一字不差。

/// 测试里所有「要上屏才量得到」的窗口的统一建窗入口。
///
/// **为什么存在**：24 个测试文件里有 40 处手写 `NSWindow(...) + orderFrontRegardless()`，
/// 跑一轮全量测试（约 15 分钟）期间这些窗口轮流弹在用户屏幕正中，把屏抢走。
/// 这里把「窗口摆哪」收成一个决定，并按**这个用例的判据是什么**分三档。
///
/// ## 三档摆法
///
/// - `.offScreen`（默认）：摆到所有屏幕之外（`x = -20000`）。给**判据是结构 /
///   几何 / 像素**的用例：NSView 计数、行矩形、ink bbox、cacheDisplay 出的 PNG、
///   真 NSEvent 打进去的行为。实测这些读数与屏内**一模一样**（见下）。
/// - `.transparentOnScreen`：落在刷新率最高的那块屏上，但 `alphaValue = 0`。
///   给**判据是时间**的性能探针（心跳拍数 / 单帧 ms / hitTest µs）。窗口真的在
///   屏幕上（有 display link、有正常合成路径），所以读数与可见时一致；但屏幕上
///   什么都看不见，不再抢屏。
/// - `.visibleOnScreen`：真的可见。只给**依赖真实可见性的用例**（tooltip、真光标）。
///
/// ## 为什么计时探针不能离屏：A/B 实测（2026-09-05，Debug，机器上另有构建在跑）
///
/// 方法：同一份二进制，靠环境变量翻转摆法，除位置外代码路径完全一致；每批 4~6 次
/// **交替**（屏内的轮次把屏外的轮次夹在中间），只信同批相对差。
/// `PermissionsTreeScrollCostTests` 一共跑了 16 轮。
///
/// `beats` = 3s 内 8ms 心跳实际收到的拍数（理想 375，越大越好）：
///
/// | 批次（时间序） | 161 表 | 300 表 |
/// |---|---|---|
/// | 一：屏内 / 屏外 / 屏外 / 屏内 | 134 / **115** / **108.5** / 128.5 | 125.5 / **98.5** / **88** / 118 |
/// | 二：屏内 / 120Hz / 屏外 / 屏外 / 120Hz / 屏内 | 116.5 / 115 / **65.5** / **87.5** / 110.5 / 115 | 113 / 107.5 / **66.5** / **82.5** / 99 / 118.5 |
/// | 三：120Hz / alpha0 / 屏外 / 屏外 / alpha0 / 120Hz | 128.5 / 135 / **101.5** / **124** / 111.5 / 135 | 126.5 / 110.5 / **106** / **101** / 119.5 / 120.5 |
///
/// 汇总（161 表）：屏内十轮均值 **123**（110–135），屏外六轮均值 **100**（65.5–124）。
/// **屏外不只是低了约 19%，方差还大得多**：第二批两次掉到 65.5 / 87.5，同一批里
/// 「超 8.33ms 的帧」从屏内恒 0~0.2% 跳到 **14.0% / 22.7%** —— 那已经是会把断言
/// 从过变成不过的量级。单帧 p50 屏内 5.25ms → 屏外 5.70ms（+8.6%）。
///
/// **`.transparentOnScreen` 拿回了屏内的读数**（第三批：alpha0 135 / 111.5 拍
/// 对 120Hz 屏 128.5 / 135；单帧 p50 5.55 vs 5.26ms，都在同批噪声内），
/// 而屏幕上看不到任何东西 —— 所以计时探针默认走这一档。
///
/// 不受摆法影响的判据（三批 16 轮全部一模一样）：`views=237`、
/// `mean-channel-delta=0.0924`、`repaint-cells=297`、`repaint-rows=33`、每步行重画数。
///
/// ## 顺带量到的两件事
///
/// - **换哪块屏不影响读数**：60Hz 外接 Studio Display 与 120Hz 内建屏的对照
///   （116.5 / 115 拍 vs 115 / 110.5 拍）在噪声内 —— 差别来自「在不在屏上」，
///   不是刷新率。
/// - **backingScaleFactor 屏外仍是 2.0**（`window.screen` 为 nil，但 backing store
///   沿用系统默认），所以像素判据不会因为离屏而换分辨率。
///
/// ## 屏内窗口会被用户的真鼠标悬停到（2026-09-06 定案）
///
/// `.transparentOnScreen` 把窗口摆在 `visibleFrame` 的左下角（默认 +40,+40）。
/// 用户的光标要是正好停在那块地方，**SwiftUI 的 `.onHover` 会真的亮起来** ——
/// 「悬停才建真控件」的行于是变成活行，而且滚动时每一步都有新的一行滚到静止的
/// 光标底下，每帧都要拆一棵 `NSTextField` 子树再建一棵。
///
/// 实测（uTable `RedisValueEditor` 1000 字段，窗口正罩住光标 vs 离屏）：
///
/// | 摆法 | NSTextField | NSView |
/// |---|---|---|
/// | 罩住光标 | **3** | **23** |
/// | 罩住光标 + `ignoresMouseEvents` | **3** | **23** |
/// | 离屏 | 1 | 17 |
/// | 罩住光标 + 谎报 `mouseLocationOutsideOfEventStream` | 1 | 17 |
///
/// 也就是说 `ignoresMouseEvents` **挡不住**：AppKit 合成 tracking area 的
/// enter / exit 时不走事件路由，而是直接问窗口「鼠标现在在窗内哪」。
/// 所以 `Unconstrained` 覆写了 `mouseLocationOutsideOfEventStream`
/// （`blindsMouse`，`.visibleOnScreen` 那档除外）—— 这是唯一挡得住的地方。
///
/// 这条曾经把 uTable 一整轮全量测试染红（18 条），读数是「活行之外有 3 个
/// NSTextField」与「单帧 p50 2.4 → 19.4ms」。**不是跨用例污染，是光标停在了探针
/// 窗口上**，所以「单跑绿、全量红」只取决于那 23 分钟里鼠标停在哪块屏。
@MainActor
enum ProbeWindow {

    enum Placement {
        /// 屏幕之外。判据是结构 / 几何 / 像素时用它。
        case offScreen
        /// 在最快的那块屏上，但 `alphaValue = 0`。判据是时间时用它。
        case transparentOnScreen
        /// 真的看得见。只给依赖真实可见性的用例（tooltip / 真光标）。
        case visibleOnScreen
    }

    /// 覆写掉屏幕约束 —— 带标题栏的窗口否则会被 `constrainFrameRect(_:to:)`
    /// 拽回可见区（`.borderless` 不受约束）。
    ///
    /// 另外**把用户的真鼠标挡在窗外**（`blindsMouse`，见 `mouseBlindOrigin`）。
    final class Unconstrained: NSWindow {
        /// 见 `ProbeWindow.mouseBlindOrigin`。`.visibleOnScreen` 那档会关掉它。
        var blindsMouse = true

        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }

        /// AppKit 在「视图动到了静止的鼠标底下」时，就是拿这个值去算
        /// `NSTrackingArea` 的 enter / exit 的 —— 谎报一个窗外的点，
        /// SwiftUI 的 `.onHover` 就再也不会因为用户的光标而亮起来。
        override var mouseLocationOutsideOfEventStream: NSPoint {
            blindsMouse ? ProbeWindow.mouseBlindOrigin : super.mouseLocationOutsideOfEventStream
        }
    }

    /// 「窗内鼠标位置」的谎报值：窗口坐标系里离内容远得不能再远的一点。
    static let mouseBlindOrigin = NSPoint(x: -1_000_000, y: -1_000_000)

    /// 这个窗口是否已经把真鼠标挡在外面（探针可以在 setUp / 建窗后直接断言它）。
    static func blindsRealMouse(_ window: NSWindow) -> Bool {
        window.mouseLocationOutsideOfEventStream == mouseBlindOrigin
    }

    /// 真鼠标此刻是不是落在这个窗口上 —— 只用来打取证日志。
    static func cursorIsInside(_ window: NSWindow) -> Bool {
        window.frame.contains(NSEvent.mouseLocation)
    }

    /// 所有屏幕并集之外的一个点。往左下走远，避免撞上以后接入的第二块屏。
    static let offScreenOrigin = NSPoint(x: -20_000, y: -20_000)

    /// 复量 A/B 用的逃生阀：`TEST_RUNNER_UTERM_PROBE_PLACEMENT=offscreen|transparent|visible`
    /// 把所有窗口强制成同一档。日常别开——上面那张表就是靠它量出来的。
    /// `TEST_RUNNER_UTERM_PROBE_ONSCREEN=1` 是「全部变可见」的老写法，留着方便调试。
    static var forcedPlacement: Placement? {
        let env = ProcessInfo.processInfo.environment
        switch env["UTERM_PROBE_PLACEMENT"] {
        case "offscreen": return .offScreen
        case "transparent": return .transparentOnScreen
        case "visible": return .visibleOnScreen
        default: break
        }
        switch env["UTERM_PROBE_ONSCREEN"] {
        case "1", "true", "YES": return .visibleOnScreen
        default: return nil
        }
    }

    /// 刷新率最高的屏（通常是内建 120Hz / 2x）。
    static var fastestScreen: NSScreen? {
        NSScreen.screens.max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }
    }

    /// 建一个测试窗口并上屏。
    ///
    /// - Parameters:
    ///   - contentRect: 只用它的 `size`；origin 由 `placement` 决定。
    ///   - styleMask: `.titled` 也能摆到屏外（见 `Unconstrained`）。
    ///   - contentView: 先挂内容再上屏。
    ///   - screen: 指定屏；屏内两档不指定时落在 `fastestScreen`。
    ///   - key: `true` 走 `makeKeyAndOrderFront`，`false` 走 `orderFrontRegardless`。
    ///   - placement: 见 `Placement`。**改这个参数前先读本文件顶部的 A/B 数据。**
    static func make(contentRect: NSRect,
                     styleMask: NSWindow.StyleMask = [.borderless],
                     contentView: NSView? = nil,
                     screen: NSScreen? = nil,
                     key: Bool = false,
                     placement: Placement = .offScreen,
                     onScreenOrigin: NSPoint = NSPoint(x: 40, y: 40)) -> NSWindow {
        let placement = forcedPlacement ?? placement
        let target: NSScreen? = placement == .offScreen ? nil : (screen ?? fastestScreen)
        let origin: NSPoint
        switch placement {
        case .offScreen:
            origin = offScreenOrigin
        case .transparentOnScreen, .visibleOnScreen:
            origin = target.map { NSPoint(x: $0.visibleFrame.minX + onScreenOrigin.x,
                                          y: $0.visibleFrame.minY + onScreenOrigin.y) }
                ?? onScreenOrigin
        }
        let window = Unconstrained(contentRect: NSRect(origin: origin, size: contentRect.size),
                                   styleMask: styleMask,
                                   backing: .buffered,
                                   defer: false,
                                   screen: target)
        // 只有「真的要给人看 / 要真光标」的那一档才放真鼠标进来；
        // 另外两档一律挡住 —— 探针窗口正落在用户光标底下时，SwiftUI 的
        // `.onHover` 会真的亮起来，把「悬停才建控件」的行全变成活行（见 `Unconstrained`）。
        window.blindsMouse = placement != .visibleOnScreen
        // 建窗时传的 contentRect 会先过一次约束；`Unconstrained` 已经放行，
        // 这里再显式落一次原点，防止 styleMask 变化引入偏移。
        window.setFrameOrigin(origin)
        if let contentView { window.contentView = contentView }
        if placement == .transparentOnScreen { window.alphaValue = 0 }
        if key { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
        logPlacementOnce(window, placement)
        return window
    }

    /// 窗口 frame 是否真的落在所有屏幕之外。探针里可以直接断言它。
    static func isOffScreen(_ window: NSWindow) -> Bool {
        !NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    /// 一行诊断，打进日志方便回看这轮到底摆在哪。
    static func describe(_ window: NSWindow) -> String {
        let f = window.frame
        return String(format: "frame=(%.0f,%.0f %.0fx%.0f) offscreen=%@ screen=%@ scale=%.1f alpha=%.1f",
                      f.minX, f.minY, f.width, f.height,
                      isOffScreen(window) ? "yes" : "NO",
                      window.screen?.localizedName ?? "nil",
                      window.backingScaleFactor,
                      window.alphaValue)
    }

    private nonisolated(unsafe) static var didLogPlacement = false

    /// 每个测试进程打一行就够了 —— 只是为了回看这轮的摆法。
    private static func logPlacementOnce(_ window: NSWindow, _ placement: Placement) {
        guard !didLogPlacement else { return }
        didLogPlacement = true
        print("[ProbeWindow] placement=\(placement) \(describe(window))")
    }
}
