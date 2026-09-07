import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 探针链路的自证用例 —— **这里不评判任何 uTerm 视图**。
///
/// 被测对象是夹具本身：`ProbeWindow` / `ProbeMetrics` / `VisionTextProbe` 三件从
/// uTable 移过来的零件，在 uTerm 的测试宿主里是不是真的能跑通「建窗 → 上屏 →
/// 挂 SwiftUI → 滚 → 量 → 截图识别」这一整条链路。后面每个视图评估任务直接抄
/// 这个类的形状，不必再验一遍地基。
///
/// 夹具刻意只用**纯 Text 行**（`ScrollView + LazyVStack + ForEach`）：
/// 没有 Button、没有 TextField、没有 `.help`，也就没有平台视图。于是
/// 「NSView 数不随行数涨」是一条**结构判据**而非性能判据 —— 它对机器负载免疫，
/// 可以当硬断言；绝对毫秒只打印（playbook §一）。
@MainActor
final class ProbeSmokeTests: XCTestCase {

    private var windows: [NSWindow] = []

    /// 拆窗不走 `tearDown()`：`XCTestCase.tearDown()` 是 `nonisolated` 的、覆写
    /// 不能改隔离，而 `uTermTests` target 的默认隔离是 `nonisolated`（uTable 那边
    /// 是 `MainActor`），Swift 6 语言模式下从那里碰 `windows` 一律判成数据竞争
    /// （`MainActor.assumeIsolated` 也不行，它要求把 `self` sending 出去）。
    /// 所以每条用例开头 `defer { closeAllWindows() }`，断言抛错也能把窗拆掉。
    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    // MARK: - 夹具

    /// 行高写死，几何判据（文档高度、滚到第几行）才算得准。
    private static let rowHeight: CGFloat = 22
    private static let size = NSSize(width: 460, height: 520)

    private struct Reading {
        let rows: Int
        let mountMS: Double
        let beats: Int
        let frameP50: Double
        let frameP95: Double
        let overBudget: Double
        let hitP50: Double
        let views: Int
        let documentHeight: CGFloat
        let scrollableHeight: CGFloat
    }

    private struct Fixture {
        let window: ProbeWindow.Unconstrained
        let host: NSHostingView<AnyView>
        let scroll: NSScrollView
        let document: NSView
        let mountMS: Double
    }

