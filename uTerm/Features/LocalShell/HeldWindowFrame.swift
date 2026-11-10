import AppKit
import SwiftUI

/// 窗口在屏幕上的位置与大小，跟终端布局一起存进 holder 归属（`HeldSessionLayout.window`）。
///
/// SwiftUI 每个 WindowGroup 只自动存一份窗口位置，其余窗口重启后都按 `defaultSize` 打开：大窗口里的分屏
/// 接回来被挤得很窄，里面的全屏程序（Claude Code）按窄尺寸重排一段输出，拉宽了那段也还是窄的。
nonisolated struct HeldWindowFrame: Codable, Equatable, Sendable {
    /// AppKit 全局坐标（主屏左下角为原点）。
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// 最后一次成为前台窗口的时刻（Unix 秒）。接回时按它叠放，大的在上。
    var activatedAt: Double

    init(_ rect: CGRect, activatedAt: Double) {
        x = rect.minX
        y = rect.minY
        width = rect.width
        height = rect.height
        self.activatedAt = activatedAt
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// 现在的屏幕上该把它摆在哪。`screens` 是各屏的可见区域（去掉菜单栏与 Dock），第一个是主屏。
    ///
    /// 放在和它重叠最多的那块屏上；一块都不重叠（那块显示器没了）就居中放到主屏。比屏幕大就缩到屏幕大小
    /// （但不小于窗口的最小尺寸，除非屏幕本身更小），伸出屏幕的部分推回来。
    static func placement(of frame: CGRect, screens: [CGRect], minSize: CGSize) -> CGRect {
        guard let main = screens.first, frame.width > 0, frame.height > 0 else { return frame }
        func overlap(_ screen: CGRect) -> CGFloat {
            let common = screen.intersection(frame)
            return common.isNull ? 0 : common.width * common.height
        }
        let best = screens.max { overlap($0) < overlap($1) } ?? main
        let onScreen = overlap(best) > 0
        let screen = onScreen ? best : main
        let width = min(max(frame.width, minSize.width), screen.width)
        let height = min(max(frame.height, minSize.height), screen.height)
        guard onScreen else {
            return CGRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height)
        }
        let x = min(max(frame.minX, screen.minX), screen.maxX - width)
        let y = min(max(frame.minY, screen.minY), screen.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// 一个终端窗口的位置跟踪：变了就报给布局写入（`HeldLayoutWriter.noteWindow`）；接回时把存的位置还原一次。
@MainActor
final class HeldWindowTracker {
    /// 窗口的位置变了（挪动、改大小、成为前台）。
    var onChange: ((HeldWindowFrame) -> Void)?
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var activatedAt: Double = 0
    private var restoring: HeldWindowFrame?
    /// 同一个窗口只还原一次：之后的位置都是用户自己摆的（SwiftUI 自己恢复的那一份也只在开窗时套一次）。
    private var didRestore = false
    private let screens: @MainActor () -> [CGRect]

    init(screens: @escaping @MainActor () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) }) {
        self.screens = screens
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// 接回时按存的位置还原（窗口还没挂上就等挂上）。只有第一次有效。
    func restore(_ frame: HeldWindowFrame?) {
        guard !didRestore, let frame else { return }
        restoring = frame
        applyRestoreIfReady()
    }

    func attach(_ window: NSWindow?) {
        guard window !== self.window else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        self.window = window
        guard let window else { return }
        if window.isKeyWindow { activatedAt = Date().timeIntervalSince1970 }
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activatedAt = Date().timeIntervalSince1970
                self?.report()
            }
        })
        applyRestoreIfReady()
        report()
    }

    /// 现在的位置。全屏、最小化时不算（还原时套回去不对）。
    var current: HeldWindowFrame? {
        guard let window, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return nil }
        return HeldWindowFrame(window.frame, activatedAt: activatedAt)
    }

    private func report() {
        guard restoring == nil, let current else { return }
        onChange?(current)
    }

    private func applyRestoreIfReady() {
        guard let saved = restoring, let window, !didRestore else { return }
        didRestore = true
        // 等这一轮结束再摆：SwiftUI 开窗时自己会按它存的那一份定位置，要在它之后。
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.restoring = nil
            self.activatedAt = saved.activatedAt
            let minSize = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
            let target = HeldWindowFrame.placement(of: saved.rect, screens: self.screens(), minSize: minSize)
            window.setFrame(target, display: true)
            HeldWindowStacking.restored(window, activatedAt: saved.activatedAt)
            self.report()
        }
    }
}

/// 接回的几个窗口按上次的前后叠放：最后用过的在最上面。窗口是一个个开出来的，每还原一个重排一次。
@MainActor
enum HeldWindowStacking {
    private struct Entry {
        weak var window: NSWindow?
        let activatedAt: Double
        let restoredAt: ContinuousClock.Instant
    }
    private static var entries: [Entry] = []
    /// 只排这一阵接回的窗口：启动时窗口是陆续开出来的，过后用户自己摆的前后不再去动。
    private static let settlingPeriod: Duration = .seconds(10)

    static func restored(_ window: NSWindow, activatedAt: Double) {
        let now = ContinuousClock.now
        entries.removeAll { entry in
            guard let other = entry.window else { return true }
            // 关掉的窗口不能被 orderFront 重新显示出来。
            return other === window || !other.isVisible || now - entry.restoredAt > settlingPeriod
        }
        entries.append(Entry(window: window, activatedAt: activatedAt, restoredAt: now))
        let ordered = order(entries.compactMap { entry in entry.window.map { ($0, entry.activatedAt) } })
        let key = NSApp.keyWindow
        let restoredIsKey = key == nil || ordered.contains { $0 === key }
        for window in ordered { window.orderFront(nil) }
        // 别抢走用户已经在用的别的窗口（欢迎窗口等）的焦点。
        if restoredIsKey, let top = ordered.last { top.makeKeyAndOrderFront(nil) }
    }

    /// 从下到上的顺序。
    nonisolated static func order<W>(_ windows: [(W, Double)]) -> [W] {
        windows.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
    }
}

/// 把所在窗口交给 `HeldWindowTracker`。
struct HeldWindowTrackerBinding: NSViewRepresentable {
    let tracker: HeldWindowTracker

    func makeNSView(context: Context) -> ProbeView { ProbeView(tracker: tracker) }

    func updateNSView(_ nsView: ProbeView, context: Context) { tracker.attach(nsView.window) }

    final class ProbeView: NSView {
        let tracker: HeldWindowTracker

        init(tracker: HeldWindowTracker) {
            self.tracker = tracker
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tracker.attach(window)
        }
    }
}
