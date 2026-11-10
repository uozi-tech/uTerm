// 【迁移中，暂未编译】这份用例还依赖 SwiftTerm 或已经删掉的 SwiftTerm 时代类型，等改写到 Ghostty + 影子终端
// （`ShadowTerminal`）上的同一条行为。改写完把这一对 `#if UTERM_LEGACY_SWIFTTERM_TESTS` / `#endif` 去掉。
// 清单与进度见 docs/ghostty-eval/migration-log.md「测试改写」。
#if UTERM_LEGACY_SWIFTTERM_TESTS
import XCTest
import AppKit
import SwiftTerm
@testable import uTerm

@MainActor
final class TerminalThemeTests: XCTestCase {

    /// uTerm 是交互式终端，光标必须可见。早先从 uService 移植过来的
    /// `hideInputCursor` 把 caretColor 抹成 `.clear`，导致输入时看不到光标。
    /// 现在 `apply(...)` 必须保留 SwiftTerm 的默认光标（非清空色）。
    func testApplyKeepsCaretVisible() {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        TerminalTheme.apply(to: view, settings: .read(), dark: true)
        XCTAssertNotEqual(view.caretColor, .clear, "光标颜色不应被清空")
    }

    func testApplyUsesFixedPitchFont() {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        TerminalTheme.apply(to: view, settings: .read(), dark: true)
        XCTAssertTrue(view.font.isFixedPitch)
    }

    /// 终端容器兜底背景跟工作区/侧栏基底一致，避免 SwiftTerm 初始层露出不同深色。
    func test_terminal_background_matches_workspace_sidebar_background() {
        let n = TerminalTheme.backgroundColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(Double(n.redComponent), 16/255, accuracy: 0.01)
        XCTAssertEqual(Double(n.greenComponent), 16/255, accuracy: 0.01)
        XCTAssertEqual(Double(n.blueComponent), 18/255, accuracy: 0.01)
    }

    /// 每次 SwiftUI 更新都会 apply：设置没变就不能盖掉程序自己设的光标形状。
    func testRepeatedApplyKeepsProgramCursorStyle() {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        TerminalTheme.apply(to: view, settings: .read(), dark: true)

        view.feed(text: "\u{1B}[6 q")
        TerminalTheme.apply(to: view, settings: .read(), dark: true)

        XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar)
    }

    /// vim、fish 这类程序退出时发 `CSI 0 q`（回到默认光标）。默认指用户在设置里选的，不是上游写死的闪烁方块。
    func testProgramResetSequencesReturnToUserCursorSetting() {
        for sequence in ["\u{1B}[0 q", "\u{1B}[ q", "\u{1B}c"] {
            let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            TerminalTheme.apply(to: view, settings: cursorSettings(.bar, blink: false), dark: true)
            view.feed(text: "\u{1B}[3 q")

            view.feed(text: sequence)

            XCTAssertEqual(view.getTerminal().options.cursorStyle, .steadyBar, sequence.debugDescription)
        }
    }

    func testProgramCanStillAskForBlinkingBlockExplicitly() {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        TerminalTheme.apply(to: view, settings: cursorSettings(.bar, blink: false), dark: true)

        view.feed(text: "\u{1B}[1 q")

        XCTAssertEqual(view.getTerminal().options.cursorStyle, .blinkBlock)
    }

    func testResetFollowsLatestCursorSetting() {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        TerminalTheme.apply(to: view, settings: cursorSettings(.bar, blink: false), dark: true)
        TerminalTheme.apply(to: view, settings: cursorSettings(.underline, blink: true), dark: true)

        view.feed(text: "\u{1B}[0 q")

        XCTAssertEqual(view.getTerminal().options.cursorStyle, .blinkUnderline)
    }

    private func cursorSettings(_ shape: TerminalCursorShape, blink: Bool) -> TerminalSettings {
        let name = "TerminalThemeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        var settings = TerminalSettings.read(from: defaults)
        settings.cursorShape = shape
        settings.cursorBlink = blink
        return settings
    }

    func testRepeatedApplyKeepsProgramColors() {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        TerminalTheme.apply(to: view, settings: .read(), dark: true)
        view.nativeBackgroundColor = .systemPink

        TerminalTheme.apply(to: view, settings: .read(), dark: true)

        XCTAssertEqual(view.nativeBackgroundColor, .systemPink)
    }

    func testAppearanceChangeReappliesColors() {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        TerminalTheme.apply(to: view, settings: .read(), dark: true)
        let darkBackground = view.nativeBackgroundColor

        TerminalTheme.apply(to: view, settings: .read(), dark: false)

        XCTAssertNotEqual(view.nativeBackgroundColor, darkBackground)
    }
}
#endif