    @ViewBuilder
    private func rowList(_ rows: Int) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(0..<rows, id: \.self) { index in
                    Text(String(format: "row_%04d", index))
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.black)
                        .frame(height: Self.rowHeight, alignment: .leading)
                        .padding(.horizontal, 14)
                }
            }
        }
        .background(Color.white)
    }

    /// 建窗 + 挂载 + 找到滚动视图。挂载耗时单独计（`layoutSubtreeIfNeeded` 之前
    /// 什么都没发生，必须把首次布局算进这一步的账）。
    private func makeFixture(rows: Int) throws -> Fixture {
        let size = Self.size
        let root = AnyView(rowList(rows).frame(width: size.width, height: size.height))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        // 计时探针留在屏上、靠 alphaValue = 0 不占用户的屏（见 ProbeWindow 顶部 A/B 数据）。
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .transparentOnScreen)
        windows.append(window)
        // 宿主 app 自己的窗口里跑着真实逻辑（连接列表探活之类），不卸会污染读数。
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .aqua)
        let start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let mountMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let scroll = try XCTUnwrap(host.firstScrollView(), "夹具里必须有 NSScrollView")
        let document = try XCTUnwrap(scroll.documentView, "NSScrollView 必须有 documentView")
        let unconstrained = try XCTUnwrap(window as? ProbeWindow.Unconstrained)
        return Fixture(window: unconstrained, host: host, scroll: scroll,
                       document: document, mountMS: mountMS)
    }

    private func viewCount(in root: NSView) -> Int {
        var n = 0
        func walk(_ view: NSView) { n += 1; for sub in view.subviews { walk(sub) } }
        walk(root)
        return n
    }

    private func classHistogram(in root: NSView) -> String {
        var counts: [String: Int] = [:]
        func walk(_ view: NSView) {
            counts[String(describing: type(of: view)), default: 0] += 1
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return counts.sorted { $0.value > $1.value }.prefix(5)
            .map { "\($0.key)×\($0.value)" }.joined(separator: "  ")
    }

    /// 拆窗后留一小段，让上一档的图层后备存储与 tracking area 真的散掉。
    private func closeWindows() async {
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - 量

    /// 一档：挂载 → 扫一遍让懒行实例化 → 3s 心跳 → 200 步往返单帧 → hitTest。
    ///
    /// 往返幅度钳在**约 3 个视口**（playbook：全程往返在大列表上一步跨几十屏，
    /// 量到的是「跳转」不是「滚动」）。
    private func measure(rows: Int) async throws -> Reading {
        let fixture = try makeFixture(rows: rows)
        let scroll = fixture.scroll
        let document = fixture.document
        let host = fixture.host

        // 建窗后立刻自证：真鼠标已被挡在窗外，否则 `.onHover` 会把读数染红。
        XCTAssertTrue(ProbeWindow.blindsRealMouse(fixture.window),
                      "透明屏内档必须谎报鼠标位置，否则用户光标会点亮 .onHover")

        let viewport = scroll.contentSize.height
        let maxOffset = max(0, document.frame.height - viewport)
        // 往返幅度：3 个视口，且不超过实际可滚动余量。
        let amplitude = min(maxOffset, viewport * 3)

        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, max(0, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }

        // 先以小于一屏的间距扫过要往返的那一段，把懒建的行与 tracking area 全部计入。
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

        // 8ms 心跳：3 秒里理想 375 拍，主线程被占住多少，这里就掉多少。
        let heartbeatStart = Date()
        var beats = 0
        while Date().timeIntervalSince(heartbeatStart) < 3 {
            try await Task.sleep(for: .milliseconds(8))
            let wave = 0.5 * (1 - cos(Double(beats % 80) / 80 * 2 * .pi))
            scrollTo(amplitude * wave)
            beats += 1
        }

        // 200 步往返，每步逼一次布局 + 绘制，量单帧主线程耗时。
        var frames: [Double] = []
        for step in 0..<200 {
            let wave = 0.5 * (1 - cos(Double(step % 80) / 80 * 2 * .pi))
            let start = CFAbsoluteTimeGetCurrent()
            scrollTo(amplitude * wave)
            layout()
            frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(8))
        }

        // hitTest：首中尾三处各 100 次。它不随规模涨才说明命中路径没被行数拖累。
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

        let reading = Reading(rows: rows,
                              mountMS: fixture.mountMS,
                              beats: beats,
                              frameP50: ProbeMetrics.percentile(frames, 0.5),
                              frameP95: ProbeMetrics.percentile(frames, 0.95),
                              overBudget: Double(frames.filter { $0 > 8.33 }.count)
                                  / Double(frames.count) * 100,
                              hitP50: ProbeMetrics.percentile(hits, 0.5),
                              views: viewCount(in: host),
                              documentHeight: document.frame.height,
                              scrollableHeight: maxOffset)
        print(String(format: """
            [probe-smoke] rows=%d mount=%.2fms beats=%d/375 frame-p50=%.3fms frame-p95=%.3fms \
            max=%.3fms over-8.33=%.1f%% hit-p50=%.1fus views=%d doc-h=%.0f scrollable=%.0f \
            amp=%.0f cpu=%.2fs rss=%.1fMB
            """,
            reading.rows, reading.mountMS, reading.beats, reading.frameP50, reading.frameP95,
            frames.max() ?? 0, reading.overBudget, reading.hitP50, reading.views,
            reading.documentHeight, reading.scrollableHeight, amplitude,
            ProbeMetrics.threadCPUSeconds(), ProbeMetrics.footprintMB()))
        print("[probe-smoke-views] rows=\(rows) \(classHistogram(in: host))")
        print("[probe-smoke-window] \(ProbeWindow.describe(fixture.window)) "
              + "cursorInside=\(ProbeWindow.cursorIsInside(fixture.window))")
        await closeWindows()
        return reading
    }

    // MARK: - 用例

    /// 整条链路跑一遍，断言只用结构判据；绝对毫秒只打印。
    func testProbeChainMeasuresLazyRowList() async throws {
        defer { closeAllWindows() }
        let small = try await measure(rows: 200)
        let large = try await measure(rows: 2000)

        // ① 真窗口确实上了屏且挡住了真鼠标（`measure` 内已断言过一次，这里留个显式的）。
        //    ② 懒栈真的懒：纯 Text 行不生成平台视图，NSView 数与行数无关。
        XCTAssertLessThanOrEqual(abs(large.views - small.views), 2,
                                 "纯 Text 的 LazyVStack 不该随行数长出 NSView："
                                 + "200 行 \(small.views) vs 2000 行 \(large.views)")
        // ③ 夹具真的能滚 —— 没有滚动余量的话上面所有滚动读数都是假的。
        XCTAssertGreaterThan(small.scrollableHeight, 0, "200 行也必须超过一屏")
        XCTAssertGreaterThan(large.scrollableHeight, small.scrollableHeight,
                             "2000 行的可滚动高度必须比 200 行大")
        // ④ 文档高度对得上行高 × 行数（懒栈会先估后修，留 20% 余量）。
        XCTAssertGreaterThan(large.documentHeight,
                             CGFloat(2000) * Self.rowHeight * 0.8,
                             "文档高度必须与 2000 行 × \(Self.rowHeight)pt 同一量级")
        // ⑤ 心跳确实在跑（拍数是相对尺，只挡「主线程完全被占死」这种硬故障）。
        XCTAssertGreaterThan(large.beats, 30, "3 秒 8ms 心跳一拍都收不到 = 主线程被占死")
        // ⑥ 三把尺本身有输出。
        XCTAssertGreaterThan(ProbeMetrics.footprintMB(), 0)
        XCTAssertGreaterThan(ProbeMetrics.threadCPUSeconds(), 0)
        XCTAssertEqual(ProbeMetrics.percentile([1, 2, 3, 4], 0.5), 3, accuracy: 0.0001,
                       "分位数口径：sorted[min(count-1, Int(count*q))]")
    }

    /// `VisionTextProbe` 的冒烟：同一个窗口截一张图，识别器要认出 `row_0123`
    /// 这样的行标签；识别器超预算就退回像素判据，空壳依旧判红。
    func testVisionTextProbeReadsRowLabels() async throws {
        defer { closeAllWindows() }
        let fixture = try makeFixture(rows: 2000)
        let scroll = fixture.scroll
        let document = try XCTUnwrap(scroll.documentView)
        let maxOffset = max(0, document.frame.height - scroll.contentSize.height)
        // 滚到第 120 行附近，视口里就有 row_0120…row_014x 这一段。
        let target = min(maxOffset, CGFloat(120) * Self.rowHeight)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        fixture.host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        fixture.host.displayIfNeeded()

        let host = fixture.host
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let ink = VisionTextProbe.inkFraction(rep)

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "probe-smoke-rows"
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-smoke-rows.png")
        try png.write(to: url)
        print("[probe-smoke-png] \(url.path) ink=\(String(format: "%.4f", ink))")

        if let text = await VisionTextProbe.text(png, languageCorrection: false) {
            print("[probe-smoke-ocr] ink=\(String(format: "%.4f", ink)) chars=\(text.count)\n\(text.prefix(400))")
            // 下划线常被识别器吞掉或读成空格，所以只钉「row + 三位以上数字」。
            XCTAssertNotNil(text.range(of: "(?i)row.{0,2}[0-9]{3}", options: .regularExpression),
                            "截图必须真的画出行标签：\(text.prefix(400))")
        } else {
            print("[probe-smoke-ocr-timeout] ink=\(String(format: "%.4f", ink))")
            XCTAssertGreaterThan(ink, 0.01,
                                 "识别器超预算后退回像素判据，列表仍不能是空壳")
        }
        await closeWindows()
    }
}
