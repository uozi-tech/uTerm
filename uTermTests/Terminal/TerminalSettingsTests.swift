import XCTest
@testable import uTerm

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

    func test_read_empty_defaults_returns_all_defaults() {
        let s = TerminalSettings.read(from: defaults)
        XCTAssertEqual(s.fontName,       "Menlo")
        XCTAssertEqual(s.fontSize,       11)
        XCTAssertEqual(s.lineHeight,     1.0)
        XCTAssertEqual(s.colorSchemeID,  .vscodeDark)
        XCTAssertEqual(s.cursorShape,    .block)
        XCTAssertEqual(s.cursorBlink,    false)
        XCTAssertEqual(s.scrollback,     3000)
        XCTAssertEqual(s.copyOnSelect,   false)
    }

    func test_read_partial_defaults_only_overrides_written() {
        defaults.set("SF Mono", forKey: "terminalFontName")
        defaults.set(14.0,      forKey: "terminalFontSize")
        let s = TerminalSettings.read(from: defaults)
        XCTAssertEqual(s.fontName,    "SF Mono")
        XCTAssertEqual(s.fontSize,    14)
        XCTAssertEqual(s.lineHeight,  1.0)         // unchanged default
        XCTAssertEqual(s.scrollback,  3000)        // unchanged default
    }

    func test_read_corrupt_scheme_raw_falls_back_to_vscodeDark() {
        defaults.set("garbage", forKey: "terminalColorScheme")
        let s = TerminalSettings.read(from: defaults)
        XCTAssertEqual(s.colorSchemeID, .vscodeDark)
    }

    func test_read_corrupt_cursor_shape_falls_back_to_block() {
        defaults.set("garbage", forKey: "terminalCursorShape")
        let s = TerminalSettings.read(from: defaults)
        XCTAssertEqual(s.cursorShape, .block)
    }

    func test_colorScheme_resolves_correct_scheme() {
        defaults.set("tokyonight", forKey: "terminalColorScheme")
        let s = TerminalSettings.read(from: defaults)
        XCTAssertEqual(s.colorScheme.id, .tokyoNight)
        XCTAssertEqual(s.colorScheme.displayName, "Tokyo Night")
    }
}
