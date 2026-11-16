import XCTest
import AppKit
import GhosttyTerminal
@testable import uTerm

/// 渲染期最低对比度。远端 prompt / TUI 按深色背景硬编码的 256 色 / 真彩色在浅色背景下不可读，`minimum-contrast`
/// 在渲染时把前景色钳到可读对比度。钳制是保色相的：OKLCH 空间只调明度，色相不动、饱和度仅按色域收缩——彩色不应
/// 被洗成黑白灰；装饰字形（盒线 / 块元素 / powerline）也不豁免。
///
/// 原来这是旧引擎上的本地补丁（`TerminalContrast.ensureContrast`，纯函数，直接调）。现在钳制在引擎的 shader 里
/// （引擎补丁 0022；官方 Ghostty 是达不到目标比就换成纯黑或纯白，块字符豁免），没有可以直接调的函数，所以这里读
/// 真的 surface **画出来的像素**：用整格的块字符 █（它正好是「装饰字形也钳制」的那一类）铺一格前景色，取这一格中心
/// 的颜色，和这一格的底色算 WCAG 对比度。
@MainActor
final class TerminalContrastTests: XCTestCase {

    private typealias RGB = (r: Int, g: Int, b: Int)

    private var rig: GhosttySurfaceRig!
    private var appearanceIsDark = true

    override func setUp() async throws {
        rig = await GhosttySurfaceRig()
    }

    override func tearDown() async throws {
        rig.close()
        rig = nil
        // 外观是进程里所有 Ghostty 窗格共用的：还原成 app 现在的外观。
        let dark = NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        GhosttyTerminalConfig.controller.setColorScheme(dark ? .dark : .light)
    }

    // MARK: 读数

    private func rgb(_ hex: UInt32) -> RGB {
        (Int((hex >> 16) & 0xFF), Int((hex >> 8) & 0xFF), Int(hex & 0xFF))
    }

