import Darwin
import GhosttyTerminal
import ObjectiveC
import QuartzCore
import SwiftTerm
import UIKit
import XCTest
@testable import uTermMobile

// GhosttyKit spike（docs/ghostty-eval/ios-spike.md）的探针夹具：
// - `ThreadCPU`：每条线程的 CPU（Ghostty 有自己的渲染 / IO 线程、解析在 GCD 队列上，只量主线程会漏账）；
// - `GhosttyPresentLog`：Ghostty 实际交给 Core Animation 的帧（`IOSurfaceLayer.setContents:`）；
// - `SwiftTermDrawLog`：SwiftTerm 的 `draw(_:)`（与 `TerminalScrollWhileOutputProbeTests` 同一手法）；
// - `GhosttyProbeHost` / `SwiftTermProbeHost`：同尺寸、同字号、同配色地挂上屏。

// MARK: - 线程 CPU

/// 进程里每条线程累计的 CPU。
///
/// 当前线程（主线程）用 `CLOCK_THREAD_CPUTIME_ID`；别的线程只能用 `thread_info(THREAD_EXTENDED_INFO)` 读——
/// Darwin 没有 `pthread_getcpuclockid`。两者都是内核记的线程 CPU 时间（纳秒精度），不是数心跳。
nonisolated enum ThreadCPU {
    struct Thread: Hashable {
        let id: UInt64
        let name: String
        let seconds: Double
    }

    /// 调用线程的 CPU 秒数（`CLOCK_THREAD_CPUTIME_ID`）。
    static func current() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
    }

    static func currentThreadID() -> UInt64 {
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        return tid
    }

    /// 所有线程的快照，按线程 id 索引。
    static func snapshot() -> [UInt64: Thread] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [:] }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var result: [UInt64: Thread] = [:]
        for index in 0..<Int(count) {
            let port = list[index]
            var ident = thread_identifier_info()
            var identCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<natural_t>.size)
            let identOK = withUnsafeMutablePointer(to: &ident) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identCount)) {
                    thread_info(port, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identCount)
                }
            }
            var ext = thread_extended_info()
            var extCount = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<natural_t>.size)
            let extOK = withUnsafeMutablePointer(to: &ext) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(extCount)) {
                    thread_info(port, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extCount)
                }
            }
            guard identOK == KERN_SUCCESS, extOK == KERN_SUCCESS else { continue }
            let name = withUnsafeBytes(of: ext.pth_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            result[ident.thread_id] = Thread(id: ident.thread_id, name: name,
                                             seconds: Double(ext.pth_user_time + ext.pth_system_time) / 1e9)
        }
        return result
    }

    /// 一段时间里各线程用掉的 CPU（毫秒），只列用过 0.05ms 以上的。新出生的线程从 0 算。
    struct Delta {
        let mainID: UInt64
        let perThread: [(name: String, id: UInt64, ms: Double)]

        var mainMS: Double { perThread.first { $0.id == mainID }?.ms ?? 0 }
        var otherMS: Double { perThread.filter { $0.id != mainID }.reduce(0) { $0 + $1.ms } }
        var totalMS: Double { perThread.reduce(0) { $0 + $1.ms } }
        /// 名字里带 `match` 的线程合计。
        func ms(matching match: String) -> Double {
            perThread.filter { $0.id != mainID && $0.name.localizedCaseInsensitiveContains(match) }.reduce(0) { $0 + $1.ms }
        }

        var line: String {
            perThread.sorted { $0.ms > $1.ms }.prefix(8).map {
                String(format: "%@=%.1f", $0.id == mainID ? "main" : ($0.name.isEmpty ? "tid\($0.id)" : $0.name), $0.ms)
            }.joined(separator: " ")
        }
    }

    static func delta(from start: [UInt64: Thread], to end: [UInt64: Thread], mainID: UInt64) -> Delta {
        let rows = end.values.compactMap { thread -> (String, UInt64, Double)? in
            let ms = (thread.seconds - (start[thread.id]?.seconds ?? 0)) * 1000
            return ms > 0.05 ? (thread.name, thread.id, ms) : nil
        }
        return Delta(mainID: mainID, perThread: rows.map { (name: $0.0, id: $0.1, ms: $0.2) })
    }
}

// MARK: - 帧计数

