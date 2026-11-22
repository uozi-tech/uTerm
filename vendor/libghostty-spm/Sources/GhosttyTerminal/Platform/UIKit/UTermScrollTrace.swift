//
//  UTermScrollTrace.swift
//  uTerm 本地补丁（不在上游）：滚动每一步发出了什么（自写拖动 / 惯性的像素、越界平移、视口行号、主线程 tick 的耗时），
//  给回归测试逐帧读，以及测试读滚动状态的入口。关着时（默认）`record` 直接返回，不占开销。
//

import Foundation
import os
import QuartzCore

public enum UTermScrollTrace {
    public struct Event: Sendable {
        /// `CACurrentMediaTime()`。
        public let time: Double
        /// drag / momentum / overscroll / row，以及耗时类的 tick-app / tick-refresh / tick-draw / wakeup-tick（见 `span`）。
        public let kind: String
        /// drag、momentum：这一步发给引擎的像素（手指跟着 / 松手之后）；overscroll：越界时画面层平移的像素；
        /// row：视口首行行号；耗时类：毫秒。
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

    // MARK: 给 Instruments 的 signpost（按「上玻璃」打分）
    //
    // 触摸阶段（`touch`）发一条 signpost；外面用 xctrace 录的时候，trace 里就能把冻结归到按下 / 拖动 / 松手，
    // user 真手甩的时候也能录。（系统滚动的 `scroll-offset` / `sv-*` / `engine-bar` 随换成上游的系统滚动实现删了。）
    // 要录的一方自己打开（真机回归用例 / 排查时临时打开；本来想用 `.dynamicTracing` 自动判断有没有人在录，实测在
    // Animation Hitches 模板下探不到）。每条 signpost 约 1 µs，每秒最多一两百条。
    // 自写惯性那几条（`glide-start` / `glide` / `surface-commit`）随自写滚动物理一起删了。
    nonisolated(unsafe) public static var emitsSignposts = false
    private static let glassSignposter = OSSignposter(subsystem: "com.uozi.uTerm.glass", category: .pointsOfInterest)

    static var isInstrumentsRecording: Bool { emitsSignposts && glassSignposter.isEnabled }

    /// 程序抓着鼠标时，松手后的惯性滑多远，相对 UIScrollView `.normal`（1 = 和普通滚动一样远；减速率按它的倒数放大）。
    /// user 在 Duo 上的 Claude 全屏界面里比过三档（1 / 0.5 / 0.25）：照 `.normal` 滑得太远，定四分之一。
    /// 留成变量是给测试核「距离跟着它走」，宿主不改它；下一帧惯性起生效。
    public static let defaultProgramMomentumTravel = 0.25
    nonisolated(unsafe) public static var programMomentumTravel = defaultProgramMomentumTravel

    /// 系统滚动途中，引擎的 wakeup 要不要在主线程同步重画（iOS，补丁 #20 的 A/B）。宿主的 Debug 构建按启动参数改它、
    /// 测试按场景改它；生产路径上只读它。下一次 wakeup 起生效。
    public enum ScrollWakeupSyncDraw: String, Sendable, CaseIterable {
        /// 系统滚动动着（手指按着 / 拖着、减速、回弹、对齐）时都不同步重画，wakeup 也不开 display link（补丁 #20）。
        case deferWhileMoving = "moving"
        /// 同上不同步重画，但 wakeup 照旧开 display link（补丁 #20 的第一版：减速慢下来以后屏幕在 60 / 120 Hz 之间跳）。
        case deferDrawKeepLink = "moving-link"
        /// 只在手指按着 / 拖着时不同步重画；松手之后的减速、回弹、对齐照旧同步重画。
        case deferWhileTouching = "touching"
        /// 一律同步重画（补丁 #20 之前）。
        case always = "always"
    }

    public static let defaultScrollWakeupSyncDraw = ScrollWakeupSyncDraw.deferWhileMoving

    /// `.deferWhileMoving` 下，系统滚动快于这个速度（点 / 秒）时引擎的 wakeup 仍然开 display link（屏幕留在 120 Hz，UIKit 每帧都写
    /// contentOffset），慢于它就不开、已经开着的当场停掉（屏幕跟 UIKit 的减速降到 60 Hz，不被 wakeup 拽回 120 Hz 两拍）。
    /// 普通 UIScrollView 在 Duo 上约 400 pt/s 以下自己降到 60 Hz。0 = 一律开（同 `.deferDrawKeepLink`），`.infinity` = 一律不开。
    public static let defaultWakeupDisplayLinkMinimumSpeed: Double = 400
    nonisolated(unsafe) public static var wakeupDisplayLinkMinimumSpeed = defaultWakeupDisplayLinkMinimumSpeed
    nonisolated(unsafe) public static var scrollWakeupSyncDraw = defaultScrollWakeupSyncDraw

