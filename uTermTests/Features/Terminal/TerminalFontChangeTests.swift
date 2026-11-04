import AppKit
import SwiftTerm
import XCTest

/// vendored SwiftTerm 补丁 #14：换字号不能重置终端状态。
///
/// 程序不知道字号变了，也不会把模式重新设一遍。上游换字号时走 `softReset()`，于是光标隐藏、
/// 方向键模式、当前颜色这些都被清掉，vim 里的方向键就此发错序列。
@MainActor
final class TerminalFontChangeTests: XCTestCase {
    /// vim、Claude Code 这类全屏程序会设的状态。
    private static let programState = [
        "\u{1b}[?1049h",   // 备用屏
        "\u{1b}[?1h",      // 方向键发应用模式序列
        "\u{1b}[?25l",     // 隐藏光标
        "\u{1b}[?7l",      // 关自动折行
        "\u{1b}[4h",       // 插入模式
        "\u{1b}[?6h",      // 原点模式
        "\u{1b}[5;10r",    // 滚动区域
        "\u{1b}[31m",      // 当前颜色
    ].joined()

    private func terminalWithProgramState() -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.feed(text: Self.programState)
        return view
    }

    /// 字号变了、行列数也变了：尺寸相关的状态归重排管，模式和颜色不能动。
    func testFontChangeThatResizesKeepsModesAndPen() {
        let view = terminalWithProgramState()
        let terminal = view.getTerminal()
        let before = terminal.snapshotFingerprint(historyLines: 0)
        let cols = terminal.cols

        view.font = .monospacedSystemFont(ofSize: 18, weight: .regular)

        XCTAssertLessThan(terminal.cols, cols, "前提：这次换字号要改变行列数")
        let changed = terminal.snapshotFingerprint(historyLines: 0).differences(from: before)
        XCTAssertNil(changed["modes"], "\(changed)")
        XCTAssertNil(changed["pen"], "\(changed)")
        XCTAssertTrue(terminal.applicationCursor)
    }

    /// 行列数没变时，整个终端状态都不该变（含滚动区域）。
    func testFontChangeThatKeepsGridChangesNothing() {
        let view = terminalWithProgramState()
        let terminal = view.getTerminal()
        let before = terminal.snapshotFingerprint(historyLines: 0)

        view.font = view.font

        XCTAssertEqual(terminal.snapshotFingerprint(historyLines: 0).differences(from: before), [:])
    }

    /// 行距走同一条路。
    func testLineSpacingChangeKeepsModesAndPen() {
        let view = terminalWithProgramState()
        let terminal = view.getTerminal()
        let before = terminal.snapshotFingerprint(historyLines: 0)

        view.lineSpacing = 1.4

        let changed = terminal.snapshotFingerprint(historyLines: 0).differences(from: before)
        XCTAssertNil(changed["modes"], "\(changed)")
        XCTAssertNil(changed["pen"], "\(changed)")
    }

    /// 尺寸通知不能跟着丢：程序靠它收到 SIGWINCH。
    func testFontChangeStillReportsNewSize() {
        final class Recorder: TerminalViewDelegate {
            var sizes: [[Int]] = []
            func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { sizes.append([newCols, newRows]) }
            func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
            func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
            func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {}
            func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
            func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
            func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
        }
        let view = terminalWithProgramState()
        let recorder = Recorder()
        view.terminalDelegate = recorder

        view.font = .monospacedSystemFont(ofSize: 18, weight: .regular)

        let terminal = view.getTerminal()
        XCTAssertEqual(recorder.sizes.last, [terminal.cols, terminal.rows])
    }
}