/// Ghostty 每交一帧就给 `IOSurfaceLayer`（补丁 0005：iOS 上是 `CAIOSurfaceLayer` 的运行时子类）设一次 contents。
/// 在这个类上加一个 `setContents:` 覆写来记时刻；类是第一个 surface 建出来时才注册的，所以要在建好之后装。
nonisolated enum GhosttyPresentLog {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var times: [Double] = []
    private nonisolated(unsafe) static var offMain = 0
    private nonisolated(unsafe) static var rawCalls = 0
    private nonisolated(unsafe) static var nilCalls = 0
    private nonisolated(unsafe) static var installed = false

    @discardableResult
    static func installIfPossible() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if installed { return true }
        guard let cls = NSClassFromString("IOSurfaceLayer") else { return false }
        let selector = NSSelectorFromString("setContents:")
        guard let inherited = class_getInstanceMethod(cls, selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(inherited), to: Setter.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { layer, contents in
            GhosttyPresentLog.record(isNil: contents == nil)
            original(layer, selector, contents)
        }
        let imp = imp_implementationWithBlock(block)
        if !class_addMethod(cls, selector, imp, method_getTypeEncoding(inherited)) {
            method_setImplementation(inherited, imp)
        }
        installed = true
        return true
    }

    /// 一次 present 里 `setContents:` 会来两次（第一轮实测：整屏刷新时 244 拍 488 次、成对出现）。
    /// 2ms 内的连续调用算同一帧——120Hz 下两帧最少隔 8.3ms，不会误并。
    private static func record(isNil: Bool) {
        let now = CACurrentMediaTime()
        let main = Foundation.Thread.isMainThread
        lock.lock()
        rawCalls += 1
        if isNil { nilCalls += 1 }
        if !isNil, times.last.map({ now - $0 > 0.002 }) ?? true {
            times.append(now)
            if !main { offMain += 1 }
        }
        lock.unlock()
    }

    static func reset() {
        lock.lock(); times.removeAll(); offMain = 0; rawCalls = 0; nilCalls = 0; lock.unlock()
    }

    static func read() -> (times: [Double], offMain: Int) {
        lock.lock(); defer { lock.unlock() }
        return (times, offMain)
    }

    /// `setContents:` 的原始调用次数与其中设成 nil 的次数（核对去重口径用）。
    static func rawCounts() -> (calls: Int, nils: Int) {
        lock.lock(); defer { lock.unlock() }
        return (rawCalls, nilCalls)
    }
}

/// SwiftTerm 的每次 `draw(_:)`：开始时刻与耗时（ms，主线程 CPU 时间，`CLOCK_THREAD_CPUTIME_ID`）。
@MainActor
enum SwiftTermDrawLog {
    nonisolated(unsafe) static var draws: [(at: Double, cpuMS: Double)] = []
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let method = class_getInstanceMethod(SwiftTerm.TerminalView.self, #selector(UIView.draw(_:)))!
        typealias Draw = @convention(c) (AnyObject, Selector, CGRect) -> Void
        let call = unsafeBitCast(method_getImplementation(method), to: Draw.self)
        let timed: @convention(block) (AnyObject, CGRect) -> Void = { view, rect in
            let at = CACurrentMediaTime()
            let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            call(view, #selector(UIView.draw(_:)), rect)
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
            SwiftTermDrawLog.draws.append((at, cpu))
        }
        method_setImplementation(method, imp_implementationWithBlock(timed))
    }
}

// MARK: - 语料

nonisolated enum TerminalSpikeCorpus {
    /// 一屏 Claude Code 跑过一阵的内容：每行都不同、铺满不溢出（同 `TerminalDrawCostProbeTests.screen`）。
    static func screen(rows: Int, salt: Int) -> String {
        let colors = ["32", "31", "36", "33", "38;2;215;119;87", "90"]
        return (0..<rows).map { index in
            "\u{1B}[\(index + 1);1H\u{1B}[2K\u{1B}[\(colors[(index + salt) % colors.count])m\(index % 2 == 0 ? "+" : "⎿")"
                + " let v\(salt % 10) = f(\(index % 100))\u{1B}[0m \u{1B}[2m// 说明\u{1B}[0m"
                + " \u{1B}[1mApp/File\(index % 100).swift\u{1B}[0m"
        }.joined()
    }

    /// Claude Code 思考时的一帧（同 `TerminalScrollWhileOutputProbeTests.claudeFrame`）。
    static func claudeFrame(_ n: Int, cols: Int) -> String {
        let glyph = ["✢", "✳", "✶", "✻", "✽"][n % 5]
        let box = String(repeating: "─", count: max(0, cols - 2))
        return "\u{1B}[?2026h"
            + "\u{1B}[6A\r\u{1B}[2K\u{1B}[38;2;215;119;87m\(glyph) Thinking…\u{1B}[0m "
            + "\u{1B}[2m(\(n / 10)s · ↓ \(n * 7) tokens · esc to interrupt)\u{1B}[0m\r\n"
            + "\u{1B}[2K\r\n"
            + "\u{1B}[2K\u{1B}[2m╭\(box)╮\u{1B}[0m\r\n"
            + "\u{1B}[2K\u{1B}[2m│\u{1B}[0m > \u{1B}[7m \u{1B}[0m\u{1B}[\(cols)G\u{1B}[2m│\u{1B}[0m\r\n"
            + "\u{1B}[2K\u{1B}[2m╰\(box)╯\u{1B}[0m\r\n"
            + "\u{1B}[2K  \u{1B}[2m? for shortcuts\u{1B}[0m"
            + "\u{1B}[?2026l"
    }

    /// 回滚区：带色的 diff、中文说明（同 `TerminalScrollWhileOutputProbeTests.history`）。
    static func history(lines: Int, cols: Int) -> String {
        let colors = ["32", "31", "36", "33", "90"]
        let body = (0..<lines).map { i -> String in
            let text = "\(i % 2 == 0 ? "+" : "⎿") let v\(i % 10) = f(\(i)) // 说明 App/File\(i % 100).swift"
            return "\u{1B}[\(colors[i % colors.count])m\(String(text.prefix(cols - 2)))\u{1B}[0m\r\n"
        }.joined()
        return body + String(repeating: "\r\n", count: 6)
    }

    /// `cat` 一个大日志：`bytes` 字节左右的带色行。
    static func flood(bytes: Int) -> Data {
        var out = Data()
        var i = 0
        while out.count < bytes {
            out.append(Data("\u{1B}[3\(i % 7 + 1)m\(i) 2026-11-09T22:\(i % 60):00Z INFO request id=\(i * 7919) path=/api/v1/items/\(i % 977) 说明 ok\u{1B}[0m\r\n".utf8))
            i += 1
        }
        return out
    }
}

// MARK: - 宿主

/// 一扇可见的窗，挂一个终端视图。`.alert` 层级盖住宿主 App 的界面（不然宿主的 SwiftUI 也在画，混进读数）。
@MainActor
func makeSpikeWindow(size: CGSize) throws -> UIWindow {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    window.windowLevel = .alert + 1
    window.backgroundColor = .black
    window.isHidden = false
    return window
}

/// GhosttyKit 那一侧。整个测试进程共用一个 ghostty app（`TerminalController`），和生产时一样。
@MainActor
final class GhosttyProbeHost: NSObject, TerminalSurfaceScrollbarDelegate {
    static let controller = GhosttyTerminalBridge.makeController(dark: true,
                                                                 fontSize: GhosttyTerminalBridge.ghosttyFontSize(points: 11))