    /// 触摸的阶段（signpost `touch` 的第二个数）：0 按下、1 开始拖、2 抬起 / 取消。
    public enum TouchPhase: Int { case down = 0, dragBegan = 1, up = 2 }

    /// 触摸阶段：按「上玻璃」打分时把冻结归到按下未拖 / 拖动 / 松手后。
    static func signpostTouch(_ phase: TouchPhase) {
        guard isInstrumentsRecording else { return }
        let text = String(format: "%.6f %d", CACurrentMediaTime(), phase.rawValue)
        glassSignposter.emitEvent("touch", "\(text, privacy: .public)")
    }

    /// 系统滚动每次 didScroll 的位置（signpost `scroll-offset`，给 `docs/ghostty-eval/glass/` 的真手打分）：时刻、
    /// contentOffset（物理像素）、在不在减速、手指按没按着、视口归谁（恒为 1 = 系统滚动）、哪条路径动的（恒为 1 = didScroll）、
    /// 终端视图的编号（按对象取的短编号，分清多个标签）。字段顺序和换成上游的系统滚动之前一样，老脚本照读。
    static func signpostScrollOffset(px: Double, decelerating: Bool, tracking: Bool, view: ObjectIdentifier) {
        guard isInstrumentsRecording else { return }
        let text = String(format: "%.6f %.1f %d %d 1 1 %d", CACurrentMediaTime(), px, decelerating ? 1 : 0, tracking ? 1 : 0,
                          view.hashValue & 0xFFFF)
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

        /// uTerm 测试用：滚动状态快照。视口位置读引擎（`ghostty_surface_smooth_scroll`）。
        struct UTermScrollState: Equatable, Sendable {
            /// 视口首行行号。
            public let row: Int
            /// 首行顶边之上滚出去的像素（引擎记的小数，`[0, 格子高)`）。
            public let fraction: Double
            /// 系统滚动越界了多少像素（UIScrollView 的橡皮筋，画面层按它平移）：正 = 拉过了顶，负 = 推过了底。
            public let overscrollPixels: Double
            /// 有东西在自己动视口 / 往程序发滚轮：自写的惯性（抓鼠标、备用屏、双指）、系统滚动的减速 / 回弹 / 对齐动画、
            /// 或者 settler 的吸附。
            public let isGliding: Bool
            /// 越界着、手指又没按着：系统滚动的回弹还没走完。
            public let isBouncing: Bool
            /// `fraction` 四舍五入到整像素。
            public var fractionPixels: Int { Int(fraction.rounded()) }
            /// 没有惯性、没有回弹、没有越界，视口在整行上。
            public var isAtRest: Bool { fraction == 0 && overscrollPixels == 0 && !isGliding && !isBouncing }
        }

        /// 没有 surface、或引擎还没有格子高时：行号取滚动条报的、小数为 0。
        var uTermScrollState: UTermScrollState {
            let position = surface?.smoothScrollPosition()
            var over = 0.0
            var gliding = momentumScroll.displayLink != nil || core.scrollSettler.isSnapping
            var bouncing = false
            #if !targetEnvironment(macCatalyst)
                if let driver = systemScroll.driver, let (mapping, _) = systemScrollMapping() {
                    let offsetPx = driver.contentOffset.y * mapping.scale
                    // UIKit 把 contentOffset 取整到 1/UIScreen.scale pt，Duo 内屏上 UIScreen.scale 是 3 而 nativeScale 是 2.807，
                    // 停在底上也可能差零点几个物理像素，不到 1 px 不算越界。
                    let raw = Double(mapping.overscroll(offsetPixels: offsetPx))
                    over = abs(raw) < 1 ? 0 : raw
                    gliding = gliding || systemScrollInMotion
                    bouncing = over != 0 && !(driver.isTracking || driver.isDragging || momentumScroll.panIsActive)
                }
            #endif
            let row = position?.row ?? core.bridge.scrollbar.map { Int($0.offset) } ?? 0
            return UTermScrollState(row: row, fraction: position?.fraction ?? 0,
                                    overscrollPixels: over, isGliding: gliding, isBouncing: bouncing)
        }

        #if !targetEnvironment(macCatalyst)
            /// uTerm 测试用：系统滚动那条路径借的 UIScrollView。
            var uTermSystemScrollView: UIScrollView? { systemScroll.driver }
            /// uTerm 测试用：系统滚动的 delegate（上游把它放在单独的对象上，测试要伪造拖动 / 减速时经它调）。
            var uTermSystemScrollDelegate: (any UIScrollViewDelegate)? { systemScroll.delegate }
            /// uTerm 测试用：现在一下单指拖动会不会归系统滚动。
            var uTermSystemPanWouldBegin: Bool { systemPanWouldBegin }
        #endif
    }
#endif
