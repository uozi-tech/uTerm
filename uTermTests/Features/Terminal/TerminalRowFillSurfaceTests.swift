import AppKit
import GhosttyTerminal
import XCTest
@testable import uTerm

/// 「按行填满」在 Mac 的真 surface 上（规则本身见 `TerminalRowFillRuleTests`）：窗格高度除不尽一行时，行数仍是自然行高下的
/// 那么多，格子被拉高、零头上下均分，看不到「底部一条空白」；拖动途中不逐帧换配置；字号、日夜换了重新算；
/// 影子终端的格子像素和 surface 一致。读的是引擎自己报的尺寸（`surfaceGrid`）和视图在窗格里的位置。
@MainActor
final class TerminalRowFillSurfaceTests: XCTestCase {
    private var sessions: [TerminalSession] = []
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        sessions.forEach { $0.dispose() }
        sessions = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
        try await super.tearDown()
    }

    // MARK: 夹具

    private func waitUntil(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func lay(_ container: GhosttyContainerView, _ size: NSSize) {
        container.setFrameSize(size)
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
    }

    /// 等「停稳再提交」（80 ms）、行高调整（隔一轮主线程）、引擎报回来都落定：surface 的尺寸、格子、视图位置、影子的
    /// 格子像素连续 0.3 s 不变。
    private func settle(_ session: TerminalSession) async {
        func snapshot() -> [Double] {
            let grid = session.surfaceIO.surfaceGrid
            let cell = session.shadow.cellPixels
            let frame = session.ghostty.view.frame
            return [Double(grid?.columns ?? 0), Double(grid?.rows ?? 0), Double(grid?.cellHeightPixels ?? 0),
                    Double(grid?.heightPixels ?? 0), Double(cell.height), frame.minY, frame.height,
                    Double(session.ghostty.grid?.rows ?? 0)]
        }
        var last = snapshot()
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(5)
        while Date().timeIntervalSince(stableSince) < 0.3, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            let now = snapshot()
            if now != last { last = now; stableSince = Date() }
        }
    }

    private func hosted(height: CGFloat = 606) async -> (TerminalSession, MockBackend, GhosttyContainerView, NSWindow) {
        let session = TerminalSession()
        session.attentionSink = { _ in }
        sessions.append(session)
        let backend = MockBackend()
        await session.connect(using: backend)
        let rect = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let window = ProbeWindow.make(contentRect: rect, contentView: NSView(frame: rect), placement: .transparentOnScreen)
        windows.append(window)
        let container = GhosttyContainerView(surface: session.ghostty.view)
        window.contentView?.addSubview(container)
        lay(container, NSSize(width: 816, height: height))
        let live = await waitUntil(10) { session.ghostty.isLive && session.ghostty.grid != nil }
        XCTAssertTrue(live, "Ghostty surface 没就绪")
        await settle(session)
        return (session, backend, container, window)
    }

    /// 这一刻的填法，全部物理像素：H = surface 高（= 窗格可用高），h0 = 自然格子高，top / bottom = 网格上下露出的空白
    /// （窗格可用区里，网格以外的部分）。
    private struct Fill: CustomStringConvertible {
        var viewHeight: Int
        var natural: Int
        var cell: Int
        var rows: Int
        var top: Int
        var bottom: Int
        var description: String { "H=\(viewHeight) h0=\(natural) h=\(cell) rows=\(rows) top=\(top) bottom=\(bottom)" }
    }

    private func fill(_ session: TerminalSession, _ container: GhosttyContainerView) -> Fill? {
        let view = session.ghostty.view
        guard let grid = session.surfaceIO.surfaceGrid, let window = container.window else { return nil }
        let scale = window.backingScaleFactor
        let i = GhosttyContainerView.insets
        let available = NSRect(x: i.left, y: i.bottom, width: container.bounds.width - i.left - i.right,
                               height: container.bounds.height - i.top - i.bottom)
        // 容器不翻转：顶边是 maxY。
        let top = Int(((available.maxY - view.frame.maxY) * scale).rounded())
        let viewHeight = Int(grid.heightPixels)
        let cell = Int(grid.cellHeightPixels)
        let rows = Int(grid.rows)
        let availablePixels = Int((available.height * scale).rounded(.down))
        return Fill(viewHeight: viewHeight, natural: cell - view.uTermCellHeightAdjustment, cell: cell, rows: rows,
                    top: top, bottom: availablePixels - top - rows * cell)
    }

    /// 整数行填满：行数是自然行高下的行数、格子按规则拉高，网格上下的空白最多差 1 像素、每边小于半行；
    /// 不封顶时每边不超过 ⌈(rows − 1) ÷ 2⌉。
    private func assertFilled(_ fill: Fill?, file: StaticString = #filePath, line: UInt = #line) {
        guard let fill else { return XCTFail("读不到 surface 的尺寸", file: file, line: line) }
        XCTAssertGreaterThan(fill.rows, 0, "\(fill)", file: file, line: line)
        XCTAssertEqual(fill.rows, fill.viewHeight / fill.natural, "行数要和自然行高下一样：\(fill)", file: file, line: line)
        let plan = TerminalRowFill(viewHeight: fill.viewHeight, naturalCellHeight: fill.natural)
        XCTAssertEqual(fill.cell, plan.cellHeight, "格子高按规则拉：\(fill)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(fill.top, 0, "\(fill)", file: file, line: line)
        XCTAssertTrue(fill.bottom - fill.top == 0 || fill.bottom - fill.top == 1, "零头上下均分：\(fill)",
                      file: file, line: line)
        XCTAssertLessThanOrEqual(fill.bottom * 2, fill.natural, "每边不到半行：\(fill)", file: file, line: line)
        if plan.adjustment < TerminalRowFill.maxAdjustment(naturalCellHeight: fill.natural) {
            XCTAssertLessThanOrEqual(fill.bottom, fill.rows / 2, "每边 ≤ ⌈(rows − 1) ÷ 2⌉：\(fill)", file: file, line: line)
        }
    }

    /// 窗格可用区的物理像素高 = h0 · k + rest 时，容器该多高（点）。
    private func containerHeight(rows k: Int, rest: Int, natural: Int, window: NSWindow) -> CGFloat {
        let scale = window.backingScaleFactor
        return CGFloat(natural * k + rest) / scale + GhosttyContainerView.insets.top + GhosttyContainerView.insets.bottom
    }

    // MARK: 用例

    /// 多组高度：正好整除、余量接近一行（行少时摊进行距、行多时只能均分）、余量刚过半行、只有两三行。
    func testWholeRowsFillThePaneAtManyHeights() async {
        let (session, backend, container, window) = await hosted()
        guard let natural = fill(session, container)?.natural else { return XCTFail("读不到格子") }
        let scale = Int(window.backingScaleFactor)
        for (k, rest) in [(20, 0), (20, natural - scale), (8, natural - scale), (30, natural / 2 + scale),
                          (3, natural - scale), (2, natural / 3), (12, scale)] {
            lay(container, NSSize(width: 816, height: containerHeight(rows: k, rest: rest, natural: natural, window: window)))
            await settle(session)
            let now = fill(session, container)
            XCTAssertEqual(now?.rows, k, "k=\(k) rest=\(rest)：\(String(describing: now))")
            assertFilled(now)
            let sent = await backend.resizes.last
            XCTAssertEqual(sent.map { Int($0.rows) }, k, "PTY 收到的行数就是自然行高下的行数")
        }
    }

    /// 拖动（一串中间尺寸，每个都在停稳之前就换掉）：不逐帧给 surface 换行高，停稳后最多换一次；PTY 只收到最终网格一次。
    func testDraggingDoesNotSwapCellHeightPerFrame() async {
        let (session, backend, container, window) = await hosted()
        guard let natural = fill(session, container)?.natural else { return XCTFail("读不到格子") }
        let before = session.link.rowFillAdjustments
        let sentBefore = await backend.resizes.count
        for step in 0..<12 {
            let rest = (step * 5) % natural
            lay(container, NSSize(width: 816, height: containerHeight(rows: 14 + step % 3, rest: rest,
                                                                       natural: natural, window: window)))
            try? await Task.sleep(for: .milliseconds(30))
        }
        lay(container, NSSize(width: 816, height: containerHeight(rows: 9, rest: natural - 2, natural: natural, window: window)))
        await settle(session)

        XCTAssertLessThanOrEqual(session.link.rowFillAdjustments - before, 1, "拖动途中不该换行高")
        assertFilled(fill(session, container))
        let sent = await backend.resizes.dropFirst(sentBefore).map { Int($0.rows) }
        XCTAssertEqual(sent, [9], "PTY 只收到停下来时的网格：\(sent)")
    }

    /// 字号变了（⌘= 走的同一个绑定）：按新的自然行高重新算，行数是新字号下的自然行数。
    func testFontSizeChangeRefits() async {
        let (session, _, container, window) = await hosted()
        guard let natural = fill(session, container)?.natural else { return XCTFail("读不到格子") }
        lay(container, NSSize(width: 816, height: containerHeight(rows: 10, rest: natural - 2, natural: natural, window: window)))
        await settle(session)
        assertFilled(fill(session, container))

        XCTAssertTrue(session.ghostty.view.performBindingAction("increase_font_size:3"))
        await settle(session)
        let bigger = fill(session, container)
        XCTAssertGreaterThan(bigger?.natural ?? 0, natural, "用例前提：字变大了")
        assertFilled(bigger)
        XCTAssertTrue(session.ghostty.view.performBindingAction("reset_font_size"))
        await settle(session)
        assertFilled(fill(session, container))
    }

    /// app 的配置整份推下来（切日夜）会把这个 surface 的行高调整清掉：要重新调回来。
    func testAppearanceChangeKeepsTheFill() async {
        let (session, _, container, window) = await hosted()
        guard let natural = fill(session, container)?.natural else { return XCTFail("读不到格子") }
        lay(container, NSSize(width: 816, height: containerHeight(rows: 6, rest: natural - 2, natural: natural, window: window)))
        await settle(session)
        let filled = fill(session, container)
        assertFilled(filled)
        XCTAssertGreaterThan(filled.map { $0.cell - $0.natural } ?? 0, 0, "用例前提：这个高度要拉伸")

        let controller = GhosttyTerminalConfig.controller
        let original = controller.effectiveColorScheme
        controller.setColorScheme(original == .dark ? .light : .dark)
        await settle(session)
        assertFilled(fill(session, container))
        controller.setColorScheme(original)
        await settle(session)
        assertFilled(fill(session, container))
    }

    /// 影子终端的格子像素跟 surface 一致（它在 IO 线程的 resize 回调里跟，行列数不变、只调行高的那次也要跟）。
    func testShadowCellMatchesSurface() async {
        let (session, _, container, window) = await hosted()
        guard let natural = fill(session, container)?.natural else { return XCTFail("读不到格子") }
        lay(container, NSSize(width: 816, height: containerHeight(rows: 7, rest: natural - 2, natural: natural, window: window)))
        await settle(session)
        guard let grid = session.surfaceIO.surfaceGrid else { return XCTFail("没有 surface") }
        XCTAssertGreaterThan(Int(grid.cellHeightPixels), natural, "用例前提：这个高度要拉伸")
        XCTAssertEqual(session.shadow.cellPixels.height, grid.cellHeightPixels)
        XCTAssertEqual(session.shadow.cellPixels.width, grid.cellWidthPixels)
        XCTAssertEqual([session.shadow.size.cols, session.shadow.size.rows], [Int(grid.columns), Int(grid.rows)])
    }

    /// 远控钉尺寸（被控端按主控端的行列数钉住）：视图就是「行列数 × 格子」，没有零头，不挪也不调。
    func testPinnedGridIsNotShifted() async {
        let (session, _, container, window) = await hosted()
        guard let natural = fill(session, container)?.natural else { return XCTFail("读不到格子") }
        lay(container, NSSize(width: 816, height: containerHeight(rows: 12, rest: natural - 2, natural: natural, window: window)))
        await settle(session)
        session.ghostty.pinGrid(cols: 50, rows: 8)
        container.layoutSubtreeIfNeeded()
        await settle(session)
        XCTAssertEqual(session.link.rowFillOffset, 0)
        XCTAssertEqual(session.surfaceIO.surfaceGrid.map { [Int($0.columns), Int($0.rows)] }, [50, 8])
        session.ghostty.unpinGrid()
        await settle(session)
        assertFilled(fill(session, container))
    }
}
