import XCTest
@testable import uTerm

@MainActor
final class TerminalSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TerminalSettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_fixed_font_constants() {
        XCTAssertEqual(TerminalSettings.fontName,   "System Monospaced")
        XCTAssertEqual(TerminalSettings.fontSize,   12)
        XCTAssertEqual(TerminalSettings.lineHeight, 1.0)
    }

    func test_read_empty_defaults_returns_all_defaults() {
        let s = TerminalSettings.read(from: defaults)
        XCTAssertEqual(s.cursorShape,    .block)
        XCTAssertEqual(s.cursorBlink,    false)
        XCTAssertEqual(s.scrollback,     3000)
        XCTAssertEqual(s.copyOnSelect,   false)
    }

    func test_read_partial_defaults_only_overrides_written() {
        defaults.set(5000, forKey: "terminalScrollback")
        defaults.set(true, forKey: "terminalCopyOnSelect")
        let s = TerminalSettings.read(from: defaults)
        XCTAssertEqual(s.scrollback,   5000)
        XCTAssertEqual(s.copyOnSelect, true)
        XCTAssertEqual(s.cursorShape,  .block)   // unchanged default
    }

    func test_read_corrupt_cursor_shape_falls_back_to_block() {
        defaults.set("garbage", forKey: "terminalCursorShape")
        let s = TerminalSettings.read(from: defaults)
        XCTAssertEqual(s.cursorShape, .block)
    }

    func test_colorScheme_resolves_by_appearance() {
        let s = TerminalSettings.read(from: defaults)
        XCTAssertEqual(s.colorScheme(dark: true).displayName,  "VS Code Dark")
        XCTAssertEqual(s.colorScheme(dark: false).displayName, "VS Code Light")
    }
}
