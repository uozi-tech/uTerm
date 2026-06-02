import XCTest
import SwiftTerm
@testable import uTerm

@MainActor
final class CopyableTerminalViewTests: XCTestCase {

    /// SwiftTerm 的 NSScroller 默认常驻可见，即便没有可滚动历史也显示一个
    /// 静态禁用的 knob。CopyableTerminalView 把它改成「仅在有 scrollback 可滚
    /// 时出现」：镜像 `scroller.isEnabled`（SwiftTerm 在 updateScroller() 里设为
    /// `canScroll`）到 `alphaValue`，且刻意不动 `isHidden` —— 避免改变
    /// `reservedScrollerWidth` 引发终端列数 reflow。
    func testScrollerAlphaMirrorsCanScrollState() {
        let terminalView = CopyableTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        // 进入窗口层级以触发 viewDidMoveToWindow → 安装 KVO 观察。
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

        // 无可滚动历史（canScroll=false → isEnabled=false）应淡出。
        scroller.isEnabled = false
        XCTAssertEqual(scroller.alphaValue, 0,
                       "scroller 应在没有可滚动历史时淡出")

        // 有可滚动历史（isEnabled=true）应出现。
        scroller.isEnabled = true
        XCTAssertEqual(scroller.alphaValue, 1,
                       "scroller 应在有 scrollback 可滚时出现")

        // 回到不可滚动应再次淡出。
        scroller.isEnabled = false
        XCTAssertEqual(scroller.alphaValue, 0,
                       "scrollback 清空后 scroller 应再次淡出")
    }
}
