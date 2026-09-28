import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 快捷命令「执行日志」（`QuickCommandRunLog`）的渲染成本探针。
///
/// ## 三层成本叠在一起（playbook §四）
///
/// 1. **非 lazy 的 `VStack + ForEach(runs)`** —— 30 天窗口内多少条就建多少行；
/// 2. 每行一个 plain `Button`（展开 / 收起），各带一个 `_FocusRingView`
///    与一个 `KeyViewProxy`；
/// 3. **每行每次 body 要跑 5 次 `JSONDecoder`** —— `QuickCommandRun.results`
///    与 `.aiRecord` 是「每次 get 都解码」的计算属性
///    （`Core/Models/QuickCommand.swift`），而折叠态的行体里
///    `results` / `failureCount` / `allSucceeded` / `aiRecord` 一共取 5 次值。
///
/// ## 规模来源
///
/// 行数 = 该命令近 30 天的执行记录数，**没有任何上限**
/// （`QuickCommandStore.retentionDays = 30`，`runs(for:)` 只按时间过滤，
/// 不 `fetchLimit`）。一条每 10 分钟跑一次的巡检命令 30 天就是 4320 条。
/// 真实档 200 条，极端档 3000 条。
///
/// ## 两臂
///
/// - `legacy`：改前那一版 `QuickCommandRunLog` / `QuickCommandLogEntry` 的
///   **逐字拷贝**（非 lazy、每行 `Button`、每次取值都解码）；
/// - `tuned`：产品里现在的那一版。
@MainActor
final class QuickCommandRunLogCostTests: XCTestCase {

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private static let size = NSSize(width: 640, height: 620)

    enum Arm: String { case legacy, tuned }

    struct Reading {
        let arm: Arm
        let runs: Int
        let mountMS: Double
        let beats: Int
        let frameP50: Double
        let frameP95: Double
        let overBudget: Double
        let hitP50: Double
        let views: Int
        let scrollableHeight: CGFloat
    }

    /// 确定性假数据：每条 6 台服务器的结果，每 4 条带一份 AI 记录。
    /// `QuickCommandRun` 是 `@Model`，但这里**不插进任何 ModelContext**
    /// —— 探针只要值，不要持久化（与 `MockServerFactory` 同一手法）。
    static func makeRuns(_ count: Int) -> [QuickCommandRun] {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map { i in
            let results = (0..<6).map { j in
                QuickCommandServerResult(serverID: UUID(uuidString:
                    "00000000-0000-0000-0000-\(String(format: "%012d", i * 10 + j))") ?? UUID(),
                    serverName: "host-\(i)-\(j)",
                    endpoint: "deploy@10.0.\(i % 256).\(j)",
                    exitCode: (i + j) % 7 == 0 ? 1 : 0,
                    durationMs: 120 + j * 31,
                    ok: (i + j) % 7 != 0)
            }
            let ai: QuickCommandAIRecord? = i % 4 == 0
                ? QuickCommandAIRecord(summary: "第 \(i) 次运行：两台 healthz 非 200，已重启并复检通过。",
                                       steps: ["读取 nginx 错误日志", "重启 nginx", "复检 /healthz"])
                : nil
            return QuickCommandRun(commandID: UUID(uuidString:
                "00000000-0000-0000-0000-000000000001")!,
                startedAt: anchor.addingTimeInterval(-Double(i) * 600),
                durationMs: 800 + i % 500,
                results: results,
                aiRecord: ai,
                id: UUID(uuidString: "00000000-0000-0000-1111-\(String(format: "%012d", i))") ?? UUID())
        }
    }

    // MARK: - 挂载

    private struct Fixture {
        let window: ProbeWindow.Unconstrained
        let host: NSHostingView<AnyView>
        let scroll: NSScrollView
        let document: NSView
        let mountMS: Double
    }

    @ViewBuilder
    private func content(arm: Arm, runs: [QuickCommandRun]) -> some View {
        ScrollView {
            switch arm {
            case .legacy: LegacyQuickCommandRunLog(runs: runs).padding(14)
            case .tuned:  QuickCommandRunLog(runs: runs).padding(14)
            }
        }
        .background(UD.bg)
    }

