import UIKit
import XCTest
@testable import uTermMobile

/// iOS 终端重画一帧的开销，按「这一帧变了多少」分三种情形在同一次运行里比：
/// - 每行都变：全屏 TUI 重绘；
/// - 什么都没变：不该交帧；
/// - 只变一行：Claude Code 思考时每帧只改转圈那一行。
///
/// 来历：这个探针原来量的是旧引擎（CPU 栅格）的 `draw(_:)`——iOS 上 `draw` 拿到的永远是整个视图、位图整块重画，
/// 能省的只有「没变的行别再排一遍版」（当时的本地补丁 #20：按行缓存排版结果），闸门是「没变 / 只变一行的整屏重画
/// 比每行都变便宜 25% 以上」。旧引擎的视图类删掉之后，那个 `draw(_:)` 没有了。
///
/// 新引擎上的对应物：GhosttyKit 的渲染器只重建脏行的格子、内容没变不交帧，iOS 上重画在主线程同步做
///（`UTermScrollTrace.wakeupDrawsSynchronously`）。所以这里量的是每交一帧（`IOSurfaceLayer.setContents:`）摊到的
/// 主线程 CPU 与全部线程 CPU（解析在 GhosttyKit 的串行队列、帧数据在渲染线程，只量主线程会漏账），扣掉「什么都没变」
/// 那一档量到的宿主基线。
///
/// 闸门只放结构判据（有输出时真的交了帧、没输出时不跟着 10 fps 交帧）；三种情形的相对开销只打印成 `DRAWCOST …` 行——
/// 原来那条 25% 的时间闸门是给旧引擎的排版缓存定的，新引擎上的比例要先在真机上读过几轮才定得出闸门。
/// 只比同一次运行里的相对值，不看绝对毫秒数（模拟器和真机、负载高低都差很多）。
@MainActor
final class TerminalDrawCostProbeTests: XCTestCase {
    private struct Reading {
        let frames: Int
        let mainMS: Double
        let totalMS: Double
    }

    /// 量 `seconds` 秒：每 100 ms 调一次 `emit`（nil = 不喂），数交出去的帧与各线程 CPU。
    private func measure(seconds: Double, emit: (@MainActor (Int) -> Void)?) async throws -> Reading {
        GhosttyPresentLog.reset()
        let mainID = ThreadCPU.currentThreadID()
        let start = ThreadCPU.snapshot()
        let t0 = CACurrentMediaTime()
        var beat = 0
        while CACurrentMediaTime() - t0 < seconds {
            emit?(beat)
            beat += 1
            try await Task.sleep(for: .milliseconds(100))
        }
        // 最后一拍喂的那一帧也让它交出去。
        try await Task.sleep(for: .milliseconds(50))
        let cpu = ThreadCPU.delta(from: start, to: ThreadCPU.snapshot(), mainID: mainID)
        return Reading(frames: GhosttyPresentLog.read().times.count, mainMS: cpu.mainMS, totalMS: cpu.totalMS)
    }

    func testFrameCostFollowsHowMuchChanged() async throws {
        let host = try GhosttyProbeHost()
        defer { host.close() }
        try await host.waitUntilReady()
        let rows = host.grid.rows, cols = host.grid.cols
        // 像 Claude Code 跑了一阵之后的屏幕：每行接近铺满但不溢出（溢出折行的话整屏连成一个软折行段落，量的就不是
        // Claude 的情形了）。光标藏起来，免得闪烁的那两帧混进「什么都没变」。
        XCTAssertLessThan(TerminalSpikeCorpus.screen(rows: 1, salt: 0).count, cols * 2)
        func feedFrame(_ text: String) {
            host.bridge.feed(Data(("\u{1B}[?2026h" + text + "\u{1B}[?2026l").utf8))
        }
        feedFrame(TerminalSpikeCorpus.screen(rows: rows, salt: 0) + "\u{1B}[?25l")
        // 热身：字体回退、字形图集都建好，三组在同样的热状态下比。
        _ = try await measure(seconds: 1) { feedFrame(TerminalSpikeCorpus.screen(rows: rows, salt: $0)) }
        host.bridge.session.waitForPendingOutput()
        try await Task.sleep(for: .milliseconds(300))

        let seconds = 3.0
        let unchanged = try await measure(seconds: seconds, emit: nil)
        let everyRow = try await measure(seconds: seconds) { feedFrame(TerminalSpikeCorpus.screen(rows: rows, salt: 100 + $0)) }
        let spinner = try await measure(seconds: seconds) { sample in
            let glyph = ["✢", "✳", "✶", "✻", "✽"][sample % 5]
            feedFrame("\u{1B}[\(rows - 4);1H\u{1B}[2K\u{1B}[38;2;215;119;87m\(glyph) Thinking… (\(sample)s)\u{1B}[0m")
        }
        host.bridge.session.waitForPendingOutput()

        /// 每帧摊到的开销，扣掉同样时长里「什么都没变」的基线（宿主自己的开销 + 探针循环）。
        func perFrame(_ reading: Reading) -> String {
            guard reading.frames > 0 else { return "main=-/frame total=-/frame" }
            return String(format: "main=%.3fms/frame total=%.3fms/frame",
                          max(0, reading.mainMS - unchanged.mainMS) / Double(reading.frames),
                          max(0, reading.totalMS - unchanged.totalMS) / Double(reading.frames))
        }
        print(String(format: "DRAWCOST rows=%d cols=%d secs=%.0f unchanged: frames=%d main=%.1fms total=%.1fms",
                     rows, cols, seconds, unchanged.frames, unchanged.mainMS, unchanged.totalMS))
        print("DRAWCOST everyRow: frames=\(everyRow.frames) \(perFrame(everyRow))")
        print("DRAWCOST spinner: frames=\(spinner.frames) \(perFrame(spinner))")

        // 3 秒、每 100 ms 一帧：该交 30 帧上下。
        XCTAssertGreaterThanOrEqual(everyRow.frames, 15, "每行都变时没交够帧")
        XCTAssertGreaterThanOrEqual(spinner.frames, 15, "只变一行时没交够帧")
        XCTAssertLessThan(unchanged.frames, 15, "内容没变也在按输出的节拍交帧")
        XCTAssertTrue(host.viewportText.contains("Thinking…"), "转圈那一行没落到屏上：\(host.viewportText.suffix(200))")
    }
}
