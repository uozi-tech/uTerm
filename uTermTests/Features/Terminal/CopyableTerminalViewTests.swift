import XCTest
import AppKit
import Carbon.HIToolbox
import SwiftTerm
@testable import uTerm

@MainActor
final class CopyableTerminalViewTests: XCTestCase {

    /// SwiftTerm 把它的 NSScroller 当作子视图常驻挂在右边缘，从不 `isHidden`，
    /// 默认 alpha=1 —— 即便没有可滚动历史也显示一个静态 knob。
    ///
    /// CopyableTerminalView 现在的契约（见 2142cf7「滚动条改为仅滚动时浮现，
    /// 根除常驻 knob」）：`installManagedScrollerIfNeeded()` 在 viewDidMoveToWindow
    /// 时把它配成 **overlay 细条、静默时 alpha=0 全隐**，可见性与 `isEnabled`
    /// （即 SwiftTerm 的 `canScroll`）**解耦** —— 只有用户实际滚动（`.scrollWheel`
    /// 命中本 pane 且 isEnabled）才经 handleScrollActivity() 淡入，停手约 1s 淡出。
    ///
    /// 注意：早期版本（ca253bb）曾用 `scroller.observe(\.isEnabled)` KVO 镜像
    /// `isEnabled → alphaValue`（有历史就常驻显示），但那正是被 2142cf7 当作
    /// 「常驻滚动条」bug 移除的行为。本测试断言的是移除之后的契约：**变为
    /// isEnabled 不应让 scroller 出现**。
    ///
    /// 这里只覆盖可同步、确定性验证的安装期不变量；滚轮驱动的淡入淡出走
    /// `NSEvent` 本地监听 + `animator()` 动画 + `perform(_:afterDelay:)`，属交互
    /// 行为，留给手动 / UI 测试，不在此同步单测内驱动。
    func testManagedScrollerHiddenByDefaultAndDecoupledFromEnabledState() {
        let terminalView = CopyableTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        // 进入窗口层级以触发 viewDidMoveToWindow → installManagedScrollerIfNeeded()。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView?.addSubview(terminalView)

        guard let scroller = terminalView.subviews
            .compactMap({ $0 as? NSScroller }).first else {
            return XCTFail("expected SwiftTerm to install an NSScroller subview")
        }

        // 安装期不变量：静默时完全隐藏 + overlay 细条样式。
        XCTAssertEqual(scroller.alphaValue, 0,
                       "scroller 安装后应默认隐藏（alpha 0）—— 仅滚动时浮现")
        XCTAssertEqual(scroller.scrollerStyle, .overlay,
                       "managed scroller 应配置为 overlay 样式")
        XCTAssertEqual(scroller.knobStyle, .light,
                       "managed scroller 应使用 light knob（暗终端用浅色）")

        // 关键回归护栏：可见性已与 isEnabled / canScroll 解耦。
        // 旧实现会在此处把 alpha 镜像到 1；现在「有历史可滚」不再等于「显示」。
        scroller.isEnabled = true
        XCTAssertEqual(scroller.alphaValue, 0,
                       "变为 isEnabled（有可滚历史）不应让 scroller 出现 —— 仅滚动时浮现")

        // 失去可滚历史同样不改变可见性（始终保持隐藏）。
        scroller.isEnabled = false
        XCTAssertEqual(scroller.alphaValue, 0,
                       "失去可滚历史时 scroller 仍应保持隐藏")
    }

    // MARK: ⌃↩

    func testControlReturnSendsCarriageReturnInsteadOfOpeningContextMenu() {
        let harness = FocusedTerminal()

        XCTAssertTrue(harness.view.performKeyEquivalent(with: returnKey(flags: .control)))

        XCTAssertEqual(harness.sent, [13])
    }

    func testControlShiftReturnAndControlKeypadEnterAlsoStayInTerminal() {
        let harness = FocusedTerminal()

        XCTAssertTrue(harness.view.performKeyEquivalent(with: returnKey(flags: [.control, .shift])))
        XCTAssertTrue(harness.view.performKeyEquivalent(
            with: returnKey(flags: .control, keyCode: UInt16(kVK_ANSI_KeypadEnter))))

        XCTAssertEqual(harness.sent, [13, 13])
    }

    func testControlReturnUsesModifiedSequenceUnderKittyKeyboardProtocol() {
        let harness = FocusedTerminal()
        harness.view.feed(text: "\u{1b}[>1u")

        XCTAssertTrue(harness.view.performKeyEquivalent(with: returnKey(flags: .control)))

        XCTAssertEqual(harness.sent, Array("\u{1b}[13;5u".utf8))
    }

    /// key equivalent 会发给窗口里的每个视图，分屏时不能让两个终端都收到回车。
    func testControlReturnIgnoredWhenTerminalIsNotFirstResponder() {
        let harness = FocusedTerminal()
        harness.window.makeFirstResponder(nil)

        XCTAssertFalse(harness.view.performKeyEquivalent(with: returnKey(flags: .control)))

        XCTAssertEqual(harness.sent, [])
    }

    func testOtherReturnCombinationsStayOutOfKeyEquivalentPath() {
        let harness = FocusedTerminal()

        XCTAssertFalse(harness.view.performKeyEquivalent(with: returnKey(flags: [])))
        XCTAssertFalse(harness.view.performKeyEquivalent(with: returnKey(flags: .command)))
        XCTAssertFalse(harness.view.performKeyEquivalent(with: returnKey(flags: [.command, .control])))

        XCTAssertEqual(harness.sent, [])
    }

    private func returnKey(
        flags: NSEvent.ModifierFlags,
        keyCode: UInt16 = UInt16(kVK_Return)
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: keyCode)!
    }
}

/// 挂在窗口里、已拿到焦点的终端，并记录它发给后端的字节。
@MainActor
private final class FocusedTerminal: @preconcurrency TerminalViewDelegate {
    let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled],
        backing: .buffered,
        defer: true)
    private(set) var sent: [UInt8] = []

    init() {
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.terminalDelegate = self
        window.makeFirstResponder(view)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sent += data
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
