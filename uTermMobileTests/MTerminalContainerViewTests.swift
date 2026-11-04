import SwiftTerm
import UIKit
import XCTest
@testable import uTermMobile

/// 终端尺寸停稳才提交：中途的尺寸不碰缓冲区，提交时才通知程序。
@MainActor
final class MTerminalContainerViewTests: XCTestCase {
    private final class Recorder: TerminalViewDelegate {
        var sizes: [[Int]] = []
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { sizes.append([newCols, newRows]) }
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {}
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    }

    private let mounted = CGSize(width: 400, height: 600)
    private let recorder = Recorder()

    private func makeTerminal() -> MTerminalView {
        let view = MTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        view.terminalDelegate = recorder
        return view
    }

    private func hosted() async -> (MTerminalView, MTerminalContainerView) {
        let view = makeTerminal()
        let container = MTerminalContainerView(terminalView: view, fontSize: 11)
        lay(container, mounted)
        await settle()
        recorder.sizes = []
        return (view, container)
    }

    private func lay(_ container: MTerminalContainerView, _ size: CGSize) {
        container.frame = CGRect(origin: .zero, size: size)
        container.layoutIfNeeded()
    }

    private func settle() async {
        try? await Task.sleep(for: MTerminalContainerView.settleDelay * 3)
    }

    private func grid(_ view: SwiftTerm.TerminalView) -> [Int] {
        [view.getTerminal().cols, view.getTerminal().rows]
    }

    func testFirstLayoutCommitsImmediately() {
        let view = makeTerminal()
        let container = MTerminalContainerView(terminalView: view, fontSize: 11)

        lay(container, mounted)

        XCTAssertEqual(view.frame.size, mounted)
    }

    /// 键盘升起又收起：缓冲区不能被碰，否则程序不知情、屏幕一直错位。
    func testRoundTripLeavesBufferUntouched() async {
        let (view, container) = await hosted()
        let terminal = view.getTerminal()
        let rows = (1...terminal.rows).map { "\u{1b}[\($0);1Hrow \($0)" }.joined()
        view.feed(text: "\u{1b}[?1049h" + rows)
        let before = terminal.snapshotFingerprint(historyLines: 100)

        lay(container, CGSize(width: 400, height: 300))
        lay(container, mounted)
        await settle()

        XCTAssertEqual(terminal.snapshotFingerprint(historyLines: 100).differences(from: before), [:])
        XCTAssertEqual(recorder.sizes, [])
    }

    func testResizeCommitsOnceAfterSettling() async {
        let (view, container) = await hosted()
        let before = grid(view)

        for height in stride(from: 560, through: 300, by: -40) {
            lay(container, CGSize(width: 400, height: CGFloat(height)))
            XCTAssertEqual(grid(view), before, "停稳之前不能重排")
        }
        await settle()

        XCTAssertLessThan(grid(view)[1], before[1])
        XCTAssertEqual(recorder.sizes, [grid(view)])
    }

    /// 键盘升起的等待期间，终端底部（提示符和光标）要留在屏上。
    func testHeldTerminalKeepsBottomVisibleWhenTallerThanContainer() async {
        let (view, container) = await hosted()

        lay(container, CGSize(width: 400, height: 300))

        XCTAssertEqual(view.frame.height, mounted.height)
        XCTAssertEqual(view.frame.maxY, 300)
    }

    /// 字号和宽度一起变（切分屏）：只重排一次，程序也只收到一次通知。
    func testFontAndWidthCommitTogether() async {
        let (view, container) = await hosted()

        lay(container, CGSize(width: 200, height: 600))
        container.setFontSize(9)
        XCTAssertEqual(view.font.pointSize, 11, accuracy: 0.01, "停稳之前不能换字号")
        await settle()

        XCTAssertEqual(view.font.pointSize, 9, accuracy: 0.01)
        XCTAssertEqual(view.frame.size.width, 200)
        XCTAssertEqual(recorder.sizes, [grid(view)])
    }

    func testCollapsedContainerKeepsGrid() async {
        let (view, container) = await hosted()
        let before = grid(view)

        lay(container, .zero)
        await settle()

        XCTAssertEqual(grid(view), before)
        XCTAssertEqual(recorder.sizes, [])
    }

    /// 外壳切换时新容器接走同一个终端，旧容器不再摆放它。
    func testStaleContainerDoesNotResizeAdoptedTerminal() async {
        let (view, stale) = await hosted()
        let live = MTerminalContainerView(terminalView: view, fontSize: 11)
        lay(live, mounted)
        let before = grid(view)

        lay(stale, CGSize(width: 200, height: 300))
        await settle()

        XCTAssertEqual(grid(view), before)
    }
}