    private func rgb(_ color: NSColor) -> RGB {
        let c = color.usingColorSpace(.sRGB) ?? color
        return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    private func luminance(_ c: RGB) -> Double {
        func channel(_ v: Int) -> Double {
            let s = Double(v) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func near(_ a: RGB, _ b: RGB, tolerance: Int = 6) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }

    private func describe(_ c: RGB?) -> String {
        c.map { String(format: "#%02X%02X%02X", $0.r, $0.g, $0.b) } ?? "读不到"
    }

    private func use(dark: Bool) {
        appearanceIsDark = dark
        GhosttyTerminalConfig.controller.setColorScheme(dark ? .dark : .light)
    }

    private var terminalBackground: RGB {
        rgb(uTerm.TerminalColorScheme.resolve(dark: appearanceIsDark).backgroundColor)
    }

    private var ratio: Double { Double(uTerm.TerminalColorScheme.minimumContrastRatio) }

    private var nextRow = 0

    /// 在新的一行开头画四格前景色为 `fg` 的块字符（`bg` 非 nil 时这几格的底色是它），等这一帧画出来，
    /// 返回第 2 格中心的颜色。画出来的颜色和「没钳制、原样画」的颜色之间可以差一点点（色彩管理、抖动）。
    private func drawn(fg: RGB, on bg: RGB? = nil, file: StaticString = #filePath, line: UInt = #line) async -> RGB {
        let row = nextRow
        nextRow += 1
        var sgr = "\u{1b}[38;2;\(fg.r);\(fg.g);\(fg.b)m"
        if let bg { sgr += "\u{1b}[48;2;\(bg.r);\(bg.g);\(bg.b)m" }
        let text = "\u{1b}[\(row + 1);1H\(sgr)████\u{1b}[0m"
        let cellBackground = bg ?? terminalBackground
        // 等到这一格既不是底色、也不再是写之前画面上的颜色（画出来了）。前景被钳成和底色一样是不可能的（那就没有对比度了）。
        // 只看「不是底色」不够：这一格自带底色、或者刚切完深浅色时，写之前的那一帧里它是默认底色（浅色下 #FFFFFF），
        // 同样不等于期望的底色，旧帧会被当成结果（换到 Ghostty cf5519b2 之后新帧晚到几毫秒，这样读错过）。
        // 刚切完深浅色时渲染器偶尔不为紧跟着的这次输出再出一帧：没等到就把同样的内容再写一遍（幂等），催它重画。
        let before = rig.pixel(col: 1, row: row)
        func isDrawn(_ p: RGB) -> Bool {
            !near(p, cellBackground, tolerance: 2) && !(before.map { near(p, $0, tolerance: 0) } ?? false)
        }
        var pixel: RGB?
        for _ in 0..<5 {
            await rig.feed(text)
            pixel = await rig.waitForPixel(col: 1, row: row, timeout: 1) { isDrawn($0) }
            if let pixel, isDrawn(pixel) { break }
        }
        guard let pixel, isDrawn(pixel) else {
            XCTFail("第 \(row + 1) 行没画出来（读到 \(describe(pixel))）；测试窗口被遮挡时引擎不出帧", file: file, line: line)
            return cellBackground
        }
        return pixel
    }

    // MARK: 用例前提

    /// 画面上读到的底色就是配色方案里的终端底色（读像素这条路是通的、色彩没被改掉）。
    func test_drawn_background_matches_the_scheme() async {
        for dark in [false, true] {
            use(dark: dark)
            await rig.feed("\u{1b}[2J\u{1b}[H")
            let expected = terminalBackground
            let pixel = await rig.waitForPixel(col: 10, row: 10) { self.near($0, expected) }
            XCTAssertTrue(pixel.map { near($0, expected) } ?? false,
                          "\(dark ? "深色" : "浅色")底应为 \(describe(expected))，读到 \(describe(pixel))")
        }
    }

    // MARK: 钳制

    /// p10k 一类 prompt 的典型场景：256 色 180 (#D7AF87) 按深色背景设计，在白底上对比度 ~1.9，钳制后必须达到最低对比度。
    func test_dark_designed_color_on_white_is_clamped() async {
        use(dark: false)
        let fg = rgb(0xD7AF87), bg = terminalBackground
        XCTAssertLessThan(contrast(fg, bg), ratio, "前提：原始对比不足")
        let shown = await drawn(fg: fg)
        XCTAssertGreaterThanOrEqual(contrast(shown, bg), ratio - 0.15, "画出来的是 \(describe(shown))")
        XCTAssertLessThan(luminance(shown), luminance(fg), "浅底上的浅色变深")
    }

    /// 钳制方向：浅底上的浅色变深，深底上的深色变浅。
    func test_clamp_moves_toward_the_correct_pole() async {
        use(dark: false)
        let onLight = await drawn(fg: rgb(0xCCCCCC))
        XCTAssertLessThan(luminance(onLight), luminance(rgb(0xCCCCCC)), "画出来的是 \(describe(onLight))")
        XCTAssertGreaterThanOrEqual(contrast(onLight, terminalBackground), ratio - 0.15)

        use(dark: true)
        let onDark = await drawn(fg: rgb(0x333333))
        XCTAssertGreaterThan(luminance(onDark), luminance(rgb(0x333333)), "画出来的是 \(describe(onDark))")
        XCTAssertGreaterThanOrEqual(contrast(onDark, terminalBackground), ratio - 0.15)
    }

    /// 回归：中灰段底（#6D6D6D，p10k powerline 常用）上、比段底略暗的前景（ansi31 路径分隔符 #3D6D7E）必须随段底一起
    /// 「提亮」，不能因方向取错被压成近黑——这正是 `/` 在中灰段上发黑的根因。方向按背景判定（深 / 中灰一律提亮）。
    func test_near_bg_fg_on_midgray_segment_is_lightened() async {
        use(dark: false)
        let fg = rgb(0x3D6D7E), bg = rgb(0x6D6D6D)
        let shown = await drawn(fg: fg, on: bg)
        XCTAssertGreaterThanOrEqual(contrast(shown, bg), ratio - 0.15, "画出来的是 \(describe(shown))")
        XCTAssertGreaterThan(luminance(shown), luminance(bg), "中灰段底上的前景应被提亮到比段底更亮，而非压黑")
    }

    /// 已达标的颜色原样画，不做任何改动。
    func test_compliant_color_is_drawn_unchanged() async {
        use(dark: false)
        let fg = rgb(0x3B3B3B)
        XCTAssertGreaterThan(contrast(fg, terminalBackground), ratio)
        let shown = await drawn(fg: fg)
        XCTAssertTrue(near(shown, fg), "达标颜色应原样画，画出来的是 \(describe(shown))")

        use(dark: true)
        let bright = rgb(0xD4D4D4)
        let shownOnDark = await drawn(fg: bright)
        XCTAssertTrue(near(shownOnDark, bright), "达标颜色应原样画，画出来的是 \(describe(shownOnDark))")
    }

    /// 极端：白底白字 / 黑底黑字 / 灰底灰字也必须钳出可读对比（极点兜底）。
    func test_identical_fg_and_bg_still_end_up_readable() async {
        use(dark: false)
        for hex in [UInt32(0xFFFFFF), 0x000000, 0x808080] {
            let color = rgb(hex)
            let shown = await drawn(fg: color, on: color)
            XCTAssertGreaterThanOrEqual(contrast(shown, color), ratio - 0.15,
                                        "fg==bg #\(String(hex, radix: 16)) 应钳出可读对比，画出来的是 \(describe(shown))")
        }
    }

    // MARK: 保色相

    /// 白底上的琥珀色被压暗后仍应是「暖色」（R > G > B 且有可感知饱和度），不是灰黑——这是与黑白混色钳制
    /// （xterm.js、官方 Ghostty）的关键差异。
    func test_clamp_preserves_hue_on_white() async {
        use(dark: false)
        let shown = await drawn(fg: rgb(0xD7AF87))
        XCTAssertGreaterThan(shown.r, shown.g, "画出来的是 \(describe(shown))")
        XCTAssertGreaterThan(shown.g, shown.b, "画出来的是 \(describe(shown))")
        XCTAssertGreaterThan(shown.r - shown.b, 20, "钳制后不应被去饱和成灰黑：\(describe(shown))")
    }

    /// 中灰底（p10k 分段底色的典型场景）上的琥珀字：达标的同时必须保持彩色，不允许漂白成接近纯白。
    func test_clamp_on_midgray_keeps_color() async {
        use(dark: false)
        let fg = rgb(0xD7AF87), bg = rgb(0x767676)
        XCTAssertLessThan(contrast(fg, bg), ratio, "前提：原始对比不足")
        let shown = await drawn(fg: fg, on: bg)
        XCTAssertGreaterThanOrEqual(contrast(shown, bg), ratio - 0.15, "画出来的是 \(describe(shown))")
        XCTAssertGreaterThan(shown.r - shown.b, 12, "中灰底上不应被漂白成白色：\(describe(shown))")
    }

    // MARK: 装饰字形也钳制

    /// 装饰字形（盒线 / 块元素 / powerline）不豁免——远端 prompt 按深色背景硬编码的灰色分隔符在浅底上是不可读的灰块，
    /// 必须和普通文本一样钳制。典型场景：很浅的灰分隔 (#D0D0D0) 在白底上对比 ~1.5，须变深。这里所有用例画的都是块字符，
    /// 这一条另外核「没达标的灰块确实被改了」（官方 Ghostty 对块字符是原样画）。
    func test_decorative_glyph_color_is_clamped_on_light_background() async {
        use(dark: false)
        let separator = rgb(0xD0D0D0), bg = terminalBackground
        XCTAssertLessThan(contrast(separator, bg), ratio, "前提：原始灰对比不足")
        let shown = await drawn(fg: separator)
        XCTAssertFalse(near(shown, separator), "块字符也要钳制，不能原样画：\(describe(shown))")
        XCTAssertGreaterThanOrEqual(contrast(shown, bg), ratio - 0.15)
        XCTAssertLessThan(luminance(shown), luminance(separator), "白底上的灰分隔符应变深可读")
    }

    // MARK: 配置接线

    /// 深 / 浅两套配色都写了最低对比度。
    func test_both_schemes_set_the_minimum_contrast_ratio() {
        for configuration in [GhosttyTerminalConfig.theme().light, GhosttyTerminalConfig.theme().dark] {
            let lines = configuration.rendered.split(separator: "\n").filter { $0.hasPrefix("minimum-contrast = ") }
            XCTAssertEqual(lines.count, 1)
            XCTAssertEqual(lines.first.flatMap { Double($0.dropFirst("minimum-contrast = ".count)) },
                           Double(uTerm.TerminalColorScheme.minimumContrastRatio))
        }
        // 3.0 = WCAG 大字号 / UI 组件 AA 下限（方向按背景判定，深 / 中灰段底统一提亮）
        XCTAssertEqual(uTerm.TerminalColorScheme.minimumContrastRatio, 3.0)
    }

    // MARK: 浅色方案的黄（原来在 TerminalColorSchemeTests 里核算法，现在要读像素，挪到这里）

    /// 黄字的逐 cell 可读性由渲染期钳制兜底：白底 / 浅灰段底 / 深灰段底（powerline 常用 ANSI 15 / 8 当段底）上
    /// 钳后都必须达到最低对比度。
    func test_vscode_light_yellow_readable_after_contrast_clamp() async {
        use(dark: false)
        let scheme = uTerm.TerminalColorScheme.resolve(dark: false)
        func rgb(_ c: TerminalRGB) -> RGB { (Int(c.red), Int(c.green), Int(c.blue)) }
        let yellow = rgb(scheme.ansiColors[3])
        for bg in [nil, rgb(scheme.ansiColors[15]), rgb(scheme.ansiColors[8])] as [RGB?] {
            let shown = await drawn(fg: yellow, on: bg)
            let cell = bg ?? terminalBackground
            XCTAssertGreaterThanOrEqual(contrast(shown, cell), ratio - 0.15,
                                        "\(describe(cell)) 上的黄画成了 \(describe(shown))")
        }
    }

    /// 2026-06-13 回归：深灰段底上的黄必须往亮处钳（保持「亮字配深底」），不允许往暗处修成暗橄榄。
    func test_vscode_light_yellow_brightens_on_dark_segment() async {
        use(dark: false)
        let scheme = uTerm.TerminalColorScheme.resolve(dark: false)
        let yellow: RGB = (Int(scheme.ansiColors[3].red), Int(scheme.ansiColors[3].green), Int(scheme.ansiColors[3].blue))
        let segment: RGB = (Int(scheme.ansiColors[8].red), Int(scheme.ansiColors[8].green), Int(scheme.ansiColors[8].blue))
        let shown = await drawn(fg: yellow, on: segment)
        XCTAssertGreaterThan(luminance(shown), luminance(yellow), "深灰段底上的黄应该被提亮而不是压暗：\(describe(shown))")
    }
}
