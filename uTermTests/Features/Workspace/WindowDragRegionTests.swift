import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 读 AppKit 真正交给 WindowServer 的拖动区，确认 `TitlebarDragRegion` 摘掉了标题栏带。
///
/// 铺满窗口的底色是这条用例的关键条件：真实窗口都铺满了可命中内容，会触发 SwiftUI 的
/// 「防拖动区覆盖整窗就作废」。对照组先证明这个条件确实让标题栏带可拖，也证明读数有效。
@MainActor
final class WindowDragRegionTests: XCTestCase {
    private let size = NSSize(width: 800, height: 400)

    func testFullWindowContentLeavesTitlebarBandDraggableWithoutModifier() throws {
        let rows = try dragRegionRows(for: Color.black)
        XCTAssertTrue(contains(rows, x: size.width / 2, yFromTop: 14))
    }

    func testModifierRemovesTitlebarBandFromDragRegion() throws {
        // 先确认同样的读法能读到拖动区，否则下面的「不包含」没有意义。
        _ = try dragRegionRows(for: Color.black)

        let rows = try dragRegionRows(for: Color.black.modifier(TitlebarDragRegion()))
        for x in [CGFloat(100), size.width / 2, size.width - 100] {
            XCTAssertFalse(contains(rows, x: x, yFromTop: 14), "x=\(x)")
        }
    }

    /// `_lastDragRegionData` 的格式：Int32 数组，前两项是头，之后每行
    /// `[y, 本行元素总数, x0, x1, x2, x3...]`，y 从窗口底部算起。
    private func dragRegionRows(for content: some View) throws -> [(y: Int32, spans: [Int32])] {
        let selector = NSSelectorFromString("_lastDragRegionData")
        let window = ProbeWindow.make(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        )
        guard window.responds(to: selector) else {
            throw XCTSkip("这版 AppKit 没有 _lastDragRegionData")
        }
        defer { window.orderOut(nil) }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: content)

        // 区域在显示周期里异步算出，等它稳定下来。
        var bytes = Data()
        for _ in 0..<40 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            window.displayIfNeeded()
            bytes = window.perform(selector)?.takeUnretainedValue() as? Data ?? Data()
        }

        let values = bytes.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        var rows: [(y: Int32, spans: [Int32])] = []
        var index = 2
        while index + 1 < values.count {
            let count = Int(values[index + 1])
            guard count >= 2, index + count <= values.count else { break }
            rows.append((values[index], Array(values[(index + 2)..<(index + count)])))
            index += count
        }
        return rows
    }

    private func contains(
        _ rows: [(y: Int32, spans: [Int32])],
        x: CGFloat,
        yFromTop: CGFloat
    ) -> Bool {
        let y = Int32(size.height - yFromTop)
        guard let row = rows.last(where: { $0.y <= y }) else { return false }
        return stride(from: 0, to: row.spans.count - 1, by: 2).contains { index in
            CGFloat(row.spans[index]) <= x && x < CGFloat(row.spans[index + 1])
        }
    }
}
