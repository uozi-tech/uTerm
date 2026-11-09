#if canImport(GhosttyVt)
import Darwin
import GhosttyVt
import QuartzCore
import UIKit
import XCTest
@testable import uTermMobile

/// 测量门 M3：影子终端（libghostty-vt，与 GhosttyKit 同一个 Ghostty commit 编）的真机开销。
///
/// vt 的 xcframework 不进仓库，也不进 pbxproj：只在命令行给测试构建加搜索路径与链接参数时才编进来
///（`canImport(GhosttyVt)`），App 本身不引用它。跑法见 docs/ghostty-eval/measure-ios.md 的 M3 一节。
/// 同样挂在 `UTERM_MEASURE=1` 后面。
@MainActor
final class GhosttyShadowProbeTests: XCTestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["UTERM_MEASURE"] == "1" else {
            throw XCTSkip("测量门探针：设 UTERM_MEASURE=1 才跑（真机、单独跑）")
        }
        UIApplication.shared.isIdleTimerDisabled = true
        SwiftTermDrawLog.install()
    }

    /// 一个 vt 终端。回滚上限按行设（10k 行时页粒度会多留几十到上百行）。
    private final class Shadow {
        let handle: OpaquePointer

        /// 回滚上限：字节按 GhosttyKit 的默认 `scrollback-limit`（10 MB）显式设。vt 自己的默认字节上限很小：
        /// 只设 `SCROLLBACK_MAX_LINES = 10_000` 时实测只留下 1,075 行（约两页），两个都设才留满 10k 行。
        init(cols: UInt16, rows: UInt16, scrollbackLines: Int? = nil, scrollbackBytes: Int = 10_000_000) {
            var term: OpaquePointer?
            let result = ghostty_terminal_new(nil, &term, cols, rows)
            precondition(result == GHOSTTY_SUCCESS && term != nil, "ghostty_terminal_new 失败 \(result)")
            handle = term!
            var bytes = scrollbackBytes
            _ = withUnsafePointer(to: &bytes) { ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, $0) }
            if var lines = scrollbackLines {
                _ = withUnsafePointer(to: &lines) { ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, $0) }
            }
        }

        deinit { ghostty_terminal_free(handle) }

        func write(_ data: Data) {
            data.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                ghostty_terminal_vt_write(handle, base, raw.count)
            }
        }

        var totalRows: Int {
            var rows = 0
            _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &rows)
            return rows
        }

        /// primary + alternate 的常驻字节（页），不含 Kitty 图片。
        var residentBytes: UInt64 {
            var usage = GhosttyTerminalMemoryUsage()
            usage.size = MemoryLayout<GhosttyTerminalMemoryUsage>.size
            guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MEMORY_USAGE, &usage) == GHOSTTY_SUCCESS else { return 0 }
            return usage.primary_resident_bytes + usage.alternate_resident_bytes
        }
    }

    // MARK: 解析吞吐

    /// 2 MB 带色日志（16 KB 一块）、Claude 历史（diff + 中文）、Claude 同步帧流，各 5 遍，单线程墙钟 = 线程 CPU。
    func testM3ParseThroughput() throws {
        let flood = TerminalSpikeCorpus.flood(bytes: 2 * 1024 * 1024)
        let history = Data(TerminalSpikeCorpus.history(lines: 20_000, cols: 58).utf8)
        let frames = Data((0..<3000).map { TerminalSpikeCorpus.claudeFrame($0, cols: 58) }.joined().utf8)
        for (name, payload) in [("flood-2MB", flood), ("claude-history", history), ("claude-frames", frames)] {
            var rates: [Double] = []
            for _ in 0..<5 {
                let shadow = Shadow(cols: 58, rows: 51, scrollbackLines: 10_000)
                let cpu0 = ThreadCPU.current()
                for start in stride(from: 0, to: payload.count, by: 16 * 1024) {
                    shadow.write(payload.subdata(in: start..<min(payload.count, start + 16 * 1024)))
                }
                let cpu = ThreadCPU.current() - cpu0
                rates.append(Double(payload.count) / 1024 / 1024 / cpu)
                // Claude 帧是原地重画（光标上移），不滚屏，只核另外两种语料进了回滚。
                if name != "claude-frames" { XCTAssertGreaterThan(shadow.totalRows, 51) }
            }
            print(String(format: "MEASURE m3 parse %@ bytes=%d MB/s p50=%.0f min=%.0f max=%.0f",
                         name, payload.count, ProbeMetrics.percentile(rates, 0.5), rates.min() ?? 0, rates.max() ?? 0))
        }
    }

    // MARK: 常驻内存

    /// 1 个 / 8 个影子终端，每个 10k 行回滚：vt 自己报的页常驻字节 + 进程 footprint 增量。
    func testM3ResidentMemory() async throws {
        for count in [1, 8] {
            try await Task.sleep(for: .milliseconds(1000))
            let before = MemoryProbe.read()
            var shadows: [Shadow] = []
            for _ in 0..<count {
                let shadow = Shadow(cols: 58, rows: 51, scrollbackLines: 10_000)
                shadow.write(Data(TerminalSpikeCorpus.history(lines: 10_000, cols: 58).utf8))
                shadows.append(shadow)
            }
            try await Task.sleep(for: .milliseconds(1000))
            let after = MemoryProbe.read()
            let resident = shadows.map(\.residentBytes)
            print(String(format: "MEASURE m3 resident n=%d per-session vt-resident=%.2fMB rows=%@ Δfootprint=%.1fMB (%.2fMB/session)",
                         count, Double(resident.first ?? 0) / 1024 / 1024, shadows.map(\.totalRows).description,
                         after.footprint - before.footprint, (after.footprint - before.footprint) / Double(count)))
            shadows.removeAll()
            try await Task.sleep(for: .milliseconds(1000))
            print(String(format: "MEASURE m3 resident n=%d released Δ=%.1fMB", count, MemoryProbe.read().footprint - before.footprint))
        }
    }

    // MARK: Claude 输出时的额外 CPU

    /// 一个整屏终端每 100 ms 来一个 Claude 同步帧，8 s 一档，A B C A B C：
    /// A = SwiftTerm（生产的 feedPaced），B = Ghostty 画面，C = Ghostty 画面 + 同一份字节同步喂影子终端（在调用 receive 的同一线程上）。
    /// 过线：C − B < (A − B) 的一成。
    func testM3ShadowCPUDuringClaude() async throws {
        let screen = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds.size
            ?? CGSize(width: 440, height: 956)
        let st = try SwiftTermProbeHost(size: screen)
        let gh = try GhosttyProbeHost(size: screen)
        defer { st.close(); gh.close() }
        try await gh.waitUntilReady()
        let ghCols = gh.grid.cols, stCols = st.grid.cols
        let shadow = Shadow(cols: UInt16(ghCols), rows: UInt16(gh.grid.rows), scrollbackLines: 10_000)
        let history = TerminalSpikeCorpus.history(lines: 300, cols: ghCols)
        gh.feedAndWait(history)
        shadow.write(Data(history.utf8))
        st.view.feed(text: TerminalSpikeCorpus.history(lines: 300, cols: stCols))
        try await Task.sleep(for: .milliseconds(500))

        enum Arm: String { case swiftterm, ghostty, ghosttyShadow = "ghostty+shadow" }
        var totals: [Arm: [Double]] = [:]
        var shadowOnly: [Double] = []
        for round in 0..<3 {
            for arm in [Arm.swiftterm, .ghostty, .ghosttyShadow] {
                st.window.windowLevel = arm == .swiftterm ? .alert + 2 : .alert + 1
                gh.window.windowLevel = arm == .swiftterm ? .alert + 1 : .alert + 2
                st.container.isOnScreen = arm == .swiftterm
                gh.view.setSurfaceVisible(arm != .swiftterm)
                try await Task.sleep(for: .milliseconds(500))
                let mainID = ThreadCPU.currentThreadID()
                let start = ThreadCPU.snapshot()
                var shadowCPU = 0.0
                let t0 = CACurrentMediaTime()
                var beat = 0
                while CACurrentMediaTime() - t0 < 8 {
                    switch arm {
                    case .swiftterm:
                        st.view.feedPaced(ArraySlice(Array(TerminalSpikeCorpus.claudeFrame(beat + 1, cols: stCols).utf8)), backlogged: false)
                    case .ghostty:
                        gh.bridge.feed(Data(TerminalSpikeCorpus.claudeFrame(beat + 1, cols: ghCols).utf8))
                    case .ghosttyShadow:
                        let data = Data(TerminalSpikeCorpus.claudeFrame(beat + 1, cols: ghCols).utf8)
                        let c0 = ThreadCPU.current()
                        shadow.write(data)
                        shadowCPU += ThreadCPU.current() - c0
                        gh.bridge.feed(data)
                    }
                    beat += 1
                    let next = t0 + Double(beat) * 0.1
                    try await Task.sleep(for: .milliseconds(Int(max(0, next - CACurrentMediaTime()) * 1000)))
                }
                let delta = ThreadCPU.delta(from: start, to: ThreadCPU.snapshot(), mainID: mainID)
                let seconds = CACurrentMediaTime() - t0
                totals[arm, default: []].append(delta.totalMS / seconds * 1000 / 1000)  // ms CPU / s
                if arm == .ghosttyShadow { shadowOnly.append(shadowCPU * 1000 / seconds) }
                print(String(format: "MEASURE m3 claude %@#%d cpu=%.1fms/s main=%.1fms/s shadow-write=%.3fms/s | %@",
                             arm.rawValue, round, delta.totalMS / seconds, delta.mainMS / seconds,
                             arm == .ghosttyShadow ? shadowCPU * 1000 / seconds : 0.0, delta.line))
            }
        }
        let a = ProbeMetrics.percentile(totals[.swiftterm] ?? [], 0.5)
        let b = ProbeMetrics.percentile(totals[.ghostty] ?? [], 0.5)
        let c = ProbeMetrics.percentile(totals[.ghosttyShadow] ?? [], 0.5)
        let direct = ProbeMetrics.percentile(shadowOnly, 0.5)
        print(String(format: "MEASURE m3 claude summary swiftterm=%.1f ghostty=%.1f ghostty+shadow=%.1f ms/s | saved=%.1f increment(process)=%.1f increment(shadow-write)=%.3f ms/s | budget(10%%)=%.2f",
                     a, b, c, a - b, c - b, direct, (a - b) / 10))
        XCTAssertGreaterThan(shadow.totalRows, 300)
    }
}
#endif
