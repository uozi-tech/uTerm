import XCTest
@testable import uTerm

/// 光标两项偏好的读取与默认值（两端共用 `TerminalCursorPreference`；mac `TerminalSettings.read` 也走它）。
final class TerminalCursorPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TerminalCursorPreferenceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testMissingKeysGiveSteadyBlock() {
        XCTAssertEqual(TerminalCursorPreference.read(from: defaults), TerminalCursorLook(shape: .block, blink: false))
        XCTAssertEqual(TerminalCursorPreference.defaultShape, .block)
        XCTAssertFalse(TerminalCursorPreference.defaultBlink)
    }

    func testStoredValuesAreRead() {
        defaults.set(TerminalCursorShape.bar.rawValue, forKey: DefaultsKey.terminalCursorShape)
        defaults.set(true, forKey: DefaultsKey.terminalCursorBlink)
        XCTAssertEqual(TerminalCursorPreference.read(from: defaults), TerminalCursorLook(shape: .bar, blink: true))
    }

    func testUnknownShapeFallsBackToBlock() {
        defaults.set("triangle", forKey: DefaultsKey.terminalCursorShape)
        XCTAssertEqual(TerminalCursorPreference.read(from: defaults).shape, .block)
        XCTAssertEqual(TerminalCursorPreference.shape(rawValue: nil), .block)
        XCTAssertEqual(TerminalCursorPreference.shape(rawValue: ""), .block)
        XCTAssertEqual(TerminalCursorPreference.shape(rawValue: "underline"), .underline)
    }

    /// mac 的整份终端设置读同一份光标值，不再各写一份默认。
    func testTerminalSettingsReadUsesTheSharedCursorPreference() {
        defaults.set(TerminalCursorShape.underline.rawValue, forKey: DefaultsKey.terminalCursorShape)
        defaults.set(true, forKey: DefaultsKey.terminalCursorBlink)
        let settings = TerminalSettings.read(from: defaults)
        XCTAssertEqual(TerminalCursorLook(shape: settings.cursorShape, blink: settings.cursorBlink),
                       TerminalCursorPreference.read(from: defaults))
    }
}
