//
//  UTermScrollTrace.swift
//  uTerm 本地补丁（不在上游）：滚动每一步发出了什么（拖动 / 减速的像素、越界平移、视口行号、主线程 tick 的耗时），
//  给回归测试逐帧读。关着时（默认）`record` 直接返回，不占开销。
//

import Foundation
import os
import QuartzCore

public enum UTermScrollTrace {
    public struct Event: Sendable {
        /// `CACurrentMediaTime()`。
        public let time: Double
        /// drag / momentum / overscroll / row，系统滚动的 sv-write / sv-phase / sv-scroll，
        /// 以及耗时类的 tick-app / tick-refresh / tick-draw / wakeup-tick（见 `span`）。
        public let kind: String
        /// drag、momentum：这一步发给引擎的像素（手指跟着 / 松手之后）；overscroll：越界时画面层平移的像素；
        /// row：视口首行行号；sv-*：见各自的 signpost 函数；耗时类：毫秒。
        public let value: Double
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var events: [Event] = []
    nonisolated(unsafe) private static var enabled = false

    public static var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; events.removeAll(); lock.unlock() }
    }

    static func record(_ kind: String, _ value: Double) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        events.append(Event(time: CACurrentMediaTime(), kind: kind, value: value))
    }

    /// 一段耗时：记在开始时刻，值是毫秒。`start` 用 `CACurrentMediaTime()`；关着时调用方传 0、这里直接返回。
    static func span(_ kind: String, since start: Double) {
        guard start > 0 else { return }
        let now = CACurrentMediaTime()
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        events.append(Event(time: start, kind: kind, value: (now - start) * 1000))
    }

    /// 打点起点：trace 开着时返回当前时刻，关着时返回 0（span 见 0 就不记）。
    static func mark() -> Double {
        lock.lock(); defer { lock.unlock() }
        return enabled ? CACurrentMediaTime() : 0
    }

    // MARK: 给 Instruments 的 signpost（M16 第八轮：按「上玻璃」打分）
    //
    // 滚动位置（`scroll-offset`）、触摸阶段（`touch`）和系统滚动的排查打点（`sv-*`、`engine-bar`）各发一条 signpost；
    // 外面用 xctrace 录的时候，trace 里就能把「这一刻想显示的位置」对到「它哪个 vsync 上的玻璃」，user 真手甩的时候也能录。
    // 要录的一方自己打开（真机回归用例 / 排查时临时打开；本来想用 `.dynamicTracing` 自动判断有没有人在录，实测在
    // Animation Hitches 模板下探不到）。每条 signpost 约 1 µs，每秒最多一两百条。
    // 自写惯性那几条（`glide-start` / `glide` / `surface-commit`）随自写滚动物理一起删了。
    nonisolated(unsafe) public static var emitsSignposts = false
    private static let glassSignposter = OSSignposter(subsystem: "com.uozi.uTerm.glass", category: .pointsOfInterest)

    static var isInstrumentsRecording: Bool { emitsSignposts && glassSignposter.isEnabled }

    /// 引擎 wakeup（app 邮箱里来了标题、滚动条这类消息）触发的 tick 要不要在主线程同步整帧重画。按平台定死，不是开关：
    /// - iOS：要。M16 第六轮试过不画（渲染线程自己会画这些变化），user 在真机上说滚动时发糊，第七轮起回到同步重画，
    ///   并按这个取值验收了滚动手感。
    /// - Mac：不要。主线程白画一帧还拿着 draw_mutex 挡渲染线程，Mac 上没有 iOS 那个观感问题。
    #if os(macOS)
        public static let wakeupDrawsSynchronously = false
    #else
        public static let wakeupDrawsSynchronously = true
    #endif

    /// 程序抓着鼠标时，松手后的惯性滑多远，相对 UIScrollView `.normal`（1 = 和普通滚动一样远；减速率按它的倒数放大）。
    /// user 在 Duo 上的 Claude 全屏界面里比过三档（1 / 0.5 / 0.25）：照 `.normal` 滑得太远，定四分之一。
    /// 留成变量是给测试核「距离跟着它走」，宿主不改它；下一帧惯性起生效。
    public static let defaultProgramMomentumTravel = 0.25
    nonisolated(unsafe) public static var programMomentumTravel = defaultProgramMomentumTravel

    /// 触摸的阶段（signpost `touch` 的第二个数）：0 按下、1 开始拖、2 抬起 / 取消。
    public enum TouchPhase: Int { case down = 0, dragBegan = 1, up = 2 }

    /// 触摸阶段：按「上玻璃」打分时把冻结归到按下未拖 / 拖动 / 松手后。
    static func signpostTouch(_ phase: TouchPhase) {
        guard isInstrumentsRecording else { return }
        let text = String(format: "%.6f %d", CACurrentMediaTime(), phase.rawValue)
        glassSignposter.emitEvent("touch", "\(text, privacy: .public)")
    }

    // MARK: 系统滚动的排查打点（M16 第十轮：user 说「顶部底部中间会有反复横跳」）

    /// 我们主动改滚动视图或引擎位置的原因（不是 UIKit 自己动的）。signpost `sv-write`：时刻、原因、改之前、改之后（物理像素）。
    public enum ScrollWrite: Int {
        /// 静止时按引擎对 contentSize（前后是 contentSize 高度，px）。
        case restSize = 1
        /// 静止时按引擎对 contentOffset。
        case restOffset = 2
        /// 跟踪 / 减速中回滚变长，只放宽 contentSize（前后是 contentSize 高度）。
        case motionGrowSize = 3
        /// 跟踪 / 减速中停在底部来了输出，改 shift（前后是 shift，px）。
        case shiftChange = 4
        /// 对齐到整行：起我们自己的对齐动画（display link 一帧帧写 contentOffset）。
        case alignAnimated = 5
        /// 对齐到整行：直接设 contentOffset。
        case alignImmediate = 6
        /// 对齐到整行：滚动视图取整后不会动，只把引擎对齐（前后是引擎位置）。
        case alignEngineOnly = 7
        /// 停住减速 / 对齐动画（前后是 contentOffset）。
        case stopDecel = 8
        /// 进回弹那一下给引擎多发一屏（前后是这次发给引擎的位移：不含 / 含多发的那一屏）。
        case edgeHeal = 9
        /// 松手后的减速没收到结束回调，兜底当它结束了。
        case watchdog = 10
    }

    static func signpostScrollWrite(_ reason: ScrollWrite, from: Double, to: Double) {
        record("sv-write", Double(reason.rawValue))
        guard isInstrumentsRecording else { return }
        let text = String(format: "%.6f %d %.1f %.1f", CACurrentMediaTime(), reason.rawValue, from, to)
        glassSignposter.emitEvent("sv-write", "\(text, privacy: .public)")
    }

    /// 滚动视图的生命周期（signpost `sv-phase`：时刻、阶段、两个值）：1 开始拖、2 将松手（速度 px/s、落点 px）、
    /// 3 松手（会不会减速）、4 减速结束、5 对齐动画结束、6 点停兜底触发。
    static func signpostScrollPhase(_ phase: Int, _ a: Double = 0, _ b: Double = 0) {
        record("sv-phase", Double(phase))
        guard isInstrumentsRecording else { return }
        let text = String(format: "%.6f %d %.1f %.1f", CACurrentMediaTime(), phase, a, b)
        glassSignposter.emitEvent("sv-phase", "\(text, privacy: .public)")
    }

    /// 每次 scrollViewDidScroll（signpost `sv-scroll`）：contentOffset（px）、越界平移（px）、换算出的引擎目标、发给引擎的位移、
    /// 跟踪中、减速中、对齐动画中。
    static func signpostDidScroll(offset: Double, over: Double, target: Int, delta: Int, tracking: Bool, decelerating: Bool, animating: Bool) {
        record("sv-scroll", offset)
        guard isInstrumentsRecording else { return }
        let text = String(format: "%.6f %.1f %.1f %d %d %d %d %d", CACurrentMediaTime(), offset, over, target, delta,
                          tracking ? 1 : 0, decelerating ? 1 : 0, animating ? 1 : 0)
        glassSignposter.emitEvent("sv-scroll", "\(text, privacy: .public)")
    }

    /// 引擎报来的滚动条和那一刻的镜像（signpost `engine-bar`）：行号、总行数、一屏行数、镜像行号、镜像小数 px。
    static func signpostEngineBar(offset: UInt64, total: UInt64, len: UInt64, modelRow: Int, modelFrac: Int) {
        guard isInstrumentsRecording else { return }
        let text = String(format: "%.6f %llu %llu %llu %d %d", CACurrentMediaTime(), offset, total, len, modelRow, modelFrac)
        glassSignposter.emitEvent("engine-bar", "\(text, privacy: .public)")
    }

    /// 视口位置（物理像素）、在不在减速、手指按没按着。第五个数是这一刻视口归谁：1 系统滚动（UIScrollView）、
    /// 2 不归系统滚动（没有回滚 / 备用屏 / 程序抓鼠标时的自写拖动；0 是换引擎之前的终端标签用的，老录制里才有）。
    /// 第六个数是哪条代码路径动的位置（1 系统滚动的 didScroll、2 自写拖动 / 惯性、3 对齐时只动引擎、
    /// 4 当场对齐（只有 Catalyst）、5 滚轮），第七个数是终端视图的编号（同一进程里第几个建出来的），用来分清多个标签。
    static func signpostScrollOffset(px: Double, decelerating: Bool, tracking: Bool, systemPhysics: Bool, source: Int, view: Int) {
        guard isInstrumentsRecording else { return }
        let text = String(format: "%.6f %.1f %d %d %d %d %d", CACurrentMediaTime(), px, decelerating ? 1 : 0, tracking ? 1 : 0,
                          systemPhysics ? 1 : 2, source, view)
        glassSignposter.emitEvent("scroll-offset", "\(text, privacy: .public)")
    }

    /// 取出并清空。
    public static func drain() -> [Event] {
        lock.lock(); defer { lock.unlock() }
        let out = events
        events.removeAll()
        return out
    }
}

