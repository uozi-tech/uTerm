import AppKit
import GhosttyTerminal
import IOSurface
import XCTest
@testable import uTerm

/// 终端字体画出来的样子（Mac）：中文的字重、全角标点的位置、英文的粗细。
///
/// 起因是试用 Ghostty 版时的三个毛病：中文偏细、全角标点贴在格子左边（字距怪）、同一份配置重启后中文时粗时细。
/// 根子在字体回退：不显式写 PingFang SC 时，汉字走 Ghostty 的自动回退，落到哪一款、什么字重不稳定；另外 Ghostty 默认
/// 不做 macOS 的字体平滑加粗，笔画比 CoreGraphics 画的细。定下的配置见 `GhosttyTerminalConfig.base` / `fontFamilies()`：
/// 系统等宽 → Menlo → PingFang SC，`font-style = Medium`，`font-thicken = true`、强度 0。
///
/// 引擎没有「这个字用了哪款字体」的读法，所以这里读真的 surface **画出来的像素**（IOSurface）：一行字占的那一条里，
/// 每个像素偏离底色多少，折算成「墨量」——这一行有字的格子里，平均每个像素被前景色盖住的比例（0–1）。字越粗墨量越大。
///
/// 每次渲染都**新建一个 controller**（一个 `ghostty_app_t`，自带一份字体与图集缓存），不碰进程里共用的那个
/// （`GhosttyTerminalConfig.controller`）：要核的正是「从头解析一遍字体，结果是不是同一个」。Ghostty 的测试夹具注明并行建
/// app 会 abort，所以一律串行建、读完就放掉。
@MainActor
final class GhosttyFontRenderingTests: XCTestCase {

    // MARK: 画的内容

    /// 纯汉字，不带标点（标点的位置单独一行核）。
    private static let chinese = "漏洞你停留的那一行被淘汰后视图停在最旧内容上继续流动"
    private static let latin = "testAnchorEvictedClampsToTopWithoutResumingFollow feed scrollback"
    private static let bold = "Bold main 1pt Waiting for 4 background agents"
    private static let chineseRow = 0, quoteRow = 1, latinRow = 2, boldRow = 3
    /// 「 在第 0–1 列，」 在第 4–5 列。
    private static let quotes = "「  」"

    /// 清屏、藏光标（块光标会算进墨量），四行内容。重复写是幂等的。
    private static let content = "\u{1b}[?25l\u{1b}[2J\u{1b}[H"
        + chinese + "\r\n" + quotes + "\r\n" + latin + "\r\n" + "\u{1b}[1m" + bold + "\u{1b}[0m"

    private static var chineseColumns: Range<Int> { 0..<(chinese.count * 2) }
    private static var latinColumns: Range<Int> { 0..<latin.count }
    private static var boldColumns: Range<Int> { 0..<bold.count }

    // MARK: 一帧

    /// 画出来的一帧：每个像素偏离底色的量（三个通道里最大的那个，0–255），原点在左上。
    private struct Frame {
        let width: Int, height: Int
        /// 一格的像素尺寸。
        let cellWidth: Int, cellHeight: Int
        let deviation: [UInt8]
        /// 前景色与底色之间差多少（整格涂满前景色时一个像素的偏离量）。
        let full: Double

        private func sum(row: Int, columns: Range<Int>) -> (ink: Double, area: Int) {
            let x0 = max(0, columns.lowerBound * cellWidth), x1 = min(width, columns.upperBound * cellWidth)
            let y0 = max(0, row * cellHeight), y1 = min(height, (row + 1) * cellHeight)
            guard x1 > x0, y1 > y0 else { return (0, 0) }
            var total = 0
            for y in y0..<y1 {
                for x in x0..<x1 { total += Int(deviation[y * width + x]) }
            }
            return (Double(total) / full, (x1 - x0) * (y1 - y0))
        }

        /// 这几格里的墨量：平均每个像素被前景色盖住的比例。
        func ink(row: Int, columns: Range<Int>) -> Double {
            let s = sum(row: row, columns: columns)
            return s.area > 0 ? s.ink / Double(s.area) : 0
        }

        /// 这几格里被盖住的像素当量（不除面积）。
        func inkPixels(row: Int, columns: Range<Int>) -> Double { sum(row: row, columns: columns).ink }

