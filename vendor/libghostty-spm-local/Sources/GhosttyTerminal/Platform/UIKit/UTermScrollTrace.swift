//
//  UTermScrollTrace.swift
//  uTerm 本地补丁（不在上游）：滚动 / 惯性 / 吸附 / 回弹每一步发出了什么，给真机回归测试逐帧读。
//  关着时（默认）`record` 直接返回，不占开销。
//

import Foundation
import os
import QuartzCore

public enum UTermScrollTrace {
    public struct Event: Sendable {
        /// `CACurrentMediaTime()`。
        public let time: Double
        /// momentum / snap / overscroll / drag / row
        public let kind: String
        /// momentum、snap、drag：这一步发出的像素；overscroll：显示的回弹像素；row：视口首行行号。
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
    // 惯性每一拍（目标 vsync 时刻、累计位移）和每次换画面的 CA 提交各发一条 signpost；外面用 xctrace 录的时候，
    // trace 里就能把「这一拍想显示的位置」对到「它哪个 vsync 上的玻璃」，user 真手甩的时候也能录。
    // 要录的一方自己打开（真机回归用例 / 排查时临时打开；本来想用 `.dynamicTracing` 自动判断有没有人在录，实测在
    // Animation Hitches 模板下探不到）。每条 signpost 约 1 µs，每秒最多一两百条。
    nonisolated(unsafe) public static var emitsSignposts = false
    private static let glassSignposter = OSSignposter(subsystem: "com.uozi.uTerm.glass", category: .pointsOfInterest)

    static var isInstrumentsRecording: Bool { emitsSignposts && glassSignposter.isEnabled }

    /// 惯性开始：初速（px/s）、总位移（px）、时长（s）。
    static func signpostGlideStart(velocity: Double, total: Double, duration: Double) {
        guard isInstrumentsRecording else { return }
        // 数值拼成字符串再发：Instruments 显示数值会加千分位、只留 4 位小数，脚本没法读。
        let text = String(format: "%.6f %.0f %.0f %.4f", CACurrentMediaTime(), velocity, total, duration)
        glassSignposter.emitEvent("glide-start", "\(text, privacy: .public)")
    }

    /// 惯性的一拍：这一拍瞄准的 vsync 时刻、到这一拍为止累计发出的位移（px）。
    static func signpostGlideTick(target: Double, cumulative: Double) {
        guard isInstrumentsRecording else { return }
        let text = String(format: "%.6f %.6f %.0f", CACurrentMediaTime(), target, cumulative)
        glassSignposter.emitEvent("glide", "\(text, privacy: .public)")
    }

    /// 画面层换了一张新画面，并且这次 CA 事务已经提交。
    static func signpostCommit() {
        guard isInstrumentsRecording else { return }
        let text = String(format: "%.6f", CACurrentMediaTime())
        glassSignposter.emitEvent("surface-commit", "\(text, privacy: .public)")
    }

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

    /// 和 SwiftTerm 标签同款：视口位置（物理像素）、在不在减速、手指按没按着。第五个数是谁发的：SwiftTerm 0、
    /// Ghostty 系统滚动 1、Ghostty 自写物理 2（自写物理的甩动由 glide-start / glide 切段，打分脚本不再按这个切）。
    /// 第六个数是哪条代码路径动的位置（1 系统滚动的 didScroll、2 自写拖动 / 惯性、3 对齐时只动引擎、4 当场对齐、5 滚轮），
    /// 第七个数是终端视图的编号（同一进程里第几个建出来的），用来分清多个标签。
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

        /// uTerm 测试用：惯性途中手指落下（`touchesBegan` / `gestureRecognizer(_:shouldReceive:)` 里停惯性的那一句）。
        func uTermTouchDownDuringMomentum() {
            stopMomentumForTouchDown()
        }

        /// uTerm 测试用：滚动状态快照。
        struct UTermScrollState: Equatable, Sendable {
            /// 本地镜像：视口首行行号、首行顶边之上滚出去的像素（见 `MomentumScrollState.modelRow`）。
            public let row: Int
            public let fractionPixels: Int
            /// 手指还按在回弹里时，拖过头的像素（未衰减）。
            public let overscrollPixels: Double
            public let isGliding: Bool
            public let isBouncing: Bool
            /// 没有惯性、没有回弹、没有拖过头，视口在整行上。
            public var isAtRest: Bool { fractionPixels == 0 && overscrollPixels == 0 && !isGliding && !isBouncing }
        }

