import AppKit
import Markdown
import SwiftUI
import XCTest
@testable import uTerm

/// 文件预览的 Markdown 渲染（`MarkdownRenderer` → `MarkdownBlocks`）的挂载 /
/// 滚动成本探针。
///
/// 形态：外层一个 `ScrollView`，里面是 `VStack + ForEach(document.blockChildren)`
/// —— **刻意非 lazy**：`1a0bd63d`「修复窗口缩放时的布局卡死」把这里的
/// `LazyVStack` 换回了 `VStack`，`MarkdownRendererTests
/// .testMarkdownPreviewCoalescesParsingAndUsesStableBlocks` 至今钉着这条。
/// 所以这一处**不能**用「换懒栈」当处方，只能限制一次挂多少块。
///
/// 规模来源：预览对 Markdown 文件只有 50MB 的字节上限
/// （`FilePreviewModel.maxPreviewBytes`），块数没有任何上限。真实档取一份
/// 2000 行 README（≈600 块），极端档取 2MB（≈5 万块，含一张 200×6 的表）。
@MainActor
final class MarkdownPreviewCostTests: XCTestCase {

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func closeWindows() async {
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
    }

    private static let size = NSSize(width: 900, height: 700)

    // MARK: - 造数据

    /// 一份 README 形状的 Markdown：标题 / 段落 / 列表 / 代码块 / 引用循环铺开，
    /// 末尾挂一张 `rows × 6` 的表（表格是逐格 `MDInlineView`，单独计价）。
    static func document(blocks: Int, tableRows: Int = 0) -> String {
        var parts: [String] = []
        var produced = 0
        var section = 0
        while produced < blocks {
            section += 1
            parts.append("## \(section). 配置项 config-\(section)")
            produced += 1
            if produced >= blocks { break }
            parts.append("这一节说明 `config-\(section)` 的默认值、覆盖顺序与常见坑。"
                         + "写长一点让段落真的换行，**排版**成本才进得了账。"
                         + "参考 [文档](https://example.com/\(section))。")
            produced += 1
            if produced >= blocks { break }
            parts.append("- `--flag-\(section)` 打开特性\n"
                         + "- `--timeout-\(section)` 超时秒数\n"
                         + "- `--retry-\(section)` 重试次数")
            produced += 1
            if produced >= blocks { break }
            parts.append("```yaml\nconfig_\(section):\n  enabled: true\n  timeout: \(section)\n```")
            produced += 1
            if produced >= blocks { break }
            parts.append("> 注意：\(section) 号配置在旧版本里叫 legacy_\(section)。")
            produced += 1
        }
        if tableRows > 0 {
            var table = "| 选项 | 类型 | 默认 | 环境变量 | 说明 | 版本 |\n"
                + "| --- | --- | --- | --- | --- | --- |\n"
            for row in 0..<tableRows {
                table += "| opt_\(row) | string | none | OPT_\(row) | 第 \(row) 个选项 | 1.\(row % 10) |\n"
            }
            parts.append(table)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - 夹具

    private struct Fixture {
        let window: ProbeWindow.Unconstrained
        let host: NSHostingView<AnyView>
        let scroll: NSScrollView
        let document: NSView
        let mountMS: Double
        let parseMS: Double
        let blocks: Int
    }

    private func makeFixture(source: String, blockLimit: Int) throws -> Fixture {
        let parseStart = CFAbsoluteTimeGetCurrent()
        let parsed = Markdown.Document(parsing: source)
        let blocks = Array(parsed.blockChildren).count
        let parseMS = (CFAbsoluteTimeGetCurrent() - parseStart) * 1000

        let size = Self.size
        let root = AnyView(
            MarkdownRenderer(source: source, initialBlockLimit: blockLimit)
                .frame(width: size.width, height: size.height))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled], contentView: host,
                                      key: true, placement: .transparentOnScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .aqua)
        let start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let mountMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let scroll = try XCTUnwrap(host.firstScrollView(), "MarkdownRenderer 里必须有 NSScrollView")
        let documentView = try XCTUnwrap(scroll.documentView)
        let unconstrained = try XCTUnwrap(window as? ProbeWindow.Unconstrained)
        return Fixture(window: unconstrained, host: host, scroll: scroll,
                       document: documentView, mountMS: mountMS, parseMS: parseMS,
                       blocks: blocks)
    }

