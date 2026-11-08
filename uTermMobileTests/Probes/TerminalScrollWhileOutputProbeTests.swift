import ObjectiveC
import SwiftData
import SwiftTerm
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// Claude Code 思考时在终端里来回滚，比滚静止的屏「稍微有点卡」：多出来的是哪一笔账。
///
/// 整个工作区界面（标签条、键盘条、终端）挂上屏，假后端每 100ms 吐一帧 Claude 思考时的输出
/// （DEC 2026 同步帧：重画转圈行、计时、输入框和底栏），手指滚动由 `CADisplayLink` 每拍推一小步，
/// 在靠底部的两屏里往返。三档同一次运行里比：
/// - 静止：没有输出；
/// - 输出、标题不变；
/// - 输出、每帧改标题（Claude Code 思考时标题里的转圈字符也在动）。
/// 只比同轮相对值，绝对毫秒只打印。
@MainActor
final class TerminalScrollWhileOutputProbeTests: XCTestCase {
    /// 每次 `draw(_:)` 的开始时刻与耗时（秒）。
    private nonisolated(unsafe) static var drawLog: [(at: Double, ms: Double)] = []
    private var restoreDraw: (() -> Void)?

    /// 手指按着期间为真：`TerminalView.isTracking` 读它。代码设滚动位置时 UIKit 的 `isTracking` 恒为假，
    /// 终端会当成没人在滚、每个 Claude 帧结束都把视图拽回底部，就不是手指拖动了。
    private nonisolated(unsafe) static var fingerDown = false

    /// 给 `SwiftTerm.TerminalView` 加一个 `isTracking` 覆写：手指按着时返回真，其余照 UIScrollView 原样。
    /// 只加一次，进程里一直留着（`fingerDown` 为假时行为不变）。
    private static let installTracking: Void = {
        let selector = #selector(getter: UIScrollView.isTracking)
        let base = class_getInstanceMethod(UIScrollView.self, selector)!
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let original = unsafeBitCast(method_getImplementation(base), to: Getter.self)
        let tracking: @convention(block) (AnyObject) -> Bool = { view in
            fingerDown || original(view, selector)
        }
        class_addMethod(SwiftTerm.TerminalView.self, selector,
                        imp_implementationWithBlock(tracking), method_getTypeEncoding(base))
    }()

