import GhosttyTerminal
import SwiftData
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
///
/// 换到 Ghostty 之后的量法（原来量的是旧终端视图：它自己是 UIScrollView、在主线程 `draw(_:)` 里画字）：
/// - 「手指拖动」：单指滚回滚区归系统滚动那条路径，这里照 `GhosttyScrollEdgeTests` 的做法直接操作 GhosttyKit 借来的
///   那个隐藏 UIScrollView（`uTermSystemScrollView`）——先调代理的 `scrollViewWillBeginDragging`（= 手指按下，之后终端
///   不许再写 contentOffset），每拍改 `contentOffset`（`scrollViewDidScroll` 照常把位移换成像素发给引擎），最后
///   `scrollViewDidEndDragging`；
/// - 「画了几次」：Ghostty 在自己的渲染线程上画，主线程没有 `draw(_:)` 可挂；数的是它交给 Core Animation 的帧
///  （`GhosttyPresentLog`，`IOSurfaceLayer.setContents:`），主线程以外的 CPU（渲染 / IO 线程）另记一笔。
@MainActor
final class TerminalScrollWhileOutputProbeTests: XCTestCase {
    private struct Reading {
        let label: String
        let ticks: Int
        let intervals: [Double]
        let work: [Double]
        /// 主线程 CPU（秒）。
        let cpu: Double
        /// 主线程以外的 CPU（毫秒），以及其中渲染线程的。
        let otherCPU: Double
        let rendererCPU: Double
        let seconds: Double
        let nominal: Double
        /// Ghostty 交给 Core Animation 的帧（时刻）。
        let presents: [Double]
        /// 同一个显示间隔里交了不止一帧的间隔数。
        let multiPresentIntervals: Int
        /// 两拍之间滚动位置被别人改掉的次数（手指按着时终端不该抢）。
        let snappedAway: Int

        var hitches: Int { intervals.filter { $0 > nominal * 1.5 }.count }
        /// 每个滚动拍交了几帧。
        var presentsPerTick: Double { ticks == 0 ? 0 : Double(presents.count) / Double(ticks) }
        var line: String {
            String(format: "SCROLLOUT %@ ticks=%d hitch=%d interval-p95=%.2f max=%.2f "
                   + "work-p50=%.2f p95=%.2f max=%.2f cpu=%.0f%% cpu-other=%.0fms renderer=%.0fms "
                   + "presents=%d per-tick=%.2f multi=%d snapped=%d",
                   label, ticks, hitches, ProbeMetrics.percentile(intervals, 0.95), intervals.max() ?? 0,
                   ProbeMetrics.percentile(work, 0.5), ProbeMetrics.percentile(work, 0.95), work.max() ?? 0,
                   cpu / seconds * 100, otherCPU, rendererCPU,
                   presents.count, presentsPerTick, multiPresentIntervals, snappedAway)
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
        defer { tab.controller.close() }
        let transport = try XCTUnwrap(handles.latest)
        let terminal = tab.controller.terminal
        let view = terminal.view
        // surface 建好、网格到位、画面开始吃字节之后再喂：就绪之前喂的只进影子，要等一次回放才上屏。
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            view.surface != nil && terminal.grid != nil && terminal.isSurfaceReady && terminal.outputPump.isFeedingSurface
        }
        XCTAssertTrue(ready, "Ghostty surface 没建起来")
        let cols = terminal.grid?.cols ?? 80

        await transport.write(Data((Self.history(lines: 400, cols: cols) + Self.claudeFrame(0, cols: cols, title: true)).utf8))
        let scrollView = try XCTUnwrap(view.uTermSystemScrollView, "终端视图里没有系统滚动借的 UIScrollView")
        _ = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            scrollView.contentSize.height > scrollView.bounds.height * 4
        }
        rig.layout()
        XCTAssertGreaterThan(scrollView.contentSize.height, scrollView.bounds.height * 4, "回滚区没填起来，滚不到东西")
        XCTAssertTrue(view.uTermSystemPanWouldBegin, "有回滚的普通屏：单指拖动应当归系统滚动")
        XCTAssertTrue(GhosttyPresentLog.installIfPossible(), "数不了 Ghostty 交的帧（IOSurfaceLayer 类还没注册）")

