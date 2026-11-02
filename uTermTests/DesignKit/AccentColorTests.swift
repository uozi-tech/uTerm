import XCTest
import SwiftUI
import UDesignKit
@testable import uTerm

final class AccentColorTests: XCTestCase {

    private func rgb(_ s: UD.ColorSpec) -> (CGFloat, CGFloat, CGFloat) { (s.r, s.g, s.b) }

    func testLabels() {
        XCTAssertEqual(AccentColor.allCases.map(\.label), ["蓝", "紫", "绿", "橙", "红"])
    }

    func testBaseHexPerColor() {
        XCTAssertEqual(AccentColor.blue.base(dark: true),   UD.ColorSpec.hex(0x1668DC))
        XCTAssertEqual(AccentColor.purple.base(dark: true), UD.ColorSpec.hex(0xBF5AF2))
        XCTAssertEqual(AccentColor.green.base(dark: true),  UD.ColorSpec.hex(0x30D158))
        XCTAssertEqual(AccentColor.orange.base(dark: true), UD.ColorSpec.hex(0xFF9F0A))
        XCTAssertEqual(AccentColor.red.base(dark: true),    UD.ColorSpec.hex(0xFF5A5A))
        XCTAssertEqual(AccentColor.blue.base(dark: false),  UD.ColorSpec.hex(0x1677FF))
        XCTAssertEqual(AccentColor.orange.base(dark: false), UD.ColorSpec.hex(0xFF8A00))
    }

    func testBlueSpecsMatchPalettePrimary() {
        // 组件库调色板（Ant Design 预设）主色 base · hover · pressed，逐级变亮。
        XCTAssertEqual(AccentColor.blue.accentSpec(dark: true),   UD.ColorSpec.hex(0x1668DC))
        XCTAssertEqual(AccentColor.blue.accentSpec(dark: false),  UD.ColorSpec.hex(0x1677FF))
        XCTAssertEqual(AccentColor.blue.hoverSpec(dark: true),    UD.ColorSpec.hex(0x3C89E8))
        XCTAssertEqual(AccentColor.blue.hoverSpec(dark: false),   UD.ColorSpec.hex(0x4096FF))
        XCTAssertEqual(AccentColor.blue.pressedSpec(dark: true),  UD.ColorSpec.hex(0x65A9F3))
        XCTAssertEqual(AccentColor.blue.pressedSpec(dark: false), UD.ColorSpec.hex(0x69B1FF))
        // 日间文字即主色；暗夜深底上取 hover 档提亮。
        XCTAssertEqual(AccentColor.blue.inkSpec(dark: true),      UD.ColorSpec.hex(0x3C89E8))
        XCTAssertEqual(AccentColor.blue.inkSpec(dark: false),     UD.ColorSpec.hex(0x1677FF))
        // softSpec（深 10% / 浅 12%）。14% 那一档叫 `UD.accentTint`（选中 / 主操作底），是另一个 token。
        XCTAssertEqual(AccentColor.blue.softSpec(dark: true),     UD.ColorSpec.hex(0x1668DC, 0.10))
        XCTAssertEqual(AccentColor.blue.softSpec(dark: false),    UD.ColorSpec.hex(0x1677FF, 0.12))
    }

    func testSoftIsBaseWithAlpha() {
        let s = AccentColor.purple.softSpec(dark: true)
        let base = AccentColor.purple.base(dark: true)
        XCTAssertEqual(rgb(s).0, base.r, accuracy: 0.0001)
        XCTAssertEqual(rgb(s).1, base.g, accuracy: 0.0001)
        XCTAssertEqual(rgb(s).2, base.b, accuracy: 0.0001)
        XCTAssertEqual(s.a, 0.10, accuracy: 0.0001)
        XCTAssertEqual(AccentColor.purple.softSpec(dark: false).a, 0.12, accuracy: 0.0001)
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

    func testHoverAndPressedMoveTowardWhite() {
        // 调色板约定 base → hover → pressed 逐级变亮（pressed 最亮）。
        let base = AccentColor.red.base(dark: true)
        let hover = AccentColor.red.hoverSpec(dark: true)
        let pressed = AccentColor.red.pressedSpec(dark: true)
        XCTAssertGreaterThan(hover.g, base.g)
        XCTAssertGreaterThan(pressed.g, hover.g)
        XCTAssertEqual(pressed.b, base.b * 0.64 + 0.36, accuracy: 0.0001)
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
        // 迁到共享包后重写的桥接：id 跟 commandPaletteSettingsItems 同族用 `setting.` 前缀，
        // detail 固定为说明文案，「当前」标记挪到 hint 位。
        XCTAssertEqual(items.map(\.id), ["setting.accent.blue", "setting.accent.purple",
                                        "setting.accent.green", "setting.accent.orange",
                                        "setting.accent.red"])
        XCTAssertTrue(items.allSatisfy { $0.detail == "切换全局界面强调色" })
        XCTAssertEqual(items.first { $0.id == "setting.accent.green" }?.hint, "当前")
        XCTAssertEqual(items.first { $0.id == "setting.accent.blue" }?.hint, "↵")
    }

    @MainActor
    func testAccentPaletteItemRunSwitchesAccent() throws {
        defer { AccentState.shared.selected = .blue }
        AccentState.shared.selected = .blue
        let items = commandPaletteAccentItems()
        // XCTUnwrap：id 若再漂移，这里直接失败，而不是静默不 run 后断言「还是蓝」。
        let red = try XCTUnwrap(items.first { $0.id == "setting.accent.red" })
        red.run()
        XCTAssertEqual(AccentState.shared.selected, .red)
    }
}