    private func makeFixture(arm: Arm, runs: [QuickCommandRun]) throws -> Fixture {
        let size = Self.size
        let host = NSHostingView(rootView: AnyView(
            content(arm: arm, runs: runs).frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .transparentOnScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .aqua)
        let start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let mountMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let scroll = try XCTUnwrap(host.firstScrollView(), "夹具里必须有 NSScrollView")
        let document = try XCTUnwrap(scroll.documentView)
        let unconstrained = try XCTUnwrap(window as? ProbeWindow.Unconstrained)
        return Fixture(window: unconstrained, host: host, scroll: scroll,
                       document: document, mountMS: mountMS)
    }

    private func closeWindows() async {
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - 量

    private func measure(arm: Arm, runs count: Int) async throws -> Reading {
        let runs = Self.makeRuns(count)
        let fixture = try makeFixture(arm: arm, runs: runs)
        let scroll = fixture.scroll
        let document = fixture.document
        let host = fixture.host

        XCTAssertTrue(ProbeWindow.blindsRealMouse(fixture.window))

        let viewport = scroll.contentSize.height
        let maxOffset = max(0, document.frame.height - viewport)
        let amplitude = min(maxOffset, viewport * 3)

        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, max(0, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }

        var visited: CGFloat = 0
        while visited < amplitude {
            scrollTo(visited)
            layout()
            try await Task.sleep(for: .milliseconds(8))
            visited += viewport * 0.8
        }
        scrollTo(0)
        layout()
        try await Task.sleep(for: .milliseconds(120))

        let heartbeatStart = Date()
        var beats = 0
        while Date().timeIntervalSince(heartbeatStart) < 3 {
            try await Task.sleep(for: .milliseconds(8))
            let wave = 0.5 * (1 - cos(Double(beats % 80) / 80 * 2 * .pi))
            scrollTo(amplitude * wave)
            beats += 1
        }

        var frames: [Double] = []
        for step in 0..<200 {
            let wave = 0.5 * (1 - cos(Double(step % 80) / 80 * 2 * .pi))
            let start = CFAbsoluteTimeGetCurrent()
            scrollTo(amplitude * wave)
            layout()
            frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(8))
        }

        var hits: [Double] = []
        for fraction in [0.02, 0.5, 0.98] {
            scrollTo(amplitude * fraction)
            layout()
            try await Task.sleep(for: .milliseconds(120))
            for i in 0..<100 {
                let point = NSPoint(x: CGFloat(40 + (i % 9) * 40), y: CGFloat(40 + (i % 11) * 40))
                let start = CFAbsoluteTimeGetCurrent()
                _ = host.hitTest(point)
                hits.append((CFAbsoluteTimeGetCurrent() - start) * 1_000_000)
            }
        }

        let reading = Reading(arm: arm, runs: count, mountMS: fixture.mountMS, beats: beats,
                              frameP50: ProbeMetrics.percentile(frames, 0.5),
                              frameP95: ProbeMetrics.percentile(frames, 0.95),
                              overBudget: Double(frames.filter { $0 > 8.33 }.count)
                                  / Double(frames.count) * 100,
                              hitP50: ProbeMetrics.percentile(hits, 0.5),
                              views: WelcomeServerListCostTests.viewCount(in: host),
                              scrollableHeight: maxOffset)
        print(String(format: """
            [runlog] arm=%@ runs=%d mount=%.2fms beats=%d/375 frame-p50=%.3fms \
            frame-p95=%.3fms over-8.33=%.1f%% hit-p50=%.1fus views=%d scrollable=%.0f \
            cpu=%.2fs rss=%.1fMB
            """, arm.rawValue, count, reading.mountMS, reading.beats, reading.frameP50,
            reading.frameP95, reading.overBudget, reading.hitP50, reading.views,
            reading.scrollableHeight, ProbeMetrics.threadCPUSeconds(), ProbeMetrics.footprintMB()))
        print("[runlog-views] arm=\(arm.rawValue) runs=\(count) "
              + WelcomeServerListCostTests.classHistogram(in: host))
        await closeWindows()
        return reading
    }

    private func average(_ r: [Reading]) -> Reading {
        let n = Double(r.count)
        return Reading(arm: r[0].arm, runs: r[0].runs,
                       mountMS: r.map(\.mountMS).reduce(0, +) / n,
                       beats: r.map(\.beats).reduce(0, +) / r.count,
                       frameP50: r.map(\.frameP50).reduce(0, +) / n,
                       frameP95: r.map(\.frameP95).reduce(0, +) / n,
                       overBudget: r.map(\.overBudget).reduce(0, +) / n,
                       hitP50: r.map(\.hitP50).reduce(0, +) / n,
                       views: r.map(\.views).reduce(0, +) / r.count,
                       scrollableHeight: r[0].scrollableHeight)
    }

    // MARK: - 尺 ①：解码本身单独称

    /// `results` / `aiRecord` 改前是「每次 get 都解一次 JSON」，而折叠态一行
    /// 一次 body 要取 5 次值。这一条把「解码缓存」那一刀单独称出来，
    /// 与视图读数分开记账。
    ///
    /// 两臂同轮：`legacy` 每次现解（改前 getter 的逐字等价），
    /// `tuned` 走模型侧的 `@Transient` 缓存。
    func testDecodeCostPerRow() {
        let runs = Self.makeRuns(200)

        /// 改前 getter 的逐字等价：每次现建 `JSONDecoder` 从 JSON 串解一遍。
        func legacyResults(_ run: QuickCommandRun) -> [QuickCommandServerResult] {
            (try? JSONDecoder().decode([QuickCommandServerResult].self,
                                       from: Data(run.resultsJSON.utf8))) ?? []
        }
        func legacyAIRecord(_ run: QuickCommandRun) -> QuickCommandAIRecord? {
            guard let json = run.aiRecordJSON, !json.isEmpty else { return nil }
            return try? JSONDecoder().decode(QuickCommandAIRecord.self, from: Data(json.utf8))
        }

        func time(_ label: String, _ body: (QuickCommandRun) -> Void) -> Double {
            for r in runs.prefix(20) { body(r) }   // 预热
            var samples: [Double] = []
            for _ in 0..<20 {
                let start = CFAbsoluteTimeGetCurrent()
                for r in runs { body(r) }
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            let p50 = ProbeMetrics.percentile(samples, 0.5)
            print(String(format: "[runlog-decode] %@ runs=200 p50=%.3fms (%.1fus/行)",
                         label, p50, p50 * 1000 / 200))
            return p50
        }

        // 折叠态一行的真实取值序列（allSucceeded → failureCount → results ×2 → aiRecord）。
        // ABBA：legacy → tuned → tuned → legacy。
        let l1 = time("legacy-folded-row") { run in
            let r = legacyResults(run)
            _ = !r.isEmpty && !r.contains { !$0.ok }
            _ = legacyResults(run).filter { !$0.ok }.count
            _ = legacyResults(run).count
            _ = legacyResults(run).count
            _ = legacyAIRecord(run) != nil
        }
        let t1 = time("tuned-folded-row") { run in
            _ = run.allSucceeded
            _ = run.failureCount
            _ = run.results.count
            _ = run.results.count
            _ = run.aiRecord != nil
        }
        let t2 = time("tuned-folded-row") { run in
            _ = run.allSucceeded
            _ = run.failureCount
            _ = run.results.count
            _ = run.results.count
            _ = run.aiRecord != nil
        }
        let l2 = time("legacy-folded-row") { run in
            let r = legacyResults(run)
            _ = !r.isEmpty && !r.contains { !$0.ok }
            _ = legacyResults(run).filter { !$0.ok }.count
            _ = legacyResults(run).count
            _ = legacyResults(run).count
            _ = legacyAIRecord(run) != nil
        }
        let legacy = (l1 + l2) / 2, tuned = (t1 + t2) / 2
        print(String(format: "[runlog-decode-avg] folded-row legacy=%.3fms tuned=%.3fms (200 行)",
                     legacy, tuned))

        // ① 同轮相对差：缓存必须把「一行 5 次取值」压到改前的一半以下。
        XCTAssertLessThan(tuned, legacy / 2,
                          "解码缓存必须生效：\(tuned)ms vs 改前 \(legacy)ms")

        // ② 语义闸门：缓存不能改变取到的值，而且写入路径要让缓存作废。
        let run = runs[0]
        XCTAssertEqual(run.results, legacyResults(run))
        XCTAssertEqual(run.aiRecord?.summary, legacyAIRecord(run)?.summary)
        let replaced = [QuickCommandServerResult(serverID: UUID(), serverName: "n",
                                                 endpoint: "e", exitCode: 3,
                                                 durationMs: 1, ok: false)]
        run.results = replaced
        XCTAssertEqual(run.results, replaced, "写入后必须读到新值（缓存跟着更新）")
        XCTAssertEqual(run.failureCount, 1)
        XCTAssertFalse(run.allSucceeded)
        // 绕过 setter 直接改底层 JSON —— 缓存按 JSON 串判失效，必须自动作废。
        run.resultsJSON = "[]"
        XCTAssertEqual(run.results, [], "直接改 resultsJSON 后缓存必须作废")
        run.aiRecordJSON = nil
        XCTAssertNil(run.aiRecord)
    }

    // MARK: - 尺 ②：挂载 / 滚动 / hitTest / NSView

    func testRunLogScaleArms() async throws {
        defer { closeAllWindows() }
        var results: [String: [Reading]] = [:]
        func record(_ r: Reading) { results["\(r.arm.rawValue)-\(r.runs)", default: []].append(r) }

        for count in [200, 3000] {
            record(try await measure(arm: .legacy, runs: count))
            record(try await measure(arm: .tuned, runs: count))
            record(try await measure(arm: .tuned, runs: count))
            record(try await measure(arm: .legacy, runs: count))
        }

        let realLegacy = average(results["legacy-200"]!)
        let realTuned = average(results["tuned-200"]!)
        let hugeLegacy = average(results["legacy-3000"]!)
        let hugeTuned = average(results["tuned-3000"]!)

        for r in [realLegacy, realTuned, hugeLegacy, hugeTuned] {
            print(String(format: """
                [runlog-avg] arm=%@ runs=%d mount=%.2fms beats=%d frame-p50=%.3fms \
                frame-p95=%.3fms over=%.1f%% hit-p50=%.1fus views=%d
                """, r.arm.rawValue, r.runs, r.mountMS, r.beats, r.frameP50, r.frameP95,
                r.overBudget, r.hitP50, r.views))
        }

        // ① 结构判据：改后 NSView 不随条数涨（懒栈 + 行内零平台控件）。
        XCTAssertLessThanOrEqual(Double(hugeTuned.views), Double(realTuned.views) * 1.2 + 8,
                                 "改后 NSView 必须不随条数涨：200 条 \(realTuned.views) "
                                 + "vs 3000 条 \(hugeTuned.views)")
        // ② 改前必须是「跟着条数涨」的形态 —— 这条钉住探针真的在量两种形态。
        XCTAssertGreaterThan(hugeLegacy.views, realLegacy.views * 2,
                             "改前臂（非 lazy）的 NSView 必须随条数涨：\(realLegacy.views) "
                             + "→ \(hugeLegacy.views)")
        // ③ 同轮相对差：极端档挂载与常驻视图数都必须显著变好。
        XCTAssertLessThan(hugeTuned.views, hugeLegacy.views)
        XCTAssertLessThan(hugeTuned.mountMS, hugeLegacy.mountMS)
        XCTAssertGreaterThan(hugeTuned.beats, 30)
    }
}

// MARK: - 改前臂（逐字拷贝）

/// **改前那一版 `QuickCommandRunLog` 的逐字拷贝**，只改了类型名。
///
/// 抄自 `uTerm/Features/Welcome/Views/QuickCommandRunLog.swift`（本 commit 的
/// 父提交）。保留了后来被改掉的三处形态：非 lazy `VStack`、每行一个 `Button`、
/// 每次取值都解码（走 `run.results` 而不是先取一次值）。
private struct LegacyQuickCommandRunLog: View {
    let runs: [QuickCommandRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("执行日志").font(.system(size: 10.5)).tracking(0.5).foregroundStyle(UD.text4)
                Text("保留近 30 天")
                    .font(.system(size: 10)).foregroundStyle(UD.text3)
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Capsule().fill(UD.fillFaint))
                Spacer()
                Text("\(runs.count) 条")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(UD.text4)
            }
            VStack(spacing: 7) {
                ForEach(runs) { run in
                    LegacyQuickCommandLogEntry(run: run)
                }
            }
        }
    }
}