    override func setUp() async throws {
        _ = Self.installTracking
        let method = class_getInstanceMethod(SwiftTerm.TerminalView.self, #selector(UIView.draw(_:)))!
        typealias Draw = @convention(c) (AnyObject, Selector, CGRect) -> Void
        let original = method_getImplementation(method)
        let call = unsafeBitCast(original, to: Draw.self)
        let timed: @convention(block) (AnyObject, CGRect) -> Void = { view, rect in
            let start = CACurrentMediaTime()
            call(view, #selector(UIView.draw(_:)), rect)
            Self.drawLog.append((start, (CACurrentMediaTime() - start) * 1000))
        }
        method_setImplementation(method, imp_implementationWithBlock(timed))
        restoreDraw = { method_setImplementation(method, original) }
    }

    override func tearDown() async throws { restoreDraw?() }

    private struct Reading {
        let label: String
        let ticks: Int
        let intervals: [Double]
        let work: [Double]
        let cpu: Double
        let seconds: Double
        let nominal: Double
        let draws: [(at: Double, ms: Double)]
        /// 同一个显示间隔里画了不止一次的间隔数。
        let doubleDrawIntervals: Int
        /// 两拍之间滚动位置被别人改掉的次数（手指按着时终端不该抢）。
        let snappedAway: Int

        var hitches: Int { intervals.filter { $0 > nominal * 1.5 }.count }
        var line: String {
            String(format: "SCROLLOUT %@ ticks=%d hitch=%d interval-p95=%.2f max=%.2f "
                   + "work-p50=%.2f p95=%.2f max=%.2f cpu=%.0f%% draws=%d draw-p50=%.2f max=%.2f double=%d snapped=%d",
                   label, ticks, hitches, ProbeMetrics.percentile(intervals, 0.95), intervals.max() ?? 0,
                   ProbeMetrics.percentile(work, 0.5), ProbeMetrics.percentile(work, 0.95), work.max() ?? 0,
                   cpu / seconds * 100, draws.count, ProbeMetrics.percentile(draws.map(\.ms), 0.5),
                   draws.map(\.ms).max() ?? 0, doubleDrawIntervals, snappedAway)
        }
    }

    /// Claude Code 思考时的一帧：上移回到动态区顶部，重画转圈行、空行、输入框、底栏。
    private static func claudeFrame(_ n: Int, cols: Int, title: Bool) -> String {
        let glyph = ["✢", "✳", "✶", "✻", "✽"][n % 5]
        let box = String(repeating: "─", count: max(0, cols - 2))
        var frame = "\u{1B}[?2026h"
        if title { frame += "\u{1B}]0;\(["⠂", "⠐"][n % 2]) 修复滚动卡顿\u{07}" }
        frame += "\u{1B}[6A\r\u{1B}[2K\u{1B}[38;2;215;119;87m\(glyph) Thinking…\u{1B}[0m "
            + "\u{1B}[2m(\(n / 10)s · ↓ \(n * 7) tokens · esc to interrupt)\u{1B}[0m\r\n"
            + "\u{1B}[2K\r\n"
            + "\u{1B}[2K\u{1B}[2m╭\(box)╮\u{1B}[0m\r\n"
            + "\u{1B}[2K\u{1B}[2m│\u{1B}[0m > \u{1B}[7m \u{1B}[0m\u{1B}[\(cols)G\u{1B}[2m│\u{1B}[0m\r\n"
            + "\u{1B}[2K\u{1B}[2m╰\(box)╯\u{1B}[0m\r\n"
            + "\u{1B}[2K  \u{1B}[2m? for shortcuts\u{1B}[0m"
            + "\u{1B}[?2026l"
        return frame
    }

    /// 回滚区里像 Claude 跑过一阵：带色的 diff、中文说明、工具调用行，每行不溢出列宽。
    private static func history(lines: Int, cols: Int) -> String {
        let colors = ["32", "31", "36", "33", "90"]
        let body = (0..<lines).map { i -> String in
            let text = "\(i % 2 == 0 ? "+" : "⎿") let v\(i % 10) = f(\(i)) // 说明 App/File\(i % 100).swift"
            return "\u{1B}[\(colors[i % colors.count])m\(String(text.prefix(cols - 2)))\u{1B}[0m\r\n"
        }.joined()
        return body + String(repeating: "\r\n", count: 6)
    }

    func testScrollCostWithClaudeOutput() async throws {
        defer { MobileProbeWindow.closeAll() }
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(try c.mainContext.fetch(
            FetchDescriptor<ServerProfile>(sortBy: [SortDescriptor(\ServerProfile.sortOrder)])).first)
        let store = MobileStore()
        store.showWorkspace = true
        let relay = HostKeyChallengeRelay()
        let script = MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0, corpus: .plain)
        let (tab, handles) = MobileFakeTerminal.tab(host: host, script)
        let sessions = MobileWorkspace()
        sessions.open(.terminal(tab))
        sessions.activate(sessions.tabs[0].id)

        let rig = MobileProbeRig(label: "scroll-output")
        rig.mount(WorkspaceScreen()
            .environment(store).environment(relay).environment(sessions)
            .environment(\.mAccent, M.accent).modelContainer(c))
        tab.controller.start(profile: host, container: c, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(connected)
        let transport = try XCTUnwrap(handles.latest)
        let view = try XCTUnwrap(tab.controller.terminalView)
        let cols = view.getTerminal().cols

        await transport.write(Data((Self.history(lines: 400, cols: cols) + Self.claudeFrame(0, cols: cols, title: true)).utf8))
        _ = await MobileFakeTerminal.waitUntil { view.contentSize.height > view.bounds.height * 4 }
        rig.layout()
        XCTAssertGreaterThan(view.contentSize.height, view.bounds.height * 4, "回滚区没填起来，滚不到东西")

        // 热身一轮，三档都在热状态下比。
        _ = try await run("warmup", view: view, rig: rig, transport: transport, cols: cols, output: .none, seconds: 1)
        var readings: [Reading] = []
        for round in 0..<2 {
            readings.append(try await run("static#\(round)", view: view, rig: rig, transport: transport,
                                          cols: cols, output: .none))
            readings.append(try await run("output#\(round)", view: view, rig: rig, transport: transport,
                                          cols: cols, output: .frames(title: false)))
            readings.append(try await run("output+title#\(round)", view: view, rig: rig, transport: transport,
                                          cols: cols, output: .frames(title: true)))
        }
        for reading in readings { print(reading.line) }
        let terminal = view.getTerminal()
        let screen = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString() }.joined()
        XCTAssertTrue(screen.contains("tokens"), "Claude 帧没落到屏上")
        XCTAssertTrue(readings.allSatisfy { $0.ticks > 60 }, "渲染循环没在交付帧")
        // 每个滚动帧都要画（补丁 #21）。之前有输出时每秒约 10 帧不画：4 秒 245 拍只画 200 次。
        for reading in readings {
            XCTAssertGreaterThanOrEqual(reading.draws.count, reading.ticks - 3, "\(reading.label) 有滚动帧没画")
            XCTAssertEqual(reading.doubleDrawIntervals, 0, "\(reading.label) 一帧画了两遍")
            XCTAssertEqual(reading.snappedAway, 0, "\(reading.label) 手指按着时滚动位置被终端改了，量的不是手指拖动")
        }
        await rig.close()
    }

    private enum Output { case none, frames(title: Bool) }

    private func run(_ label: String, view: SwiftTerm.TerminalView, rig: MobileProbeRig,
                     transport: MobileFakeTerminalTransport, cols: Int, output: Output,
                     seconds: Double = 4) async throws -> Reading {
        let bottom = max(0, view.contentSize.height - view.bounds.height)
        let amplitude = min(bottom, view.bounds.height * 2)
        let counter = DisplayLinkCounter()
        var step = 0
        var lastSet: CGFloat?
        var snapped = 0
        counter.onTick = {
            if let lastSet, abs(view.contentOffset.y - lastSet) > 0.5 { snapped += 1 }
            // 底部往上两屏之间往返，一个来回 120 拍（60Hz 下 2 秒）。
            let phase = 0.5 * (1 - cos(Double(step % 120) / 120 * 2 * .pi))
            let y = bottom - amplitude * CGFloat(phase)
            view.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            lastSet = view.contentOffset.y
            rig.layout()
            step += 1
        }
        Self.fingerDown = true
        var tickTimes: [Double] = []
        let drive = counter.onTick
        counter.onTick = { tickTimes.append(CACurrentMediaTime()); drive?() }
        Self.drawLog.removeAll()
        let cpu0 = ProbeMetrics.threadCPUSeconds()
        counter.start()
        let start = Date()
        var frame = 1
        while Date().timeIntervalSince(start) < seconds {
            if case .frames(let title) = output {
                await transport.write(Data(Self.claudeFrame(frame, cols: cols, title: title).utf8))
                frame += 1
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        counter.stop()
        Self.fingerDown = false
        counter.onTick = nil
        let cpu = ProbeMetrics.threadCPUSeconds() - cpu0
        let draws = Self.drawLog
        var doubled = 0
        for (a, b) in zip(tickTimes, tickTimes.dropFirst())
        where draws.filter({ $0.at >= a && $0.at < b }).count > 1 { doubled += 1 }
        view.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        rig.layout()
        return Reading(label: label, ticks: counter.ticks, intervals: counter.intervals, work: counter.workMS,
                       cpu: cpu, seconds: seconds, nominal: counter.nominalIntervalMS,
                       draws: draws, doubleDrawIntervals: doubled, snappedAway: snapped)
    }
}
