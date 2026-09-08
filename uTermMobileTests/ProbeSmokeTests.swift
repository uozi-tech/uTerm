import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// iOS 探针链路的自证用例 —— **这里不评判任何 uTermMobile 视图**。
///
/// 被测对象是夹具本身：`MobileProbeWindow` / `DisplayLinkCounter` /
/// `ProbeMetrics` 三件零件，在 `uTermMobile.app` 这个测试宿主里是不是真的能跑通
/// 「建窗 → 上屏 → 挂 SwiftUI → 滚 → 量」这一整条链路。后面每个屏幕的评估任务
/// 直接抄这个类的形状，不必再验一遍地基。
///
/// 夹具刻意只用**纯 Text 行**（`ScrollView + LazyVStack + ForEach`）：
/// 没有 Button、没有 TextField，也就没有平台视图。于是「`UIView` 数不随行数涨」
/// 是一条**结构判据**而非性能判据 —— 它对机器负载免疫，可以当硬断言；
/// 绝对毫秒只打印（playbook §一）。
///
/// 隔离：`uTermMobileTests` 的 `SWIFT_DEFAULT_ACTOR_ISOLATION` 与 `uTermTests`
/// 对齐取 `nonisolated`（宿主 `uTermMobile` 是 `MainActor`），所以这里显式
/// `@MainActor`，且**不覆写 `tearDown()`**（父类那个是 `nonisolated`，
/// 覆写不能改隔离），改用每条用例开头 `defer { closeAllWindows() }`。
@MainActor
final class ProbeSmokeTests: XCTestCase {

    private var windows: [UIWindow] = []

    private func closeAllWindows() {
        for window in windows { MobileProbeWindow.close(window) }
        windows.removeAll()
    }

    // MARK: - 夹具

    /// 行高写死，几何判据（内容高度、滚到第几行）才算得准。
    private static let rowHeight: CGFloat = 22
    /// 尺寸写死而不用屏幕尺寸：iPhone 与 iPad 的可视行数差三倍，
    /// 写死才能让同一份读数在两台模拟器之间可比。
    private static let size = CGSize(width: 390, height: 700)

    private struct Reading {
        let rows: Int
        let mountMS: Double
        let sleepBeats: Int
        let displayTicks: Int
        let idealTicks: Int
        let frameP50: Double
        let frameP95: Double
        let overBudget: Double
        let hitP50: Double
        let views: Int
        let contentHeight: CGFloat
        let scrollableHeight: CGFloat
        let footprintMB: Double
    }

    private struct Fixture {
        let window: UIWindow
        let host: UIHostingController<AnyView>
        let scroll: UIScrollView
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

    /// 建窗 + 挂载 + 找到滚动视图。挂载耗时单独计：`layoutIfNeeded()` 之前什么都
    /// 没发生，首次布局必须算进这一步的账。
    private func makeFixture(rows: Int) throws -> Fixture {
        let size = Self.size
        let root = AnyView(rowList(rows).frame(width: size.width, height: size.height))
        let (window, host) = MobileProbeWindow.make(size: size, rootView: root)
        windows.append(window)

        let start = CFAbsoluteTimeGetCurrent()
        host.view.layoutIfNeeded()
        // iOS 没有 `displayIfNeeded()`；`CATransaction.flush()` 是把这一轮的图层
        // 提交真的推出去的等价手法，不 flush 的话「挂载」只量到布局、漏掉 CA 那笔账。
        CATransaction.flush()
        let mountMS = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let scroll = try XCTUnwrap(host.view.firstScrollView(), "夹具里必须有 UIScrollView")
        return Fixture(window: window, host: host, scroll: scroll, mountMS: mountMS)
    }

    /// 拆窗后留一小段，让上一档的图层后备存储真的散掉。
    private func closeWindows() async {
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
    }

    // MARK: - 量

