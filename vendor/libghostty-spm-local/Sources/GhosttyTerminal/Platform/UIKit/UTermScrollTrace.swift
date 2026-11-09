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
    // 由宿主打开（uTerm 的 Ghostty 试用入口打开；本来想用 `.dynamicTracing` 自动判断有没有人在录，实测在
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

    /// 测试用 A/B 开关：true = 回到第五轮的行为（引擎 wakeup 也让协调器在主线程同步整帧重画）。默认 false。
    nonisolated(unsafe) public static var legacyWakeupSyncDraw = false

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