    let window: UIWindow
    let bridge: GhosttyTerminalBridge
    var view: MGhosttyTerminalView { bridge.view }
    private(set) var scrollbar: TerminalScrollbar?
    private(set) var scrollbarUpdates = 0

    init(size: CGSize = CGSize(width: 393, height: 760)) throws {
        window = try makeSpikeWindow(size: size)
        bridge = GhosttyTerminalBridge(controller: Self.controller, frame: CGRect(origin: .zero, size: size))
        super.init()
        bridge.view.delegate = self
        bridge.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(bridge.view)
    }

    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        self.scrollbar = scrollbar
        scrollbarUpdates += 1
    }

    /// 等 surface 建好、第一帧交出去、网格报上来。
    func waitUntilReady(timeout: Double = 5) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            GhosttyPresentLog.installIfPossible()
            if view.surface != nil, bridge.grid != nil, !GhosttyPresentLog.read().times.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        // 第一次报上来的网格可能还是按建 surface 那一刻的尺寸算的（第一轮实测先报 30×10），等它停稳。
        var last = "\(grid)"
        var stableSince = CACurrentMediaTime()
        while CACurrentMediaTime() < deadline, CACurrentMediaTime() - stableSince < 0.3 {
            try await Task.sleep(for: .milliseconds(20))
            if "\(grid)" != last { last = "\(grid)"; stableSince = CACurrentMediaTime() }
        }
        if view.surface != nil, bridge.grid != nil { return }
        XCTFail("Ghostty surface 没就绪：surface=\(view.surface != nil) grid=\(String(describing: bridge.grid)) presents=\(GhosttyPresentLog.read().times.count)")
    }

    /// 喂字节并等解析完（`waitForPendingOutput` 在主线程上会边等边 tick app）。
    func feedAndWait(_ text: String) {
        bridge.feed(Data(text.utf8))
        bridge.session.waitForPendingOutput()
    }

    var viewportText: String { bridge.session.readViewportText() ?? "" }

    var grid: (cols: Int, rows: Int) { bridge.grid ?? (0, 0) }

    func close() {
        bridge.view.removeFromSuperview()
        window.isHidden = true
    }
}

/// SwiftTerm 那一侧：和 `SwiftTermView.makeUIView` 一样装配色、关附加栏，挂在 `MTerminalContainerView` 里。
@MainActor
final class SwiftTermProbeHost {
    let window: UIWindow
    let view: MTerminalView
    let container: MTerminalContainerView

    init(size: CGSize = CGSize(width: 393, height: 760)) throws {
        window = try makeSpikeWindow(size: size)
        view = MTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        view.contentInsetAdjustmentBehavior = .never
        view.inputAccessoryView = nil
        view.caretViewTracksFocus = false
        let scheme = MTerminalColors.resolve(dark: true)
        TerminalAppearance.applyColors(to: view, scheme: scheme)
        TerminalAppearance.applyCaretColors(to: view, scheme: scheme, shape: .block)
        view.backgroundColor = scheme.backgroundColor
        view.getTerminal().changeScrollback(RemoteConstants.snapshotScrollback)
        container = MTerminalContainerView(terminalView: view, fontSize: 11)
        container.frame = window.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(container)
        container.layoutIfNeeded()
    }

    var grid: (cols: Int, rows: Int) { (view.getTerminal().cols, view.getTerminal().rows) }

    func close() {
        container.removeFromSuperview()
        window.isHidden = true
    }
}