    private func viewCount(in root: NSView) -> Int {
        var n = 0
        func walk(_ v: NSView) { n += 1; for s in v.subviews { walk(s) } }
        walk(root)
        return n
    }

    private func classHistogram(in root: NSView) -> String {
        var counts: [String: Int] = [:]
        func walk(_ v: NSView) {
            counts[String(describing: type(of: v)), default: 0] += 1
            for s in v.subviews { walk(s) }
        }
        walk(root)
        return counts.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.key)×\($0.value)" }.joined(separator: "  ")
    }

    struct Reading {
        let arm: String
        let blocks: Int
        let chars: Int
        let parseMS: Double
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

    private func measure(arm: String, source: String, blockLimit: Int) async throws -> Reading {
        let fixture = try makeFixture(source: source, blockLimit: blockLimit)
        XCTAssertTrue(ProbeWindow.blindsRealMouse(fixture.window),
                      "透明屏内档必须谎报鼠标位置")
        let scroll = fixture.scroll
        let document = fixture.document
        let host = fixture.host
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
                let point = NSPoint(x: CGFloat(40 + (i % 9) * 60), y: CGFloat(40 + (i % 11) * 50))
                let start = CFAbsoluteTimeGetCurrent()
                _ = host.hitTest(point)
                hits.append((CFAbsoluteTimeGetCurrent() - start) * 1_000_000)
            }
        }

        let reading = Reading(arm: arm,
                              blocks: fixture.blocks,
                              chars: source.count,
                              parseMS: fixture.parseMS,
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
            [md-preview] arm=%@ blocks=%d chars=%d parse=%.1fms mount=%.1fms beats=%d/375 \
            frame-p50=%.3fms frame-p95=%.3fms over-8.33=%.1f%% hit-p50=%.1fus views=%d \
            doc-h=%.0f scrollable=%.0f cpu=%.2fs rss=%.1fMB
            """,
            reading.arm, reading.blocks, reading.chars, reading.parseMS, reading.mountMS,
            reading.beats, reading.frameP50, reading.frameP95, reading.overBudget,
            reading.hitP50, reading.views, reading.documentHeight, reading.scrollableHeight,
            ProbeMetrics.threadCPUSeconds(), ProbeMetrics.footprintMB()))
        print("[md-preview-views] arm=\(arm) \(classHistogram(in: host))")
        await closeWindows()
        return reading
    }

    // MARK: - 用例

    /// 真实档：2000 行 README。两臂 —— 不分段（改前）vs 分段（改后）。
    /// 真实档的块数本来就在一段之内，两臂应当读数相同；这一条钉的是
    /// 「分段不能让常规文件变慢」。
    func testRealisticReadmeCost() async throws {
        defer { closeAllWindows() }
        let source = Self.document(blocks: 600)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).count
        print("[md-preview-scale] realistic lines=\(lines) chars=\(source.count)")
        let unchunked = try await measure(arm: "unchunked-600", source: source,
                                          blockLimit: Int.max)
        let chunked = try await measure(arm: "chunked-600", source: source,
                                        blockLimit: MarkdownBlockWindow.defaultLimit)
        XCTAssertEqual(unchunked.blocks, chunked.blocks, "两臂必须解析出同样多的块")
        XCTAssertGreaterThan(unchunked.scrollableHeight, 0, "600 块必须超过一屏")
        print(String(format: "[md-preview-ratio] realistic chunked/unchunked mount=%.2f "
                     + "beats=%.2f p50=%.2f views=%.2f",
                     chunked.mountMS / max(unchunked.mountMS, 0.001),
                     Double(chunked.beats) / Double(max(unchunked.beats, 1)),
                     chunked.frameP50 / max(unchunked.frameP50, 0.001),
                     Double(chunked.views) / Double(max(unchunked.views, 1))))
    }

    /// 极端档：2MB / ≈5 万块，末尾一张 200×6 的表。
    func testExtremeDocumentCost() async throws {
        defer { closeAllWindows() }
        let source = Self.extremeSource()
        let chunked = try await measure(arm: "chunked-extreme", source: source,
                                        blockLimit: MarkdownBlockWindow.defaultLimit)
        let unchunked = try await measure(arm: "unchunked-extreme", source: source,
                                          blockLimit: Int.max)
        print(String(format: "[md-preview-ratio] extreme chunked/unchunked mount=%.2f "
                     + "beats=%.2f p50=%.2f p95=%.2f views=%.2f doc-h=%.2f",
                     chunked.mountMS / max(unchunked.mountMS, 0.001),
                     Double(chunked.beats) / Double(max(unchunked.beats, 1)),
                     chunked.frameP50 / max(unchunked.frameP50, 0.001),
                     chunked.frameP95 / max(unchunked.frameP95, 0.001),
                     Double(chunked.views) / Double(max(unchunked.views, 1)),
                     Double(chunked.documentHeight) / Double(max(unchunked.documentHeight, 1))))
        // 结构判据：分段臂挂载的文档必须显著短于不分段臂 —— 段真的钳住了挂载量。
        XCTAssertLessThan(chunked.documentHeight, unchunked.documentHeight * 0.5,
                          "分段臂的文档高度必须显著低于不分段臂："
                          + "\(chunked.documentHeight) vs \(unchunked.documentHeight)")
        // 结构判据：两臂的 NSView 数都不随块数走（Markdown 块渲染成 `Text`，
        //   不产生平台视图）—— 所以 NSView 在这一处**不是**有效的成本尺，
        //   真正的账在文档高度 / 布局树规模上。分段臂只多出一个「继续渲染」的
        //   按钮壳，允许 ±4。
        XCTAssertLessThanOrEqual(abs(chunked.views - unchunked.views), 4,
                                 "Markdown 块不产生平台视图，两臂 NSView 应当基本相等："
                                 + "\(chunked.views) vs \(unchunked.views)")
        // 结构判据：不分段臂的极端档必须真的超预算（否则上面那条是空断言）。
        XCTAssertGreaterThan(unchunked.overBudget, 50,
                             "不分段臂的极端档必须真的超预算：\(unchunked.overBudget)%")
        XCTAssertLessThan(chunked.overBudget, unchunked.overBudget,
                          "分段臂的超预算帧必须少于不分段臂")
    }

    static func extremeSource() -> String {
        var source = document(blocks: 50_000, tableRows: 200)
        // 补到 2MB —— 上限是 50MB 字节数，块数没有上限，两者都要撑到位。
        while source.utf8.count < 2_000_000 {
            source += "\n\n" + document(blocks: 200)
        }
        return source
    }

    /// `isStreaming` 在预览皮肤下是不是真的什么都不改：`.preview` 的
    /// `usesChatCodeBlock == false`，`MarkdownBlocks` 只把这个标志传给
    /// `ChatCodeBlock`，而预览根本不走那条分支。量不出问题就别改（guide §二）。
    func testStreamingFlagIsInertForPreviewSkin() {
        XCTAssertFalse(MarkdownStyle.preview.usesChatCodeBlock,
                       "预览皮肤走纯等宽块，不走 ChatCodeBlock —— "
                       + "isStreaming 因此对预览的渲染结果没有影响")
        XCTAssertTrue(MarkdownStyle.chat.usesChatCodeBlock)
    }
}
