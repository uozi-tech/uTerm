import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 「按行填满」在 iOS 的真 surface 上（规则与 Mac 用例见 `TerminalRowFillRuleTests` / `TerminalRowFillSurfaceTests`）：
/// 容器高度除不尽一行时，行数仍是自然行高下的那么多，格子被拉高、零头上下均分；键盘升降 / 转屏 / 分屏（都是容器尺寸
/// 变化）途中不逐帧换配置；字号跟着宽度变了重新算；影子终端的格子像素和 surface 一致。
@MainActor
final class TerminalRowFillMobileTests: MTerminalContainerTestCase {

    /// 等「停稳再提交」、行高调整（隔一轮主线程）、引擎报回来都落定：连续 0.3 s 不变。
    private func settleFill(_ bridge: GhosttyTerminalBridge) async {
        func snapshot() -> [Double] {
            let grid = bridge.session.surfaceGrid
            return [Double(grid?.columns ?? 0), Double(grid?.rows ?? 0), Double(grid?.cellHeightPixels ?? 0),
                    Double(grid?.heightPixels ?? 0), Double(bridge.shadow.cellPixels.height),
                    bridge.view.frame.minY, bridge.view.frame.height, Double(bridge.grid?.rows ?? 0)]
        }
        try? await Task.sleep(for: MTerminalContainerView.settleDelay * 2)
        var last = snapshot()
        var stableSince = ContinuousClock.now
        let deadline = stableSince + .seconds(5)
        while ContinuousClock.now < deadline, ContinuousClock.now - stableSince < .milliseconds(300) {
            try? await Task.sleep(for: .milliseconds(20))
            let now = snapshot()
            if now != last {
                last = now
                stableSince = ContinuousClock.now
            }
        }
    }

    private struct Fill: CustomStringConvertible {
        var viewHeight: Int
        var natural: Int
        var cell: Int
        var rows: Int
        var top: Int
        var bottom: Int
        var description: String { "H=\(viewHeight) h0=\(natural) h=\(cell) rows=\(rows) top=\(top) bottom=\(bottom)" }
    }

    /// 这一刻的填法（物理像素）：top / bottom = 容器里网格上下露出的空白。
    private func fill(_ bridge: GhosttyTerminalBridge, _ container: MTerminalContainerView) -> Fill? {
        guard let grid = bridge.session.surfaceGrid else { return nil }
        let scale = bridge.view.uTermScaleFactor
        let top = Int((Double(bridge.view.frame.minY) * scale).rounded())
        let cell = Int(grid.cellHeightPixels)
        let rows = Int(grid.rows)
        let containerPixels = Int((Double(container.bounds.height) * scale).rounded(.down))
        return Fill(viewHeight: Int(grid.heightPixels), natural: cell - bridge.view.uTermCellHeightAdjustment, cell: cell,
                    rows: rows, top: top, bottom: containerPixels - top - rows * cell)
    }

