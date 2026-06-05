import XCTest
import SwiftUI
@testable import uTerm

final class AccentColorTests: XCTestCase {

    private func rgb(_ s: UD.ColorSpec) -> (CGFloat, CGFloat, CGFloat) { (s.r, s.g, s.b) }

    func testLabels() {
        XCTAssertEqual(AccentColor.allCases.map(\.label), ["蓝", "紫", "绿", "橙", "红"])
    }

    func testBaseHexPerColor() {
        XCTAssertEqual(AccentColor.blue.base(dark: true),   UD.ColorSpec.hex(0x0A84FF))
        XCTAssertEqual(AccentColor.purple.base(dark: true), UD.ColorSpec.hex(0xBF5AF2))
        XCTAssertEqual(AccentColor.green.base(dark: true),  UD.ColorSpec.hex(0x30D158))
        XCTAssertEqual(AccentColor.orange.base(dark: true), UD.ColorSpec.hex(0xFF9F0A))
        XCTAssertEqual(AccentColor.red.base(dark: true),    UD.ColorSpec.hex(0xFF5A5A))
        XCTAssertEqual(AccentColor.blue.base(dark: false),  UD.ColorSpec.hex(0x007AFF))
        XCTAssertEqual(AccentColor.orange.base(dark: false), UD.ColorSpec.hex(0xFF8A00))
    }

    func testBlueSpecsMatchLegacyConstants() {
        XCTAssertEqual(AccentColor.blue.accentSpec(dark: true),   UD.ColorSpec.hex(0x0A84FF))
        XCTAssertEqual(AccentColor.blue.accentSpec(dark: false),  UD.ColorSpec.hex(0x007AFF))
        XCTAssertEqual(AccentColor.blue.inkSpec(dark: true),      UD.ColorSpec.hex(0x4DA3FF))
        XCTAssertEqual(AccentColor.blue.inkSpec(dark: false),     UD.ColorSpec.hex(0x0067E0))
        XCTAssertEqual(AccentColor.blue.softSpec(dark: true),     UD.ColorSpec.hex(0x0A84FF, 0.10))
        XCTAssertEqual(AccentColor.blue.softSpec(dark: false),    UD.ColorSpec.hex(0x007AFF, 0.13))
        XCTAssertEqual(AccentColor.blue.pressedSpec(dark: true),  UD.ColorSpec.hex(0x96ACCD))
        XCTAssertEqual(AccentColor.blue.pressedSpec(dark: false), UD.ColorSpec.hex(0x5A7099))
    }

    func testSoftIsBaseWithAlpha() {
        let s = AccentColor.purple.softSpec(dark: true)
        let base = AccentColor.purple.base(dark: true)
        XCTAssertEqual(rgb(s).0, base.r, accuracy: 0.0001)
        XCTAssertEqual(rgb(s).1, base.g, accuracy: 0.0001)
        XCTAssertEqual(rgb(s).2, base.b, accuracy: 0.0001)
        XCTAssertEqual(s.a, 0.10, accuracy: 0.0001)
        XCTAssertEqual(AccentColor.purple.softSpec(dark: false).a, 0.13, accuracy: 0.0001)
    }

    func testInkBrightensInDarkDeepensInLight() {
        let base = AccentColor.green.base(dark: true)
        let ink = AccentColor.green.inkSpec(dark: true)
        XCTAssertGreaterThanOrEqual(ink.r, base.r)
        XCTAssertLessThanOrEqual(ink.r, 1.0)
        let lbase = AccentColor.green.base(dark: false)
        let link = AccentColor.green.inkSpec(dark: false)
        XCTAssertLessThanOrEqual(link.g, lbase.g)
    }

    func testInkUsesBrightenFactorForDerivedColor() {
        // 锁定派生提亮系数 1.22（防止 inkSpec 派生公式被无意改动）
        let base = AccentColor.orange.base(dark: true)
        let ink = AccentColor.orange.inkSpec(dark: true)
        XCTAssertEqual(ink.g, min(base.g * 1.22, 1.0), accuracy: 0.0001)
        XCTAssertEqual(ink.b, min(base.b * 1.22, 1.0), accuracy: 0.0001)
    }

    func testPressedMovesTowardGray() {
        let base = AccentColor.red.base(dark: true)
        let pressed = AccentColor.red.pressedSpec(dark: true)
        XCTAssertLessThan(abs(pressed.r - 0.5), abs(base.r - 0.5) + 0.0001)
        XCTAssertLessThan(abs(pressed.g - 0.5), abs(base.g - 0.5) + 0.0001)
    }

    @MainActor
    func testAccentStateDefaultsToBlueWhenAbsent() {
        let suite = UserDefaults(suiteName: "acc.test.absent")!
        suite.removePersistentDomain(forName: "acc.test.absent")
        let s = AccentState(defaults: suite)
        XCTAssertEqual(s.selected, .blue)
    }

    @MainActor
    func testAccentStateReadsValidStoredValue() {
        let suite = UserDefaults(suiteName: "acc.test.valid")!
        suite.removePersistentDomain(forName: "acc.test.valid")
        suite.set("green", forKey: AccentState.key)
        let s = AccentState(defaults: suite)
        XCTAssertEqual(s.selected, .green)
    }

    @MainActor
    func testAccentStateUnknownValueFallsBackToBlue() {
        let suite = UserDefaults(suiteName: "acc.test.unknown")!
        suite.removePersistentDomain(forName: "acc.test.unknown")
        suite.set("chartreuse", forKey: AccentState.key)
        let s = AccentState(defaults: suite)
        XCTAssertEqual(s.selected, .blue)
    }

    @MainActor
    func testAccentStatePersistsOnSet() {
        let suite = UserDefaults(suiteName: "acc.test.persist")!
        suite.removePersistentDomain(forName: "acc.test.persist")
        let s = AccentState(defaults: suite)
        s.selected = .red
        XCTAssertEqual(suite.string(forKey: AccentState.key), "red")
    }

    @MainActor
    func testAccentPaletteItems() {
        defer { AccentState.shared.selected = .blue }
        AccentState.shared.selected = .green
        let items = commandPaletteAccentItems()
        XCTAssertEqual(items.count, 5)
        XCTAssertTrue(items.allSatisfy { $0.kind == .setting })
        XCTAssertEqual(Set(items.map(\.id)).count, 5)
        XCTAssertEqual(items.map(\.title),
                       ["强调色 · 蓝", "强调色 · 紫", "强调色 · 绿", "强调色 · 橙", "强调色 · 红"])
        XCTAssertEqual(items.first { $0.id == "accent.green" }?.detail, "当前")
        XCTAssertEqual(items.first { $0.id == "accent.blue" }?.detail, "")
    }

    @MainActor
    func testAccentPaletteItemRunSwitchesAccent() {
        defer { AccentState.shared.selected = .blue }
        AccentState.shared.selected = .blue
        let items = commandPaletteAccentItems()
        items.first { $0.id == "accent.red" }?.run()
        XCTAssertEqual(AccentState.shared.selected, .red)
    }
}