private struct LegacyQuickCommandLogEntry: View {
    let run: QuickCommandRun
    @State private var open = false

    private var results: [QuickCommandServerResult] { run.results }
    private var failCount: Int { run.failureCount }
    private var allOK: Bool { run.allSucceeded }
    private var statusColor: Color { allOK ? UD.success : UD.danger }

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 9) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(UTermFormat.logTimestamp(run.startedAt))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(UD.text)
                        Text(overview).font(.system(size: 10.5)).foregroundStyle(UD.text4)
                    }
                    Spacer(minLength: 4)
                    if run.aiRecord != nil { aiRecordTag }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(UD.text4)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(results) { result in serverResultRow(result) }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(UD.fillFaint))
    }

    private var overview: String {
        let ok = results.count - failCount
        var parts = ["\(results.count) 台", "成功 \(ok)"]
        if failCount > 0 { parts.append("失败 \(failCount)") }
        parts.append(UFormat.duration(milliseconds: Double(run.durationMs)))
        return parts.joined(separator: " · ")
    }

    private var aiRecordTag: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles").font(.system(size: 8))
            Text("AI 记录").font(.system(size: 10))
        }
        .foregroundStyle(UD.aiAccent)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(UD.aiAccent.opacity(0.12)))
    }

    private func serverResultRow(_ result: QuickCommandServerResult) -> some View {
        HStack(spacing: 8) {
            Circle().fill(result.ok ? UD.success : UD.danger).frame(width: 5, height: 5)
            Text(result.serverName)
                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(UD.text)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(result.exitCode.map { "退出码 \($0) · \(result.durationMs)ms" }
                 ?? "连接失败 · \(result.durationMs)ms")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(result.ok ? UD.text4 : UD.danger).lineLimit(1)
        }
    }
}