#if canImport(UIKit)
    import UIKit

    public extension UITerminalView {
        /// uTerm 测试用：Ghostty 报的一个格子的物理像素尺寸；还没有 surface 时为 nil。
        var uTermCellPixels: CGSize? {
            guard let metrics = surface?.size(), metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else { return nil }
            return CGSize(width: Int(metrics.cellWidthPixels), height: Int(metrics.cellHeightPixels))
        }

        /// uTerm 测试用：惯性 / 系统减速途中手指落下（`touchesBegan` / `gestureRecognizer(_:shouldReceive:)` 里停住它的那一句）。
        func uTermTouchDownDuringMomentum() {
            stopMomentumForTouchDown()
        }

        /// uTerm 测试用：滚动状态快照。
        struct UTermScrollState: Equatable, Sendable {
            /// 本地镜像：视口首行行号、首行顶边之上滚出去的像素（见 `MomentumScrollState.modelRow`）。
            public let row: Int
            public let fractionPixels: Int
            /// 系统滚动越界了多少像素（UIScrollView 的橡皮筋，画面层按它平移）：正 = 拉过了顶，负 = 推过了底。
            public let overscrollPixels: Double
            /// 有东西在自己动视口 / 往程序发滚轮：自写的惯性（抓鼠标、备用屏、双指）或系统滚动的减速 / 回弹 / 对齐动画。
            public let isGliding: Bool
            /// 越界着、手指又没按着：系统滚动的回弹还没走完。
            public let isBouncing: Bool
            /// 没有惯性、没有回弹、没有越界，视口在整行上。
            public var isAtRest: Bool { fractionPixels == 0 && overscrollPixels == 0 && !isGliding && !isBouncing }
        }

        var uTermScrollState: UTermScrollState {
            var over = 0.0
            var gliding = momentumScroll.displayLink != nil
            var bouncing = false
            #if !targetEnvironment(macCatalyst)
                if let driver = systemScroll.driver, let g = systemScrollGeometry() {
                    let offsetPx = Double(driver.contentOffset.y * g.scale)
                    let maxPx = Double(g.viewMax)
                    // UIKit 把 contentOffset 取整到 1/UIScreen.scale pt，Duo 内屏上 UIScreen.scale 是 3 而 nativeScale 是 2.807，
                    // 停在底上也可能差零点几个物理像素，不到 1 px 不算越界。
                    if offsetPx < -1 { over = -offsetPx } else if offsetPx > maxPx + 1 { over = maxPx - offsetPx }
                    gliding = gliding || systemScrollInMotion
                    bouncing = over != 0 && !(driver.isTracking || driver.isDragging || momentumScroll.panActive)
                }
            #endif
            return UTermScrollState(row: momentumScroll.modelRow, fractionPixels: momentumScroll.modelFrac,
                                    overscrollPixels: over, isGliding: gliding, isBouncing: bouncing)
        }

        #if !targetEnvironment(macCatalyst)
            /// uTerm 测试用：系统滚动那条路径借的 UIScrollView。
            var uTermSystemScrollView: UIScrollView? { systemScroll.driver }
            /// uTerm 测试用：现在一下单指拖动会不会归系统滚动。
            var uTermSystemPanWouldBegin: Bool { systemPanWouldBegin }
        #endif
    }
#endif
