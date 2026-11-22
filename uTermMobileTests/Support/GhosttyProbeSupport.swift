import Darwin
import GhosttyTerminal
import ObjectiveC
import QuartzCore
import UIKit
import UIKit.UIGestureRecognizerSubclass
import XCTest
@testable import uTermMobile

// GhosttyKit spike（docs/ghostty-eval/ios-spike.md）的探针夹具：
// - `ThreadCPU`：每条线程的 CPU（Ghostty 有自己的渲染 / IO 线程、解析在 GCD 队列上，只量主线程会漏账）；
// - `GhosttyPresentLog`：Ghostty 实际交给 Core Animation 的帧（`IOSurfaceLayer.setContents:`）；
// - `GhosttyProbeHost`：按固定尺寸、字号、配色把一条终端挂上屏。
//
// 换引擎之前这里还有对照组的夹具（旧引擎的 `draw(_:)` 计时与宿主）；旧引擎的视图类删掉之后一并去掉，
// 历史读数留在 docs/ghostty-eval/ 里。

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
    /// 和 `times` 一一对应：这一帧是不是在主线程上交的（主线程同步重画 = true，渲染线程自己画 = false）。
    private nonisolated(unsafe) static var onMain: [Bool] = []
    private nonisolated(unsafe) static var offMain = 0
    private nonisolated(unsafe) static var rawCalls = 0
    private nonisolated(unsafe) static var nilCalls = 0
    private nonisolated(unsafe) static var installed = false
    /// 每个 layer（= 每个 surface）各交了几帧，同一套 2ms 去重。多终端探针按它分账。
    private nonisolated(unsafe) static var perLayer: [ObjectIdentifier: (count: Int, last: Double)] = [:]

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
            GhosttyPresentLog.record(isNil: contents == nil, layer: ObjectIdentifier(layer))
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
    private static func record(isNil: Bool, layer: ObjectIdentifier) {
        let now = CACurrentMediaTime()
        let main = Foundation.Thread.isMainThread
        lock.lock()
        rawCalls += 1
        if isNil { nilCalls += 1 }
        if !isNil {
            let entry = perLayer[layer] ?? (0, 0)
            if now - entry.last > 0.002 { perLayer[layer] = (entry.count + 1, now) } else { perLayer[layer] = (entry.count, now) }
        }
        if !isNil, times.last.map({ now - $0 > 0.002 }) ?? true {
            times.append(now)
            onMain.append(main)
            if !main { offMain += 1 }
        }
        lock.unlock()
    }

    static func reset() {
        lock.lock(); times.removeAll(); onMain.removeAll(); offMain = 0; rawCalls = 0; nilCalls = 0; perLayer.removeAll(); lock.unlock()
    }

    static func read() -> (times: [Double], offMain: Int) {
        lock.lock(); defer { lock.unlock() }
        return (times, offMain)
    }

    /// 每一帧交出的时刻和是不是主线程交的。
    static func readThreads() -> [(time: Double, main: Bool)] {
        lock.lock(); defer { lock.unlock() }
        return zip(times, onMain).map { (time: $0, main: $1) }
    }

    /// 各 layer 交的帧数（去重后），按帧数从多到少。
    static func perLayerCounts() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return perLayer.values.map(\.count).sorted(by: >)
    }

    /// `setContents:` 的原始调用次数与其中设成 nil 的次数（核对去重口径用）。
    static func rawCounts() -> (calls: Int, nils: Int) {
        lock.lock(); defer { lock.unlock() }
        return (rawCalls, nilCalls)
    }
}

// MARK: - 语料

