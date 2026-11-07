import SwiftTerm
import UIKit
import XCTest
@testable import uTermMobile

/// 按行缓存排版结果（SwiftTerm 补丁 #20）不能画出旧内容。
///
/// 做法：视图 A 经历一连串变化、每步之间都画一次，缓存里积满旧行；视图 B 是全新视图，喂同样的字节、只画一次。
/// 两张截图必须逐字节相同。光标最后都隐藏，免得闪烁相位不同。
/// `layer.render(in:)` 读的是图层现有的位图、不会重画；滚动视图的 bounds 原点是滚动位置，截图前要挪回原点，
/// 否则整张空白、比对假通过——所以每次比对都先断言快照和一个什么都没写的视图不同（按字节数判断不可靠：
/// 只有一行字的屏 PNG 也就几 KB）。
@MainActor
final class TerminalRowCacheTests: XCTestCase {
    private var window: UIWindow?
    private var history = ""

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
    }

    private func makeView() throws -> SwiftTerm.TerminalView {
        if window == nil {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
            window.isHidden = false
            self.window = window
        }
        let view = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600),
                                          font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        window?.addSubview(view)
        view.layoutIfNeeded()
        // 和 app 一样装实色配色（SwiftTerm 默认背景是 `.clear`）。
        let scheme = MTerminalColors.resolve(dark: true)
        TerminalAppearance.applyColors(to: view, scheme: scheme)
        view.backgroundColor = scheme.backgroundColor
        return view
    }

    /// 喂给 A 并记下来，最后原样喂给 B。
    private func feed(_ view: SwiftTerm.TerminalView, _ text: String) {
        history += text
        view.feed(text: text)
    }

    private func draw(_ view: SwiftTerm.TerminalView) {
        view.flushPendingDisplay()
        view.setNeedsDisplay(view.bounds)
        view.layer.displayIfNeeded()
    }

    private func snapshot(_ view: UIView) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            context.cgContext.translateBy(x: -view.bounds.minX, y: -view.bounds.minY)
            view.layer.render(in: context.cgContext)
        }.pngData() ?? Data()
    }

    /// 全新视图喂同样的字节，`configure` 在喂之前做与 A 相同的设置；两边停在同一个滚动位置比。
    private func assertMatchesFreshView(_ cached: SwiftTerm.TerminalView,
                                        configure: (SwiftTerm.TerminalView) -> Void = { _ in },
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        feed(cached, "\u{1B}[?25l")
        draw(cached)
        let fresh = try makeView()
        configure(fresh)
        fresh.feed(text: history)
        fresh.flushPendingDisplay()
        fresh.contentOffset = cached.contentOffset
        draw(fresh)

        let blank = try makeView()
        draw(blank)

        let expected = snapshot(fresh)
        XCTAssertNotEqual(expected, snapshot(blank), "快照是空白的，比对没有意义", file: file, line: line)
        XCTAssertEqual(snapshot(cached), expected, "缓存画出了旧内容", file: file, line: line)
        fresh.removeFromSuperview()
        blank.removeFromSuperview()
    }

    private static func coloredLines(_ range: Range<Int>, tag: String) -> String {
        range.map { "\u{1B}[3\($0 % 7 + 1)m\(tag) \($0)\u{1B}[0m \u{1B}[44m bg \u{1B}[0m 中文 🙂 ━━\r\n" }.joined()
    }

    func testSnapshotsTellDifferentContentApart() throws {
        let a = try makeView()
        a.feed(text: Self.coloredLines(0..<60, tag: "one"))
        draw(a)
        let b = try makeView()
        b.feed(text: Self.coloredLines(0..<60, tag: "two"))
        draw(b)
        XCTAssertGreaterThan(snapshot(a).count, 20_000)
        XCTAssertNotEqual(snapshot(a), snapshot(b))
    }

    func testInPlaceRewritesMatchAFreshView() throws {
        let view = try makeView()
        feed(view, Self.coloredLines(0..<80, tag: "line"))
        draw(view)
        let rows = view.getTerminal().rows
        for frame in 0..<12 {
            let glyph = ["✢", "✳", "✶", "✻"][frame % 4]
            feed(view, "\u{1B}[?2026h\u{1B}[\(rows - 3);1H\u{1B}[2K\u{1B}[38;2;215;119;87m\(glyph) Thinking \(frame)"
                + "\u{1B}[0m\u{1B}[\(frame % rows + 1);5H\u{1B}[1;45mX\(frame)\u{1B}[0m\u{1B}[?2026l")
            draw(view)
        }
        try assertMatchesFreshView(view)
    }

    func testScrollingAndRecycledScrollbackMatchAFreshView() throws {
        let view = try makeView()
        feed(view, Self.coloredLines(0..<200, tag: "early"))
        draw(view)
        // 往回翻看几处，把这些行放进缓存。
        for offset in stride(from: view.contentOffset.y, through: 0, by: -333) {
            view.contentOffset.y = offset
            draw(view)
        }
        // 继续输出到回滚缓冲装满、开始回收旧行对象（默认回滚 500 行）。
        feed(view, Self.coloredLines(0..<900, tag: "late"))
        draw(view)
        view.contentOffset.y = view.contentOffset.y / 2
        draw(view)
        try assertMatchesFreshView(view)
    }

    func testPaletteChangeMatchesAFreshView() throws {
        let view = try makeView()
        feed(view, Self.coloredLines(0..<80, tag: "line"))
        draw(view)
        let palette = (0..<16).map { SwiftTerm.Color(red: UInt16($0 * 4000), green: 30000, blue: UInt16(65535 - $0 * 4000)) }
        view.installColors(palette)
        draw(view)
        try assertMatchesFreshView(view) { $0.installColors(palette) }
    }

    func testAlternateScreenRoundTripMatchesAFreshView() throws {
        let view = try makeView()
        feed(view, Self.coloredLines(0..<80, tag: "main"))
        draw(view)
        feed(view, "\u{1B}[?1049h\u{1B}[H\u{1B}[2J" + Self.coloredLines(0..<20, tag: "vim"))
        draw(view)
        feed(view, "\u{1B}[?1049l")
        draw(view)
        try assertMatchesFreshView(view)
    }

    /// 同一个行号换成了另一个行对象（进出备用屏），两个对象各自的修改计数恰好相等。
    /// 计数是每行自己从 0 数起的小整数，两行各写了同样多的字就会相等；只比计数会把主屏的旧行画到备用屏上，
    /// 缓存键必须同时认行对象。这里把两行的计数精确对齐后再比。
    func testSameRowOnAnotherLineObjectMatchesAFreshView() throws {
        let view = try makeView()
        let terminal = view.getTerminal()
        // 主屏第 0 行反复改写，把计数抬到备用屏那行追得上的位置之上。
        feed(view, "\u{1B}[1;1Hmain-screen-text" + String(repeating: "\u{1B}[1;1Hm", count: 200))
        draw(view)
        let mainLine = try XCTUnwrap(terminal.getLine(row: 0))
        let mainGeneration = mainLine.generation

        feed(view, "\u{1B}[?1047h\u{1B}[1;1Halt--screen-text")
        let altLine = try XCTUnwrap(terminal.getLine(row: 0))
        XCTAssertFalse(altLine === mainLine)
        XCTAssertLessThan(altLine.generation, mainGeneration)
        // 原地重写同一个字，内容不变、计数逐次 +1，直到和主屏那行相等。
        while altLine.generation < mainGeneration {
            feed(view, "\u{1B}[1;1Ha")
        }
        XCTAssertEqual(altLine.generation, mainGeneration)
        draw(view)
        try assertMatchesFreshView(view)
    }

    /// 选区画在行里（选中格的前景、背景色），选上、取消都要重排受影响的行。
    func testSelectionChangesMatchAFreshView() throws {
        let content = Self.coloredLines(0..<80, tag: "line") + "\u{1B}[?25l"
        let view = try makeView()
        view.feed(text: content)
        draw(view)

        func reference(selected: Bool) throws -> Data {
            let fresh = try makeView()
            fresh.feed(text: content)
            fresh.flushPendingDisplay()
            if selected { fresh.selectAll() }
            fresh.contentOffset = view.contentOffset
            draw(fresh)
            defer { fresh.removeFromSuperview() }
            return snapshot(fresh)
        }

        view.selectAll()
        draw(view)
        let selected = try reference(selected: true)
        XCTAssertNotEqual(selected, try reference(selected: false), "全选后应该能看出选区")
        XCTAssertEqual(snapshot(view), selected, "选上之后缓存还画着没选的样子")

        view.selectNone()
        draw(view)
        XCTAssertEqual(snapshot(view), try reference(selected: false), "取消选区后缓存还画着选中色")
    }
}