        var uTermScrollState: UTermScrollState {
            var over = Double(momentumScroll.overscrollRaw)
            var gliding = momentumScroll.displayLink != nil
            #if !targetEnvironment(macCatalyst)
                if let driver = systemScroll.driver, let g = systemScrollGeometry() {
                    let offsetPx = Double(driver.contentOffset.y * g.scale)
                    let maxPx = Double(g.viewMax)
                    // UIKit 把 contentOffset 取整到 1/UIScreen.scale pt，Duo 内屏上 UIScreen.scale 是 3 而 nativeScale 是 2.807，
                    // 停在底上也可能差零点几个物理像素，不到 1 px 不算越界。
                    if offsetPx < -1 { over = -offsetPx } else if offsetPx > maxPx + 1 { over = maxPx - offsetPx }
                    gliding = gliding || systemScrollInMotion
                }
            #endif
            return UTermScrollState(row: momentumScroll.modelRow, fractionPixels: momentumScroll.modelFrac,
                                    overscrollPixels: over, isGliding: gliding, isBouncing: momentumScroll.bounceLink != nil)
        }

        #if !targetEnvironment(macCatalyst)
            /// uTerm 测试用：系统滚动那条路径借的 UIScrollView。
            var uTermSystemScrollView: UIScrollView? { systemScroll.driver }
            /// uTerm 测试用：现在一下单指拖动会不会归系统滚动。
            var uTermSystemPanWouldBegin: Bool { systemPanWouldBegin }
        #endif
    }

    /// 惯性期间「画面哪一刻真正提交给 Core Animation」：在主 runloop 上 CA 提交之后（order 排在 CA 的 2000000 之后）
    /// 看 Ghostty 那个 IOSurfaceLayer 的 contents 换没换，换了就记一笔（trace 的 commit，和打开输入日志时的
    /// `uterm-commit` 行）。同一帧里惯性发出位移的时刻、那一帧的 targetTimestamp 也记着（`uterm-glide`），两者一对就知道
    /// 每一步有没有赶在它该显示的 vsync 之前上屏。只在测试打开 trace 或排查时打开输入日志时装，平时零开销。
    @MainActor
    enum UTermCommitWatch {
        nonisolated(unsafe) private static var observer: CFRunLoopObserver?
        nonisolated(unsafe) private static weak var layer: CALayer?
        nonisolated(unsafe) private static var lastContents: ObjectIdentifier?
        nonisolated(unsafe) private static var until: CFTimeInterval = 0
        /// 一次性的「画面层换了 IOSurface 就告诉我」：惯性交接用（见 glideFrame），不受 isWanted 限制。
        nonisolated(unsafe) private static var oneShot: (layer: CALayer?, baseline: ObjectIdentifier?, until: CFTimeInterval,
                                                         handler: @MainActor (CFTimeInterval) -> Void)?

        static var isWanted: Bool {
            UTermScrollTrace.isEnabled || TerminalDebugLog.isEnabled || UTermScrollTrace.isInstrumentsRecording
        }

        /// 从现在起再看 `seconds` 秒（每个惯性帧续一次）。
        static func watch(_ view: UIView, seconds: CFTimeInterval = 0.25) {
            guard isWanted else { return }
            until = CACurrentMediaTime() + seconds
            layer = surfaceLayer(in: view.layer)   // 每次重找：多个标签各有各的 layer，层级很浅
            installObserver()
        }

        /// `seconds` 秒内画面层的 contents 一离开 `baseline` 就（在那次 CA 提交之后）调一次 `handler(提交时刻)`；超时不调。
        static func onContentsChange(of view: UIView, from baseline: ObjectIdentifier?, within seconds: CFTimeInterval,
                                     _ handler: @escaping @MainActor (CFTimeInterval) -> Void) {
            oneShot = (surfaceLayer(in: view.layer), baseline, CACurrentMediaTime() + seconds, handler)
            installObserver()
        }

        private static func installObserver() {
            guard observer == nil else { return }
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, 2_000_001
            ) { _, _ in
                MainActor.assumeIsolated { UTermCommitWatch.afterCommit() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }

        private static func afterCommit() {
            let now = CACurrentMediaTime()
            if let shot = oneShot {
                let current = shot.layer?.contents.map { ObjectIdentifier($0 as AnyObject) }
                if now > shot.until {
                    oneShot = nil
                } else if current != shot.baseline {
                    oneShot = nil
                    shot.handler(now)
                }
            }
            if isWanted, let contents = layer?.contents {
                let id = ObjectIdentifier(contents as AnyObject)
                if id != lastContents {
                    lastContents = id
                    UTermScrollTrace.record("commit", now)
                    UTermScrollTrace.signpostCommit()
                    TerminalDebugLog.log(.input, "uterm-commit t=\(String(format: "%.5f", now))")
                }
            }
            if now > until, oneShot == nil, let observer {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                self.observer = nil
            }
        }

        /// 视图里 Ghostty 画面层当前挂着的 IOSurface 的身份（每交一帧换一个）。
        static func contentsIdentity(of view: UIView) -> ObjectIdentifier? {
            surfaceLayer(in: view.layer)?.contents.map { ObjectIdentifier($0 as AnyObject) }
        }

        private static func surfaceLayer(in root: CALayer) -> CALayer? {
            if NSStringFromClass(type(of: root)).contains("IOSurface") { return root }
            for sub in root.sublayers ?? [] {
                if let found = surfaceLayer(in: sub) { return found }
            }
            return nil
        }
    }
#endif
