import Foundation
#if canImport(AppKit)
import AppKit
/// 终端配色用的平台颜色类型：macOS `NSColor` / iOS `UIColor`。
typealias TerminalPlatformColor = NSColor
#else
import UIKit
typealias TerminalPlatformColor = UIColor
#endif

/// ANSI 调色板里的一个颜色（sRGB，每通道 8 位）。
nonisolated struct TerminalRGB: Equatable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    /// `#RRGGBB`，Ghostty 配置里颜色的写法。
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    var components: (UInt8, UInt8, UInt8) { (red, green, blue) }

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 平台颜色（按 sRGB 取分量，四舍五入到 8 位）。透明度不管：终端配色都是不透明的。
    init(_ color: TerminalPlatformColor) {
        #if canImport(AppKit)
        let c = color.usingColorSpace(.sRGB) ?? color
        let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        func byte(_ value: CGFloat) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
        self.init(red: byte(r), green: byte(g), blue: byte(b))
    }
}

/// 一套完整的终端配色：背景 / 前景 / accent + 16 色 ANSI 表。
/// bright 8-15 由 normal 0-7 经 lighten 公式生成。
///
/// 配色不再可自定义：终端固定用 VS Code 家族的前景 / ANSI 色，按 app 外观自动取
/// 深 / 浅变体（`resolve(dark:)`）。深色背景对齐工作区基底。
///
/// macOS 与 iOS 共用这一份表；翻成 Ghostty 的配置在 `TerminalGhosttyConfig.colors`（两端共用）。
nonisolated struct TerminalColorScheme: @unchecked Sendable {
    /// 渲染期最低 WCAG 对比度（VS Code `minimumContrastRatio` 同思路）。远端
    /// prompt / TUI（p10k 等）常按深色背景硬编码 256 色 / 真彩色，不经过下面的
    /// 16 色 ANSI 表——浅色背景下唯一可靠的解法是渲染时钳制前景色（Ghostty 的
    /// `minimum-contrast` + 引擎补丁 0022：保色相、只调明度）。
    ///
    /// 取 3.0（WCAG 大字号 / UI 组件 AA 下限）而非 VS Code 的 4.5：钳制是
    /// 保色相的（OKLCH 只调明度），但 4.5 在中灰底上数学上只有逼近纯黑 / 纯白
    /// 才达标，色彩会被洗掉；3.0 在可读性与还原 prompt 配色之间取平衡。
    static let minimumContrastRatio: CGFloat = 3.0

    let displayName: String
    let backgroundColor: TerminalPlatformColor
    let foregroundColor: TerminalPlatformColor
    let accentColor: TerminalPlatformColor
    /// 光标块填充色（深色方案沿用 VS Code #AEAFAD；浅色方案用深色 caret）。
    let cursorColor: TerminalPlatformColor
    /// 选区底色：与编辑器同用 VS Code 选区蓝（深 #264F78 / 浅 #ADD6FF，同 `EditorTheme.selectionBg`），
    /// 保证选中文字在两种底上都可读。
    let selectionColor: TerminalPlatformColor
    /// 16 色 ANSI 调色板（0-7 normal, 8-15 bright）。
    let ansiColors: [TerminalRGB]

    /// 设计稿提供 8 色（normal 0-7）；bright (8-15) 由 lighten 公式生成：
    ///   bright = normal × 0.7 + white × 0.3
    static func lightenForBright(_ c: TerminalRGB) -> TerminalRGB {
        let blend: (UInt8) -> UInt8 = { v in
            UInt8((UInt32(v) * 7 + UInt32(0xFF) * 3) / 10)
        }
        return TerminalRGB(red: blend(c.red), green: blend(c.green), blue: blend(c.blue))
    }

    /// sRGB 0xRRGGBB → 平台颜色。
    private static func rgb(_ hex: UInt32) -> TerminalPlatformColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        #if canImport(AppKit)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        #else
        return UIColor(red: r, green: g, blue: b, alpha: 1)
        #endif
    }

    private static func ansi(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> TerminalRGB {
        TerminalRGB(red: r, green: g, blue: b)
    }

    private static func makeAnsi(black: (UInt8, UInt8, UInt8),
                                  red: (UInt8, UInt8, UInt8),
                                  green: (UInt8, UInt8, UInt8),
                                  yellow: (UInt8, UInt8, UInt8),
                                  blue: (UInt8, UInt8, UInt8),
                                  magenta: (UInt8, UInt8, UInt8),
                                  cyan: (UInt8, UInt8, UInt8),
                                  white: (UInt8, UInt8, UInt8)) -> [TerminalRGB] {
        let normals = [black, red, green, yellow, blue, magenta, cyan, white].map { ansi($0.0, $0.1, $0.2) }
        let brights = normals.map { lightenForBright($0) }
        return normals + brights
    }

    /// 显式 16 色（normal 0-7 + bright 8-15）。浅色方案用，brights 取官方值。
    private static func makeAnsi(normals: [(UInt8, UInt8, UInt8)],
                                 brights: [(UInt8, UInt8, UInt8)]) -> [TerminalRGB] {
        (normals + brights).map { ansi($0.0, $0.1, $0.2) }
    }

    // MARK: VS Code 深 / 浅

    static let vscodeDark = TerminalColorScheme(
        displayName: "VS Code Dark",
        // 暗夜终端底 = 卡面色 #141414（UD.panel）：终端坐在工作区内容卡的凹槽里，纯黑会成一块
        // 黑洞、四角还露出卡面色的圆角帽（实机反馈「终端背景不用纯黑」）。与日间「白终端 = 白卡」同理。
        backgroundColor: rgb(0x141414),
        foregroundColor: rgb(0xD4D4D4),
        accentColor: rgb(0x569CD6),
        cursorColor: rgb(0xAEAFAD),
        selectionColor: rgb(0x264F78),
        ansiColors: makeAnsi(
            black:   (0x00, 0x00, 0x00),
            red:     (0xF1, 0x4C, 0x4C),
            green:   (0x73, 0xC9, 0x91),
            yellow:  (0xE2, 0xC0, 0x8D),
            blue:    (0x5C, 0xC8, 0xFF),
            magenta: (0xC5, 0x86, 0xC0),
            cyan:    (0x56, 0xB6, 0xC2),
            white:   (0xCC, 0xCC, 0xCC))
    )

    /// VS Code Light Modern 终端色。源：microsoft/vscode 内置主题，官方原值。
    /// 不要为「某种段底可读」改暗单个颜色（曾把 yellow 写死成 #3F3200）：palette
    /// 是全局的，深灰段底上起点过暗的黄会被对比度钳制往更暗方向修成暗橄榄。
    /// 逐 cell 可读性由渲染期 minimumContrastRatio 兜底——浅灰段底上压暗、
    /// 深灰段底上提亮，两种方向都正确。
    static let vscodeLight = TerminalColorScheme(
        displayName: "VS Code Light",
        backgroundColor: rgb(0xFFFFFF),
        foregroundColor: rgb(0x3B3B3B),
        accentColor: rgb(0x005FB8),
        cursorColor: rgb(0x3B3B3B),
        selectionColor: rgb(0xADD6FF),
        ansiColors: makeAnsi(
            normals: [(0x00,0x00,0x00),(0xCD,0x31,0x31),(0x00,0xBC,0x00),(0x94,0x98,0x00),
                      (0x04,0x51,0xA5),(0xBC,0x05,0xBC),(0x05,0x98,0xBC),(0x55,0x55,0x55)],
            brights: [(0x66,0x66,0x66),(0xCD,0x31,0x31),(0x14,0xCE,0x14),(0xB5,0xBA,0x00),
                      (0x04,0x51,0xA5),(0xBC,0x05,0xBC),(0x05,0x98,0xBC),(0xA5,0xA5,0xA5)])
    )

    /// 按 app 外观取深 / 浅变体。dark=true 返回 VS Code Dark，false 返回 VS Code Light。
    static func resolve(dark: Bool) -> TerminalColorScheme {
        dark ? .vscodeDark : .vscodeLight
    }
}