    /// 一档：挂载 → 扫一遍让懒行实例化 → 3s 心跳（sleep 拍 + CADisplayLink 拍）
    /// → 200 步往返单帧 → hitTest。
    ///
    /// 往返幅度钳在**约 3 个视口**（playbook：全程往返在大列表上一步跨几十屏，
    /// 量到的是「跳转」不是「滚动」）。
    private func measure(rows: Int) async throws -> Reading {
        let fixture = try makeFixture(rows: rows)
        let scroll = fixture.scroll
        let host = fixture.host

        let viewport = scroll.bounds.height
        let maxOffset = max(0, scroll.contentSize.height - viewport)
        let amplitude = min(maxOffset, viewport * 3)

        func scrollTo(_ y: CGFloat) {
            scroll.setContentOffset(CGPoint(x: 0, y: min(maxOffset, max(0, y))), animated: false)
        }
        func layout() {
            host.view.layoutIfNeeded()
            CATransaction.flush()
        }

        // 先以小于一屏的间距扫过要往返的那一段，把懒建的行全部计入。
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

        // 3 秒双心跳：
        // ① `Task.sleep(8ms)` 拍数 —— 主线程还愿不愿意回到 runloop（理想 375 拍）。
        // ② `CADisplayLink` 拍数 —— 渲染循环实际交付了几帧（理想 = maxFPS × 3）。
        let maxFPS = MobileProbeWindow.maximumFramesPerSecond()
        let counter = DisplayLinkCounter()
        counter.start()
        let heartbeatStart = Date()
        var sleepBeats = 0
        while Date().timeIntervalSince(heartbeatStart) < 3 {
            try await Task.sleep(for: .milliseconds(8))
            let wave = 0.5 * (1 - cos(Double(sleepBeats % 80) / 80 * 2 * .pi))
            scrollTo(amplitude * wave)
            sleepBeats += 1
        }
        counter.stop()
        let displayTicks = counter.ticks
        let tickP95 = ProbeMetrics.percentile(counter.intervals, 0.95)

        // 200 步往返，每步逼一次布局 + 提交，量单帧主线程耗时。
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
                let point = CGPoint(x: CGFloat(40 + (i % 8) * 40), y: CGFloat(40 + (i % 15) * 40))
                let start = CFAbsoluteTimeGetCurrent()
                _ = host.view.hitTest(point, with: nil)
                hits.append((CFAbsoluteTimeGetCurrent() - start) * 1_000_000)
            }
        }