        // 热身一轮，三档都在热状态下比。
        _ = try await run("warmup", terminal: terminal, scrollView: scrollView, rig: rig, transport: transport,
                          cols: cols, output: .none, seconds: 1)
        var rounds: [(still: Reading, output: Reading, titled: Reading)] = []
        for round in 0..<2 {
            let still = try await run("static#\(round)", terminal: terminal, scrollView: scrollView, rig: rig,
                                      transport: transport, cols: cols, output: .none)
            let output = try await run("output#\(round)", terminal: terminal, scrollView: scrollView, rig: rig,
                                       transport: transport, cols: cols, output: .frames(title: false))
            let titled = try await run("output+title#\(round)", terminal: terminal, scrollView: scrollView, rig: rig,
                                       transport: transport, cols: cols, output: .frames(title: true))
            rounds.append((still, output, titled))
        }
        let readings = rounds.flatMap { [$0.still, $0.output, $0.titled] }
        for reading in readings { print(reading.line) }
        // 读状态找影子终端：它和画面吃同一份字节。
        XCTAssertTrue(terminal.shadow.viewportText().contains("tokens"), "Claude 帧没落到屏上")
        XCTAssertTrue(readings.allSatisfy { $0.ticks > 60 }, "渲染循环没在交付帧")
        for reading in readings {
            // 滚动时画面真的在换帧（不是手势空转）。
            XCTAssertGreaterThan(reading.presents.count, reading.ticks / 4, "\(reading.label) 滚动时几乎没交帧")
            XCTAssertEqual(reading.snappedAway, 0, "\(reading.label) 手指按着时滚动位置被终端改了，量的不是手指拖动")
        }
        // 每个滚动帧都要画：有输出时每拍交的帧不能比同一轮静止时少（换引擎之前的回归是有输出时每秒约 10 帧不画，
        // 4 秒 245 拍只画 200 次，约八成）。按同轮相对值比：Ghostty 的渲染节拍是它自己的，和这里驱动滚动的 link 不一定同频，
        // 「帧数 ≥ 拍数 − 3」那种绝对门槛不适用。
        for round in rounds {
            for reading in [round.output, round.titled] {
                XCTAssertGreaterThanOrEqual(reading.presentsPerTick, round.still.presentsPerTick * 0.9,
                                            "\(reading.label) 有输出时滚动帧画得比静止时少（\(round.still.label) 每拍 "
                                                + String(format: "%.2f", round.still.presentsPerTick) + " 帧）")
            }
        }
        // 「一个显示间隔里交了不止一帧」只打印（multi=）：引擎 wakeup 在主线程同步重画时，跨行 / 来输出的那一拍本来就
        // 会多交一帧（见 measure-ios.md 第六、七轮），不是换引擎之前「一帧画了两遍」那个 bug 的等价物。
        await rig.close()
    }

    private enum Output { case none, frames(title: Bool) }

    private func run(_ label: String, terminal: GhosttyTerminalBridge, scrollView: UIScrollView, rig: MobileProbeRig,
                     transport: MobileFakeTerminalTransport, cols: Int, output: Output,
                     seconds: Double = 4) async throws -> Reading {
        let view = terminal.view
        let bottom = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let amplitude = min(bottom, scrollView.bounds.height * 2)
        let counter = DisplayLinkCounter()
        var step = 0
        var lastSet: CGFloat?
        var snapped = 0
        var tickTimes: [Double] = []
        counter.onTick = {
            tickTimes.append(CACurrentMediaTime())
            if let lastSet, abs(scrollView.contentOffset.y - lastSet) > 0.5 { snapped += 1 }
            // 底部往上两屏之间往返，一个来回 120 拍（60Hz 下 2 秒）。
            let phase = 0.5 * (1 - cos(Double(step % 120) / 120 * 2 * .pi))
            let y = bottom - amplitude * CGFloat(phase)
            scrollView.contentOffset = CGPoint(x: 0, y: y)
            lastSet = scrollView.contentOffset.y
            rig.layout()
            step += 1
        }
        // 手指按下：从这里到 didEndDragging，终端不该自己写 contentOffset（来了输出也不把视口拽回底部）。
        view.scrollViewWillBeginDragging(scrollView)
        GhosttyPresentLog.reset()
        let threads0 = ThreadCPU.snapshot()
        let mainID = ThreadCPU.currentThreadID()
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
        counter.onTick = nil
        let cpu = ProbeMetrics.threadCPUSeconds() - cpu0
        let threads = ThreadCPU.delta(from: threads0, to: ThreadCPU.snapshot(), mainID: mainID)
        let presents = GhosttyPresentLog.read().times
        var multi = 0
        for (a, b) in zip(tickTimes, tickTimes.dropFirst())
        where presents.filter({ $0 >= a && $0 < b }).count > 1 { multi += 1 }
        // 手指拖回底部再抬起，等对齐收尾。
        scrollView.contentOffset = CGPoint(x: 0, y: bottom)
        view.scrollViewDidEndDragging(scrollView, willDecelerate: false)
        rig.layout()
        try await Task.sleep(for: .milliseconds(400))
        return Reading(label: label, ticks: counter.ticks, intervals: counter.intervals, work: counter.workMS,
                       cpu: cpu, otherCPU: threads.otherMS, rendererCPU: threads.ms(matching: "renderer"),
                       seconds: seconds, nominal: counter.nominalIntervalMS,
                       presents: presents, multiPresentIntervals: multi, snappedAway: snapped)
    }
}