        /// 这几格里两帧之间平均每个像素差多少（按前景色满格 = 1 折算）。完全一样是 0。
        func difference(from other: Frame, row: Int, columns: Range<Int>) -> Double {
            guard width == other.width, height == other.height, cellWidth == other.cellWidth, cellHeight == other.cellHeight else { return 1 }
            let x0 = max(0, columns.lowerBound * cellWidth), x1 = min(width, columns.upperBound * cellWidth)
            let y0 = max(0, row * cellHeight), y1 = min(height, (row + 1) * cellHeight)
            guard x1 > x0, y1 > y0 else { return 1 }
            var total = 0
            for y in y0..<y1 {
                for x in x0..<x1 { total += abs(Int(deviation[y * width + x]) - Int(other.deviation[y * width + x])) }
            }
            return Double(total) / full / Double((x1 - x0) * (y1 - y0))
        }

        /// 占两格的一个字（左边那格在第 `column` 列）的墨迹有多少落在右边那一格。
        func rightShare(row: Int, column: Int) -> Double {
            let left = inkPixels(row: row, columns: column..<(column + 1))
            let right = inkPixels(row: row, columns: (column + 1)..<(column + 2))
            return left + right > 0 ? right / (left + right) : 0
        }
    }

    private static func capture(_ surface: IOSurfaceRef, cell: CGSize, full: Double) -> Frame {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        let bpr = IOSurfaceGetBytesPerRow(surface), bpe = max(4, IOSurfaceGetBytesPerElement(surface))
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        // 底色取右下角（那里没有字）。
        let bgOffset = (h - 3) * bpr + (w - 3) * bpe
        let bg = (Int(base[bgOffset]), Int(base[bgOffset + 1]), Int(base[bgOffset + 2]))
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let rowBase = y * bpr
            for x in 0..<w {
                let o = rowBase + x * bpe
                let d = max(abs(Int(base[o]) - bg.0), abs(Int(base[o + 1]) - bg.1), abs(Int(base[o + 2]) - bg.2))
                out[y * w + x] = UInt8(min(255, d))
            }
        }
        return Frame(width: w, height: h, cellWidth: Int(cell.width), cellHeight: Int(cell.height), deviation: out, full: full)
    }

    // MARK: 渲染

    /// 正式配置（`GhosttyTerminalConfig.base`）。
    private var production: GhosttyTerminal.TerminalConfiguration {
        GhosttyTerminalConfig.base(settings: TerminalSettings(cursorShape: .block, cursorBlink: false, scrollback: 3_000,
                                                              copyOnSelect: false))
    }

    /// 正式配置换一条族名回退链（`font-family` 给空值是清空前面写过的）。
    private func production(families: [String]) -> GhosttyTerminal.TerminalConfiguration {
        var config = production.custom("font-family", "")
        for family in families { config = config.custom("font-family", family) }
        return config
    }

    /// 用一个**新建的** controller、浅色配色，把 `content` 画出来，读回这一帧。读完窗口收走、controller 放掉。
    ///
    /// 第一帧常常还是空的（字体还没解析完、图集还没上传），测试窗口被遮挡时显示节拍还会停：所以一直等到中文那一行有墨、
    /// 而且连着两次读到的墨量一样才算数；每一轮都把窗口叫到前面、把 surface 叫回出帧，久等不到就把内容再写一遍。
    private func render(_ configuration: GhosttyTerminal.TerminalConfiguration,
                        file: StaticString = #filePath, line: UInt = #line) async throws -> Frame {
        let controller = GhosttyTerminal.TerminalController(configSource: .none, theme: GhosttyTerminalConfig.theme(),
                                                            terminalConfiguration: configuration)
        controller.setColorScheme(.light)
        let io = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let rect = NSRect(x: 0, y: 0, width: 1_040, height: 120)
        let view = GhosttySurfaceView(frame: rect)
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(io))
        let window = ProbeWindow.make(contentRect: rect, contentView: view, placement: .transparentOnScreen, keepsDrawing: true)
        window.appearance = NSAppearance(named: .aqua)
        defer {
            window.orderOut(nil)
            view.removeFromSuperview()
        }
        try XCTSkipUnless(window.backingScaleFactor == 2, "墨量的期望值是在 2x 屏上量的")

        let scheme = uTerm.TerminalColorScheme.vscodeLight
        let fg = scheme.foregroundColor.usingColorSpace(.sRGB) ?? scheme.foregroundColor
        let bg = scheme.backgroundColor.usingColorSpace(.sRGB) ?? scheme.backgroundColor
        let full = 255 * max(abs(fg.redComponent - bg.redComponent), abs(fg.greenComponent - bg.greenComponent),
                             abs(fg.blueComponent - bg.blueComponent))

        func read() -> Frame? {
            guard let cell = view.uTermCellPixels, let surface = GhosttyFrameWatch.currentSurface(of: view) else { return nil }
            return Self.capture(surface, cell: cell, full: Double(full))
        }

        let deadline = Date().addingTimeInterval(15)
        var lastFeed = Date.distantPast
        var previous: Double?
        while Date() < deadline {
            window.orderFrontRegardless()
            view.setSurfaceVisible(true)
            // surface 还没建好时写进去的字节会排队；久等不到画面就再写一遍（内容以清屏开头，幂等）。
            if view.uTermCellPixels != nil, Date().timeIntervalSince(lastFeed) > 2 {
                io.receive(Self.content)
                lastFeed = Date()
                previous = nil
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard let frame = read() else { continue }
            let ink = frame.ink(row: Self.chineseRow, columns: Self.chineseColumns)
            if ink > 0.02, let previous, previous == ink,
               frame.ink(row: Self.latinRow, columns: Self.latinColumns) > 0.02 {
                return frame
            }
            previous = ink
        }
        XCTFail("15 秒内没等到画面（测试窗口被遮挡时引擎不出帧）", file: file, line: line)
        throw XCTSkip("没有画面可读")
    }

    private func percent(_ value: Double) -> String { String(format: "%.2f%%", value * 100) }

    private func describe(_ frame: Frame) -> String {
        "格子 \(frame.cellWidth)×\(frame.cellHeight) px，"
            + "中文 \(percent(frame.ink(row: Self.chineseRow, columns: Self.chineseColumns)))，"
            + "英文 \(percent(frame.ink(row: Self.latinRow, columns: Self.latinColumns)))，"
            + "粗体 \(percent(frame.ink(row: Self.boldRow, columns: Self.boldColumns)))，"
            + "「 右半边 \(percent(frame.rightShare(row: Self.quoteRow, column: 0)))"
    }

    // MARK: 期望值
    //
    // 2026-11-10 实测（12 pt、2x 屏、格子 15×28 px、浅色配色；同一进程里新建 controller 多次、另外分三个进程各跑一遍，
    // 读数逐像素相同）：
    //
    //   配置                                         中文      英文      粗体     「 落在右半边
    //   正式配置（系统等宽 → Menlo → PingFang SC）   28.37%   19.47%   22.52%   100%
    //   去掉 Menlo（系统等宽 → PingFang SC）         与正式配置逐像素相同
    //   不写 PingFang SC（汉字走自动回退）           30.14%   19.47%   22.52%   0%（贴左）
    //   正式配置去掉 font-thicken                    24.59%   16.87%   20.18%   100%
    //   正式配置把 font-style 换成 Regular           22.84%   17.28%   22.52%   100%
    //
    // 自动回退那一行是这几次运行里落到的那一款（比苹方 Medium 还重、标点贴左）；试用时见过它落到细的一款，
    // 中文墨量掉到正式配置的六成左右（约 17%）。

    /// 中文行墨量的下限。正式配置 28.37%；关掉加粗是 24.59%、字重退成 Regular 是 22.84%、回退到细体约 17%。
    /// 取正式配置与「关掉加粗」的中点，两头各留约 1.9 个百分点。
    private static let chineseInkFloor = 0.265
    /// 英文行墨量的下限。正式配置 19.47%；关掉加粗是 16.87%、字重退成 Regular 是 17.28%。取 19.47 与 17.28 的中点。
    private static let latinInkFloor = 0.184
    /// 两次渲染之间允许的差：墨量差不到 0.2 个百分点、同一条里平均每个像素差不到 1%。实测是 0；
    /// 换一款字体 / 字重时这一条的像素差在 3.8%–6.3%。
    private static let sameInk = 0.002, samePixels = 0.01

    // MARK: 用例

    /// 「中文字重不稳定」的回归：同一份配置新建两个 controller 各从头解析一遍字体，画出来的中文是同一个样子。
    func test_chinese_weight_is_the_same_across_fresh_controllers() async throws {
        let first = try await render(production)
        let second = try await render(production)
        let a = first.ink(row: Self.chineseRow, columns: Self.chineseColumns)
        let b = second.ink(row: Self.chineseRow, columns: Self.chineseColumns)
        XCTAssertEqual(a, b, accuracy: Self.sameInk, "两次的中文墨量：\(percent(a)) / \(percent(b))")
        let difference = second.difference(from: first, row: Self.chineseRow, columns: Self.chineseColumns)
        XCTAssertLessThan(difference, Self.samePixels, "两次的中文行逐像素差 \(percent(difference))（换了字体或字重）")
        XCTAssertEqual(first.cellWidth, second.cellWidth)
        XCTAssertEqual(first.cellHeight, second.cellHeight)
    }

    /// 「中文偏细」的回归：中文行的墨量不低于下限（汉字落到细体、字重没取到 Medium、加粗没开，都会掉到下限以下）。
    func test_chinese_is_not_thin() async throws {
        let frame = try await render(production)
        let ink = frame.ink(row: Self.chineseRow, columns: Self.chineseColumns)
        XCTAssertGreaterThanOrEqual(ink, Self.chineseInkFloor, describe(frame))
    }

    /// 「字距怪」的回归：全角左引号「占两格，墨迹在右半边（苹方的排法，挨着后面的字）。汉字走自动回退、落到
    /// 界面字体的变体时它贴在左边那一格。
    func test_fullwidth_left_quote_sits_in_the_right_half() async throws {
        let frame = try await render(production)
        XCTAssertGreaterThan(frame.inkPixels(row: Self.quoteRow, columns: 0..<2), 10, "前提：「 画出来了。\(describe(frame))")
        XCTAssertGreaterThanOrEqual(frame.rightShare(row: Self.quoteRow, column: 0), 0.9, describe(frame))
        // 右引号」反过来，墨迹在左半边（挨着前面的字）。
        XCTAssertLessThanOrEqual(frame.rightShare(row: Self.quoteRow, column: 4), 0.1, "」 应在左半边")
    }

    /// 英文的粗细：`font-thicken` 开着、字重是 Medium 时英文行的墨量不低于下限（Ghostty 默认不加粗，笔画细一截）。
    func test_latin_is_thickened_to_the_previous_weight() async throws {
        let frame = try await render(production)
        let ink = frame.ink(row: Self.latinRow, columns: Self.latinColumns)
        XCTAssertGreaterThanOrEqual(ink, Self.latinInkFloor, describe(frame))
        // 粗体比常规更重（两行文字不同，比的是平均每格的墨量）。
        XCTAssertGreaterThan(frame.ink(row: Self.boldRow, columns: Self.boldColumns), ink, describe(frame))
    }

    /// 回退链里 Menlo 排在苹方前面，不影响汉字：和「系统等宽 → PingFang SC」（并排对照时定下的顺序）画出来逐像素相同，
    /// 也就是汉字和全角标点仍然落在苹方、字重不变。
    func test_menlo_ahead_of_pingfang_leaves_chinese_on_pingfang() async throws {
        let families = GhosttyTerminalConfig.fontFamilies()
        let system = try XCTUnwrap(TerminalSettings.textFont().familyName)
        XCTAssertEqual(families, [system, "Menlo", "PingFang SC"], "前提：正式的回退链")
        let withMenlo = try await render(production)
        let withoutMenlo = try await render(production(families: [system, "PingFang SC"]))
        for (name, row, columns) in [("中文行", Self.chineseRow, Self.chineseColumns), ("引号行", Self.quoteRow, 0..<6),
                                     ("英文行", Self.latinRow, Self.latinColumns)] {
            let difference = withMenlo.difference(from: withoutMenlo, row: row, columns: columns)
            XCTAssertLessThan(difference, Self.samePixels,
                              "\(name)逐像素差 \(percent(difference))。有 Menlo：\(describe(withMenlo))；没有：\(describe(withoutMenlo))")
        }
    }

    /// 回退链里的 Menlo 只是占位，不起兜底作用：`font-style = Medium` 对链里每个族名都生效，Menlo 没有 Medium 这一款
    /// （只有 Regular / Bold / Italic / Bold Italic），按「Menlo + Medium」找不到，这一格被跳过。实测拿掉系统等宽后
    /// 「Menlo → PingFang SC」+ Medium 的格子是 24×34 px，和只写 PingFang SC 逐项相同（苹方成了主字体）。
    /// 这没有关系：系统等宽（`.AppleSystemUIFontMonospaced`）在 macOS 上总取得到、而且有 Medium，链的第一格从不落空。
    /// 这里核的就是这件事：链的第一格是系统等宽、取得到 Medium，正式配置画出来的格子是等宽字体的宽度。
    func test_system_monospace_is_always_available_so_menlo_is_only_a_placeholder() async throws {
        let families = GhosttyTerminalConfig.fontFamilies()
        let system = try XCTUnwrap(TerminalSettings.textFont().familyName, "系统等宽字体取不到")
        XCTAssertEqual(families.first, system, "链的第一格是系统等宽")
        let members = NSFontManager.shared.availableMembers(ofFontFamily: system) ?? []
        XCTAssertTrue(members.contains { ($0[1] as? String) == "Medium" }, "系统等宽有 Medium 这一款：\(members.map { $0[1] })")
        let frame = try await render(production)
        let em = TerminalSettings.fontSize * 2
        XCTAssertLessThan(Double(frame.cellWidth), 0.75 * em, "格子宽应是等宽字体的宽度。\(describe(frame))")
    }
}
