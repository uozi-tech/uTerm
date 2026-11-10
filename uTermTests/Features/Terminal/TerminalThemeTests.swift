import XCTest
import AppKit
import GhosttyTerminal
@testable import uTerm

/// 终端的外观与设置怎么交给引擎。原来核的是 `TerminalTheme.apply(to:)`（往 SwiftTerm 视图上设颜色、字体、光标）；
/// 现在是 `GhosttyTerminalConfig` 把 uTerm 的设置翻成 Ghostty 的配置文本（`base` 是与外观无关的部分，`colors` / `theme`
/// 是深浅两套配色）。这里核产出的配置；配置在真的 surface 上生效没有，由带窗口的用例核
/// （`TerminalContrastTests` 的像素、`TerminalFontChangeTests` 的配置重载）。
@MainActor
final class TerminalThemeTests: XCTestCase {

    /// 配置文本解析成「键 → 全部取值」（font-family、palette 这类键可以重复）。
    private func entries(_ configuration: GhosttyTerminal.TerminalConfiguration) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for line in configuration.rendered.split(separator: "\n") {
            guard let separator = line.range(of: " = ") else { continue }
            out[String(line[..<separator.lowerBound]), default: []].append(String(line[separator.upperBound...]))
        }
        return out
    }

    private func settings(_ shape: TerminalCursorShape = .block, blink: Bool = false, scrollback: Int = 3_000,
                          copyOnSelect: Bool = false) -> TerminalSettings {
        TerminalSettings(cursorShape: shape, cursorBlink: blink, scrollback: scrollback, copyOnSelect: copyOnSelect)
    }

    /// uTerm 是交互式终端，光标必须可见。早先从 uService 移植过来的 `hideInputCursor` 把光标色抹成透明，
    /// 输入时看不到光标。配置里光标色必须是配色方案里那个不透明的颜色，光标下的字用终端底色。
    func testCursorColorIsOpaqueAndComesFromTheScheme() {
        for scheme in [uTerm.TerminalColorScheme.vscodeDark, .vscodeLight] {
            let config = entries(GhosttyTerminalConfig.colors(scheme))
            let cursor = GhosttyTerminalConfig.hex(scheme.cursorColor)
            XCTAssertEqual(config["cursor-color"], [cursor], scheme.displayName)
            XCTAssertEqual(cursor.count, 7, "#RRGGBB，不带透明度")
            XCTAssertEqual(config["cursor-text"], [GhosttyTerminalConfig.hex(scheme.backgroundColor)])
            XCTAssertNil(config["cursor-opacity"], "不调光标透明度")
            XCTAssertNotEqual(cursor, GhosttyTerminalConfig.hex(scheme.backgroundColor), "光标不能和底色一样")
        }
    }

    /// 一个字体族在 CoreText 里有哪些款式（Ghostty 也是按族名 + 款式名在 CoreText 里找）。
    private func styles(ofFamily family: String) -> [String] {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let matches = (CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor]) ?? []
        return matches.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontStyleNameAttribute) as? String }
    }

    /// 终端字体的回退链：系统等宽 → Menlo → PingFang SC，按顺序写进配置；字重 Medium；加粗开着、强度 0。
    /// 苹方必须显式写上且排在最后（汉字固定用它、字重稳定）；SF Mono 不是系统自带的，不写。
    /// 画出来的样子（中文字重、全角标点位置、英文粗细）由 `GhosttyFontRenderingTests` 读像素核。
    func testFontFallbackChainAndWeight() throws {
        let families = GhosttyTerminalConfig.fontFamilies()
        let system = try XCTUnwrap(TerminalSettings.textFont().familyName)
        XCTAssertEqual(families, [system, "Menlo", "PingFang SC"])
        XCTAssertFalse(families.contains("SF Mono"))
        XCTAssertTrue(TerminalSettings.textFont().isFixedPitch)
        XCTAssertTrue(NSFont(name: "Menlo", size: 12)?.isFixedPitch ?? false, "系统自带的等宽字体")
        // 第一个和最后一个都要有 Medium 这一款：font-style 对链里每个族名都生效，没有这一款的族名会被跳过。
        XCTAssertTrue(styles(ofFamily: system).contains("Medium"), "\(system)：\(styles(ofFamily: system))")
        XCTAssertTrue(styles(ofFamily: "PingFang SC").contains("Medium"), "PingFang SC：\(styles(ofFamily: "PingFang SC"))")

        let config = entries(GhosttyTerminalConfig.base(settings: settings()))
        XCTAssertEqual(config["font-family"], families, "回退链按顺序写进配置")
        XCTAssertEqual((config["font-size"] ?? []).compactMap { Double($0) }, [TerminalSettings.fontSize])
        XCTAssertEqual(config["font-style"], ["Medium"])
        XCTAssertEqual(config["font-thicken"], ["true"])
        XCTAssertEqual(config["font-thicken-strength"], ["0"])
        XCTAssertNil(config["adjust-cell-height"], "行高不动")
    }

    /// 终端底色 = 内容卡的卡面色：暗夜 #141414（`UD.panel`）、日间白卡白终端。终端坐在工作区内容卡的凹槽里，
    /// 底色和卡面不一样的话凹槽四角会露出另一种颜色。（原来这条核的是 `TerminalTheme.backgroundColor` 这个兜底常数，
    /// 它随 SwiftTerm 的宿主视图一起删了；现在只有配色方案里的这一个底色，直接写进 Ghostty 的配置。）
    func test_terminal_background_matches_workspace_sidebar_background() {
        let dark = uTerm.TerminalColorScheme.resolve(dark: true), light = uTerm.TerminalColorScheme.resolve(dark: false)
        XCTAssertEqual(GhosttyTerminalConfig.hex(dark.backgroundColor), "#141414")
        XCTAssertEqual(entries(GhosttyTerminalConfig.colors(dark))["background"], ["#141414"])
        XCTAssertEqual(GhosttyTerminalConfig.hex(light.backgroundColor), "#FFFFFF")
        XCTAssertEqual(entries(GhosttyTerminalConfig.colors(light))["background"], ["#FFFFFF"])
    }

    /// 深浅两套配色各自写全：底色、前景、选区、16 色调色板、最低对比度；深浅的底色不同。
    func testThemeCarriesBothAppearances() {
        let theme = GhosttyTerminalConfig.theme()
        let light = entries(theme.light), dark = entries(theme.dark)
        XCTAssertNotEqual(light["background"], dark["background"])
        for (name, config, scheme) in [("浅色", light, uTerm.TerminalColorScheme.vscodeLight), ("深色", dark, .vscodeDark)] {
            XCTAssertEqual(config["background"], [GhosttyTerminalConfig.hex(scheme.backgroundColor)], name)
            XCTAssertEqual(config["foreground"], [GhosttyTerminalConfig.hex(scheme.foregroundColor)], name)
            XCTAssertEqual(config["selection-background"], [GhosttyTerminalConfig.hex(scheme.selectionColor)], name)
            XCTAssertEqual(config["palette"]?.count, 16, name)
            for (index, color) in scheme.ansiColors.enumerated() {
                XCTAssertEqual(config["palette"]?[index], "\(index)=\(color.hex)", "\(name) 第 \(index) 色")
            }
            XCTAssertEqual((config["minimum-contrast"] ?? []).compactMap { Double($0) },
                           [Double(uTerm.TerminalColorScheme.minimumContrastRatio)], name)
        }
    }

    /// 设置里的光标形状与闪烁写进配置。程序用 `CSI n q` 临时改光标、`CSI 0 q` 回到默认——「默认」由引擎按配置里的
    /// 这两项还原，所以配置必须跟着用户的设置走（SwiftTerm 上要靠补丁把「默认」从写死的闪烁方块改成用户选的）。
    func testCursorSettingsReachTheConfiguration() {
        let cases: [(TerminalCursorShape, Bool, String)] = [(.block, false, "block"), (.bar, false, "bar"), (.underline, true, "underline")]
        for (shape, blink, expected) in cases {
            let config = entries(GhosttyTerminalConfig.base(settings: settings(shape, blink: blink)))
            XCTAssertEqual(config["cursor-style"], [expected])
            XCTAssertEqual(config["cursor-style-blink"], [blink ? "true" : "false"])
        }
        // 设置换了，配置跟着换：`GhosttyTerminalBridge.apply(settings:)` 靠它判断要不要整份重载。
        XCTAssertNotEqual(GhosttyTerminalConfig.base(settings: settings(.bar)), GhosttyTerminalConfig.base(settings: settings(.underline)))
        XCTAssertEqual(GhosttyTerminalConfig.base(settings: settings(.bar)), GhosttyTerminalConfig.base(settings: settings(.bar)))
    }

    /// 每次 SwiftUI 更新都会 apply：设置没变就什么都不做，不会盖掉程序自己设的光标形状和颜色
    /// （SwiftTerm 上是比对后跳过；Ghostty 上重载配置同样要跳过）。这里能核的是：重复 apply 之后控制器手上的配置
    /// 文本没有变；程序设的模式在配置重载后还在，由 `TerminalFontChangeTests` 在真的 surface 上核。
    func testRepeatedApplyWithUnchangedSettingsKeepsTheConfiguration() {
        let current = TerminalSettings.read()
        GhosttyTerminalBridge.apply(settings: current)
        let before = GhosttyTerminalConfig.controller.renderedConfig
        for _ in 0..<5 { GhosttyTerminalBridge.apply(settings: current) }
        XCTAssertEqual(GhosttyTerminalConfig.controller.renderedConfig, before)
        let config = before
        XCTAssertTrue(config.contains("cursor-style = \(GhosttyTerminalConfig.cursorStyle(current.cursorShape).rawValue)"),
                      "控制器用的就是当前设置的那份配置")
        XCTAssertTrue(config.contains("scrollback-limit-lines = \(current.scrollback)"))
    }

    /// 历史行数：surface 和影子终端的回滚上限用同一个函数算（`TerminalScrollbackLimits`），两边必须一样，
    /// 否则回放进 surface 的历史长度和它自己攒的不一样。字节上限按行数放宽，不低于 10 MB。
    func testScrollbackLimitsAreSharedBetweenTheSurfaceAndTheShadow() {
        for lines in [1_000, 3_000, 10_000, 100_000] {
            let limits = TerminalScrollbackLimits(lines: lines)
            let config = entries(GhosttyTerminalConfig.base(settings: settings(scrollback: lines)))
            XCTAssertEqual(config["scrollback-limit-lines"], [String(lines)])
            XCTAssertEqual(config["scrollback-limit-bytes"], [String(limits.bytes)])
            XCTAssertEqual(limits.shadowOptions.scrollbackLines, lines)
            XCTAssertEqual(limits.shadowOptions.scrollbackBytes, limits.bytes)
            XCTAssertGreaterThanOrEqual(limits.bytes, 10_000_000)
            XCTAssertGreaterThanOrEqual(limits.bytes, lines * 1_000)
            XCTAssertNil(config["scrollback-limit"], "旧键这个版本不认、静默忽略，不能再写")
        }
        XCTAssertEqual(TerminalScrollbackLimits(lines: -5).lines, 0)
    }

    /// 与安全、与 uTerm 自己的机制有关的几项固定值。
    func testFixedConfigurationThatUTermReliesOn() {
        let config = entries(GhosttyTerminalConfig.base(settings: settings()))
        XCTAssertEqual(config["clipboard-read"], ["deny"], "远端程序不能读走 Mac 的剪贴板")
        XCTAssertEqual(config["clipboard-write"], ["allow"])
        XCTAssertEqual(config["desktop-notifications"], ["false"], "通知由影子终端的事件发，Ghostty 不重复发")
        XCTAssertEqual(config["shell-integration"], ["none"])
        XCTAssertEqual(config["confirm-close-surface"], ["false"])
        XCTAssertEqual(config["window-padding-x"], ["0"], "内边距由容器留，网格才等于「视图像素 ÷ 格子像素」")
        XCTAssertEqual(config["window-padding-y"], ["0"])
        XCTAssertEqual(config["window-padding-balance"], ["false"])
        XCTAssertEqual(config["copy-on-select"], ["none"])
        XCTAssertEqual(entries(GhosttyTerminalConfig.base(settings: settings(copyOnSelect: true)))["copy-on-select"], ["clipboard"])
        // 迁移前的着色规则（M16）。
        XCTAssertEqual(config["palette-generate"], ["true"])
        XCTAssertEqual(config["bold-color"], ["bright"])
        XCTAssertEqual(config["faint-opacity"], ["0.5"])
    }

    /// 外观变了（深 ↔ 浅）：影子终端替 surface 答颜色查询时用的配色跟着换。
    func testAppearanceChangeUpdatesTheColorsTheShadowReports() async {
        let session = TerminalSession()
        session.attentionSink = { _ in }
        defer { session.dispose() }
        let backend = MockBackend()
        await session.connect(using: backend)

        func backgroundReply(dark: Bool) async -> String {
            session.updateShadowColors(dark: dark)
            let before = await backend.writtenData.count
            session.feedOutput(text: "\u{1b}]11;?\u{07}")
            let deadline = Date().addingTimeInterval(2)
            while await backend.writtenData.count == before, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return await backend.writtenData.dropFirst(before).map { String(decoding: $0, as: UTF8.self) }.joined()
        }
        let dark = await backgroundReply(dark: true)
        let light = await backgroundReply(dark: false)
        XCTAssertTrue(dark.hasPrefix("\u{1b}]11;rgb:"), dark.debugDescription)
        XCTAssertTrue(light.hasPrefix("\u{1b}]11;rgb:"), light.debugDescription)
        XCTAssertNotEqual(dark, light, "深浅两种外观报的底色不同")
        XCTAssertTrue(dark.contains("rgb:1414/1414/1414"), "深色底 #141414：\(dark.debugDescription)")
        XCTAssertTrue(light.contains("rgb:ffff/ffff/ffff"), "浅色底 #FFFFFF：\(light.debugDescription)")
    }
}