    private func assertFilled(_ fill: Fill?, file: StaticString = #filePath, line: UInt = #line) {
        guard let fill else { return XCTFail("读不到 surface 的尺寸", file: file, line: line) }
        XCTAssertGreaterThan(fill.rows, 0, "\(fill)", file: file, line: line)
        XCTAssertEqual(fill.rows, fill.viewHeight / fill.natural, "行数要和自然行高下一样：\(fill)", file: file, line: line)
        let plan = TerminalRowFill(viewHeight: fill.viewHeight, naturalCellHeight: fill.natural)
        XCTAssertEqual(fill.cell, plan.cellHeight, "格子高按规则拉：\(fill)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(fill.top, 0, "\(fill)", file: file, line: line)
        // 容器高换成像素时多出的不到 1 像素也算在底下，所以底边最多比顶边多 2。
        XCTAssertTrue((0...2).contains(fill.bottom - fill.top), "零头上下均分：\(fill)", file: file, line: line)
        XCTAssertLessThanOrEqual(fill.bottom * 2, fill.natural + 2, "每边不到半行：\(fill)", file: file, line: line)
        if plan.adjustment < TerminalRowFill.maxAdjustment(naturalCellHeight: fill.natural) {
            XCTAssertLessThanOrEqual(fill.bottom, fill.rows / 2 + 1, "每边 ≤ ⌈(rows − 1) ÷ 2⌉：\(fill)", file: file, line: line)
        }
    }

    /// 容器高（点）：surface 高 = h0 · k + rest 物理像素。
    private func height(rows k: Int, rest: Int, natural: Int, scale: Double) -> CGFloat {
        // 多给 0.25 像素，免得浮点把 floor(点 × 倍率) 算成少一个像素。
        CGFloat((Double(natural * k + rest) + 0.25) / scale)
    }

    /// 多组高度（键盘升起 / 收起、转屏、分屏都落到容器高度上）：正好整除、余量接近一行、余量刚过半行、只有两三行。
    func testWholeRowsFillTheContainerAtManyHeights() async throws {
        let (bridge, container) = try await hostedInWindow()
        await settleFill(bridge)
        guard let natural = fill(bridge, container)?.natural else { return XCTFail("读不到格子") }
        let scale = bridge.view.uTermScaleFactor
        for (k, rest) in [(20, 0), (20, natural - 2), (8, natural - 2), (24, natural / 2 + 1),
                          (3, natural - 2), (2, natural / 3), (12, 1)] {
            lay(container, CGSize(width: 400, height: height(rows: k, rest: rest, natural: natural, scale: scale)))
            await settleFill(bridge)
            let now = fill(bridge, container)
            XCTAssertEqual(now?.rows, k, "k=\(k) rest=\(rest)：\(String(describing: now))")
            assertFilled(now)
            XCTAssertEqual(bridge.grid?.rows, k, "报给远端的行数就是自然行高下的行数")
        }
    }

    /// 转屏（宽高对调）、分屏（变窄）：每次停稳后都填满，行数是自然行数。
    func testRotationAndSplitKeepFilling() async throws {
        let (bridge, container) = try await hostedInWindow()
        for size in [CGSize(width: 600, height: 380), CGSize(width: 195, height: 600), CGSize(width: 400, height: 311),
                     CGSize(width: 400, height: 600)] {
            lay(container, size)
            await settleFill(bridge)
            assertFilled(fill(bridge, container))
        }
    }

    /// 一串中间尺寸（键盘动画、拖分隔条）：不逐帧给 surface 换行高，远端只收到一次尺寸通知。
    func testResizingDoesNotSwapCellHeightPerFrame() async throws {
        let (bridge, container) = try await hostedInWindow()
        await settleFill(bridge)
        guard let natural = fill(bridge, container)?.natural else { return XCTFail("读不到格子") }
        let scale = bridge.view.uTermScaleFactor
        let before = await reported(bridge)
        let adjustments = bridge.link.rowFillAdjustments
        for step in 0..<10 {
            lay(container, CGSize(width: 400, height: height(rows: 16 + step % 3, rest: (step * 7) % natural,
                                                               natural: natural, scale: scale)))
            try? await Task.sleep(for: .milliseconds(30))
        }
        lay(container, CGSize(width: 400, height: height(rows: 9, rest: natural - 2, natural: natural, scale: scale)))
        await settleFill(bridge)

        XCTAssertLessThanOrEqual(bridge.link.rowFillAdjustments - adjustments, 1, "途中不该换行高")
        assertFilled(fill(bridge, container))
        let after = await reported(bridge)
        XCTAssertEqual(after.rows, 9)
        XCTAssertEqual(after.count, before.count + 1, "远端只收到一次尺寸通知")
    }

    /// 字号跟着宽度变（切分屏、转屏）：和尺寸一起提交，按新的自然行高重新算；远端只收到一次通知。
    func testFontSizeChangeRefits() async throws {
        let (bridge, container) = try await hostedInWindow()
        await settleFill(bridge)
        guard let natural = fill(bridge, container)?.natural else { return XCTFail("读不到格子") }
        let scale = bridge.view.uTermScaleFactor
        lay(container, CGSize(width: 400, height: height(rows: 14, rest: natural - 2, natural: natural, scale: scale)))
        await settleFill(bridge)
        assertFilled(fill(bridge, container))
        let before = await reported(bridge)

        container.setFontSize(14)
        await settleFill(bridge)
        let bigger = fill(bridge, container)
        XCTAssertGreaterThan(bigger?.natural ?? 0, natural, "用例前提：字变大了")
        assertFilled(bigger)
        let after = await reported(bridge)
        XCTAssertEqual(after.count, before.count + 1, "字号换了只通知一次")
    }

    /// 影子终端的格子像素跟 surface 一致（行列数不变、只调行高的那次也跟）。
    func testShadowCellMatchesSurface() async throws {
        let (bridge, container) = try await hostedInWindow()
        await settleFill(bridge)
        guard let natural = fill(bridge, container)?.natural else { return XCTFail("读不到格子") }
        let scale = bridge.view.uTermScaleFactor
        lay(container, CGSize(width: 400, height: height(rows: 9, rest: natural - 2, natural: natural, scale: scale)))
        await settleFill(bridge)
        guard let grid = bridge.session.surfaceGrid else { return XCTFail("没有 surface") }
        XCTAssertGreaterThan(Int(grid.cellHeightPixels), natural, "用例前提：这个高度要拉伸")
        XCTAssertEqual(bridge.shadow.cellPixels.height, grid.cellHeightPixels)
        XCTAssertEqual(bridge.shadow.cellPixels.width, grid.cellWidthPixels)
        XCTAssertEqual([bridge.shadow.size.cols, bridge.shadow.size.rows], [Int(grid.columns), Int(grid.rows)])
    }
}