nonisolated enum TerminalSpikeCorpus {
    /// 一屏 Claude Code 跑过一阵的内容：带色的 diff、路径、中文、界面符号，每行都不同、接近铺满但不溢出
    ///（Claude Code 按终端宽度自己断行、输出硬换行；溢出折行的话整屏连成一个软折行段落，就不是它的情形了）。
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

// MARK: - surface 与影子终端逐行比

/// surface 的视口文字（`InMemoryTerminalSession.readViewportText()`）和影子终端的（`ShadowTerminal.viewportText()`）逐行比。
/// 行尾空白不算（两边读法不同）。另外容忍 GhosttyKit `readViewportText` 的一个读法缺陷（M4 查出来的，不是终端状态差异）：
/// 一行的最后一格是 spacer head（宽字符放不下、折到了下一行）时，surface 读出来的这一行行尾会多带上下一行开头那个宽字符。
nonisolated enum GhosttyViewportDiff {
    static func trimmedLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { ShadowTerminal.trimmingTrailingWhitespace(String($0)) }
    }

    /// nil = 一致；否则是第一处不同的说明。
    static func firstDifference(surface: String, shadow: String) -> String? {
        let a = trimmedLines(surface), b = trimmedLines(shadow)
        guard a.count == b.count else { return "行数不同 surface=\(a.count) shadow=\(b.count)" }
        for index in a.indices where a[index] != b[index] {
            if index + 1 < b.count, let spill = b[index + 1].first, a[index] == b[index] + String(spill) { continue }
            return "第 \(index) 行不同 surface=«\(a[index])» shadow=«\(b[index])»"
        }
        return nil
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

/// 测试期间有没有真手指碰过这扇窗。
///
/// 探针从不合成触摸事件（滚动是直接改 contentOffset / 调手势的处理函数），所以这个识别器的 `touchesBegan` 只要来了，
/// 就是有人碰了真机的屏幕：窗口盖在最上层，终端视图里借来的 UIScrollView 会真的跟着手指滚、松手后真的减速，
/// 量位移的探针读到的就是「测试喂的步子 + 手指的拖动和惯性」。2026-11-10 在 Duo 上
/// `GhosttySmoothScrollPixelTests.testPrecisionScrollMovesByPixels` 四次里有一次中途多走了约 12 行、之后一串越来越小的位移
///（先是几步不规则的大位移，再是一条衰减曲线），当时没有这个记录、事后没法分辨；现在碰了就记下来，宿主关掉时报出来。
/// 它只看不拦：不取消、不延迟触摸，自己永远不识别成功。
final class RealTouchWatch: UIGestureRecognizer {
    private(set) var touchesSeen = 0
    private(set) var firstAt: Double?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        touchesSeen += touches.count
        if firstAt == nil { firstAt = CACurrentMediaTime() }
        state = .failed
    }

    override func canPrevent(_: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by _: UIGestureRecognizer) -> Bool { false }
}

/// GhosttyKit 那一侧。整个测试进程共用一个 ghostty app（`TerminalController`），和生产时一样。
@MainActor
final class GhosttyProbeHost: NSObject, TerminalSurfaceScrollbarDelegate {
    static let controller = GhosttyTerminalBridge.makeController(
                                                                 fontSize: GhosttyTerminalBridge.ghosttyFontSize(points: 11))

    let window: UIWindow
    let bridge: GhosttyTerminalBridge
    var view: MGhosttyTerminalView { bridge.view }
    private(set) var scrollbar: TerminalScrollbar?
    private(set) var scrollbarUpdates = 0
    /// 测试期间真手指碰没碰过这扇窗（见 `RealTouchWatch`）；`close()` 时碰过就判这条用例失败。
    let touchWatch = RealTouchWatch()
    private let openedAt = CACurrentMediaTime()

    /// `keepsBridgeDelegate`：留着桥自己的委托（点链接、查找的回报），不换成探针（`scrollbar` 就收不到了）。
    init(size: CGSize = CGSize(width: 393, height: 760), keepsBridgeDelegate: Bool = false) throws {
        window = try makeSpikeWindow(size: size)
        bridge = GhosttyTerminalBridge(controller: Self.controller, frame: CGRect(origin: .zero, size: size))
        super.init()
        if !keepsBridgeDelegate { bridge.view.delegate = self }
        bridge.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(bridge.view)
        window.addGestureRecognizer(touchWatch)
    }

    func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
        self.scrollbar = scrollbar
        scrollbarUpdates += 1
    }

    /// 等 surface 建好、第一帧交出去、网格报上来，并且画面已经在吃实时字节（`isSurfaceReady` 之前喂的只进影子，
    /// 就绪后由一次回放补进 surface——回放排在后台队列上，这里连它一起等完）。
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
        while CACurrentMediaTime() < deadline, !(bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface) {
            try await Task.sleep(for: .milliseconds(20))
        }
        if view.surface != nil, bridge.grid != nil, bridge.isSurfaceReady, bridge.outputPump.isFeedingSurface { return }
        XCTFail("Ghostty surface 没就绪：surface=\(view.surface != nil) grid=\(String(describing: bridge.grid)) "
            + "ready=\(bridge.isSurfaceReady) feeding=\(bridge.outputPump.isFeedingSurface) presents=\(GhosttyPresentLog.read().times.count)")
    }

    /// 喂字节并等解析完（`waitForPendingOutput` 在主线程上会边等边 tick app）。
    func feedAndWait(_ text: String) {
        bridge.feed(Data(text.utf8))
        bridge.session.waitForPendingOutput()
    }

    var viewportText: String { bridge.session.readViewportText() ?? "" }

    var grid: (cols: Int, rows: Int) { bridge.grid ?? (0, 0) }

    func close() {
        if touchWatch.touchesSeen > 0 {
            XCTFail(String(format: "测试期间有真手指碰了屏幕（%d 次，第一次在宿主建好后 %.1f s）：终端会跟着手指滚动、松手后还有惯性，"
                + "这一条的读数作废，别碰手机重跑", touchWatch.touchesSeen, (touchWatch.firstAt ?? openedAt) - openedAt))
        }
        bridge.view.removeFromSuperview()
        window.isHidden = true
    }
}