        let reading = Reading(rows: rows,
                              mountMS: fixture.mountMS,
                              sleepBeats: sleepBeats,
                              displayTicks: displayTicks,
                              idealTicks: maxFPS * 3,
                              frameP50: ProbeMetrics.percentile(frames, 0.5),
                              frameP95: ProbeMetrics.percentile(frames, 0.95),
                              overBudget: Double(frames.filter { $0 > 8.33 }.count)
                                  / Double(frames.count) * 100,
                              hitP50: ProbeMetrics.percentile(hits, 0.5),
                              views: host.view.recursiveViewCount(),
                              contentHeight: scroll.contentSize.height,
                              scrollableHeight: maxOffset,
                              footprintMB: ProbeMetrics.footprintMB())
        print(String(format: """
            [probe-smoke] rows=%d mount=%.2fms sleep-beats=%d/375 display-ticks=%d/%d \
            tick-p95=%.2fms frame-p50=%.3fms frame-p95=%.3fms max=%.3fms over-8.33=%.1f%% \
            hit-p50=%.1fus views=%d content-h=%.0f scrollable=%.0f amp=%.0f \
            cpu=%.2fs footprint=%.1fMB
            """,
            reading.rows, reading.mountMS, reading.sleepBeats,
            reading.displayTicks, reading.idealTicks, tickP95,
            reading.frameP50, reading.frameP95, frames.max() ?? 0, reading.overBudget,
            reading.hitP50, reading.views, reading.contentHeight, reading.scrollableHeight,
            amplitude, ProbeMetrics.threadCPUSeconds(), reading.footprintMB))
        print("[probe-smoke-views] rows=\(rows) \(host.view.classHistogram())")
        print("[probe-smoke-window] \(MobileProbeWindow.describe(fixture.window))")
        await closeWindows()
        return reading
    }

    // MARK: - 用例

    /// ① `@testable import uTermMobile` 真的引到了产品类型。
    ///
    /// 单独一条用例：它失败说明 `TEST_HOST` / `BUNDLE_LOADER` 接错了，
    /// 与下面那条量读数的用例是两码事，混在一起会让「链路没通」看着像「探针跑挂了」。
    func testHostSymbolsAreVisible() throws {
        // `MTab` 是 uTermMobile/Shell/MobileStore.swift 里的产品类型（主标签枚举）。
        // 挑它是因为它没有任何 SwiftData / CloudKit 依赖，构造它不会连带唤起容器。
        XCTAssertEqual(MTab.allCases.count, 5, "主标签共 5 个：主机/终端/文件/命令/设置")
        XCTAssertEqual(MTab.hosts.label, "主机")
        XCTAssertEqual(MTab(rawValue: "settings"), .settings)
        print("[probe-smoke-host] MTab.allCases = \(MTab.allCases.map(\.rawValue))")
    }

    /// ② 整条量测链路跑一遍，断言只用结构判据；绝对毫秒只打印。
    func testProbeChainMeasuresLazyRowList() async throws {
        defer { closeAllWindows() }
        let small = try await measure(rows: 200)
        let large = try await measure(rows: 2000)

        // 懒栈真的懒：纯 Text 行不生成平台视图，UIView 数与行数无关。
        XCTAssertLessThanOrEqual(abs(large.views - small.views), 2,
                                 "纯 Text 的 LazyVStack 不该随行数长出 UIView："
                                 + "200 行 \(small.views) vs 2000 行 \(large.views)")
        // 夹具真的能滚 —— 没有滚动余量的话上面所有滚动读数都是假的。
        XCTAssertGreaterThan(small.scrollableHeight, 0, "200 行也必须超过一屏")
        XCTAssertGreaterThan(large.scrollableHeight, small.scrollableHeight,
                             "2000 行的可滚动高度必须比 200 行大")
        // 内容高度对得上行高 × 行数（懒栈会先估后修，留 20% 余量）。
        XCTAssertGreaterThan(large.contentHeight,
                             CGFloat(2000) * Self.rowHeight * 0.8,
                             "内容高度必须与 2000 行 × \(Self.rowHeight)pt 同一量级")
        // 两种心跳都确实在跑（拍数是相对尺，只挡「主线程被占死 / 渲染循环停摆」这种硬故障）。
        XCTAssertGreaterThan(large.sleepBeats, 30, "3 秒 8ms 心跳一拍都收不到 = 主线程被占死")
        XCTAssertGreaterThan(large.displayTicks, 30,
                             "3 秒 CADisplayLink 收不到 30 拍 = 渲染循环没在跑，"
                             + "窗口很可能没真上屏（ticks=\(large.displayTicks)/\(large.idealTicks)）")
        // 三把尺本身有输出。
        XCTAssertGreaterThan(large.footprintMB, 0)
        XCTAssertGreaterThan(ProbeMetrics.threadCPUSeconds(), 0)
        XCTAssertEqual(ProbeMetrics.percentile([1, 2, 3, 4], 0.5), 3, accuracy: 0.0001,
                       "分位数口径：sorted[min(count-1, Int(count*q))]")
        // hitTest 不随规模涨（结构判据：闸门守比值，不守绝对微秒）。
        XCTAssertLessThan(large.hitP50, max(small.hitP50 * 4, 40),
                          "hitTest 随行数涨了 4 倍以上：200 行 \(small.hitP50)us vs "
                          + "2000 行 \(large.hitP50)us")
    }

    /// ③ 窗口真的上了屏 —— 渲染出来的像素不是空壳。
    ///
    /// 桌面那份用 `VisionTextProbe` 做 OCR；iOS 这条先只做**墨迹判据**
    /// （非白像素占比），不引 Vision：模拟器上 OCR 慢且不稳，而「空壳」这种
    /// 硬故障墨迹就能挡住。后续真要认字再把 `VisionTextProbe` 移过来。
    func testRenderedRowsAreNotBlank() async throws {
        defer { closeAllWindows() }
        let fixture = try makeFixture(rows: 2000)
        let scroll = fixture.scroll
        let maxOffset = max(0, scroll.contentSize.height - scroll.bounds.height)
        scroll.setContentOffset(
            CGPoint(x: 0, y: min(maxOffset, CGFloat(120) * Self.rowHeight)), animated: false)
        fixture.host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        CATransaction.flush()

        let view = fixture.host.view!
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        // `drawHierarchy(afterScreenUpdates:)` 而非 `layer.render(in:)`：后者不走
        // SwiftUI 的绘制路径，纯 Text 会被画成空白，墨迹判据直接假红。
        let png = try XCTUnwrap(renderer.pngData { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        })

        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "probe-smoke-rows"
        attachment.lifetime = .keepAlways
        add(attachment)

        let ink = try inkFraction(png)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-smoke-rows.png")
        try png.write(to: url)
        print("[probe-smoke-png] \(url.path) bytes=\(png.count) ink=\(String(format: "%.4f", ink))")
        XCTAssertGreaterThan(ink, 0.005, "截图是空壳：非白像素只占 \(ink * 100)%")
        await closeWindows()
    }

    /// 非白像素占比。抽样（每 4 个像素取 1 个）足够挡空壳，全扫在 3x 屏上要几百万次。
    private func inkFraction(_ png: Data) throws -> Double {
        let image = try XCTUnwrap(UIImage(data: png)?.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var dark = 0, total = 0
        for i in stride(from: 0, to: width * height, by: 4) {
            total += 1
            if Int(pixels[i * 4]) + Int(pixels[i * 4 + 1]) + Int(pixels[i * 4 + 2]) < 600 {
                dark += 1
            }
        }
        return total == 0 ? 0 : Double(dark) / Double(total)
    }
}
