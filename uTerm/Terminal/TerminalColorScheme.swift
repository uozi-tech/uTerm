import Foundation
import AppKit
import SwiftTerm

/// 一套完整的终端配色：背景 / 前景 / accent + 16 色 ANSI 表。
/// bright 8-15 由 normal 0-7 经 lighten 公式生成。
///
/// 配色不再可自定义：终端固定用 VS Code 家族的前景 / ANSI 色，按 app 外观自动取
/// 深 / 浅变体（`resolve(dark:)`）。深色背景对齐工作区基底。
struct TerminalColorScheme {
    let displayName: String
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let accentColor: NSColor
    /// 光标块填充色（深色方案沿用 VS Code #AEAFAD；浅色方案用深色 caret）。
    let cursorColor: NSColor
    /// 16-色 ANSI palette（0-7 normal, 8-15 bright），按 SwiftTerm.installColors 顺序。
    let ansiColors: [SwiftTerm.Color]

    /// 设计稿提供 8 色（normal 0-7）；bright (8-15) 由 lighten 公式生成：
    ///   bright = normal × 0.7 + white × 0.3
    static func lightenForBright(_ c: SwiftTerm.Color) -> SwiftTerm.Color {
        let blend: (UInt16) -> UInt16 = { v in
            let scaled = UInt32(v) * 7 + UInt32(0xFFFF) * 3
            return UInt16(scaled / 10)
        }
        return SwiftTerm.Color(red: blend(c.red), green: blend(c.green), blue: blend(c.blue))
    }

    private static func ansi(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16(r) * 257,
            green: UInt16(g) * 257,
            blue: UInt16(b) * 257
        )
    }

    private static func makeAnsi(black: (UInt8, UInt8, UInt8),
                                  red: (UInt8, UInt8, UInt8),
                                  green: (UInt8, UInt8, UInt8),
                                  yellow: (UInt8, UInt8, UInt8),
                                  blue: (UInt8, UInt8, UInt8),
                                  magenta: (UInt8, UInt8, UInt8),
                                  cyan: (UInt8, UInt8, UInt8),
                                  white: (UInt8, UInt8, UInt8)) -> [SwiftTerm.Color] {
        let normals = [black, red, green, yellow, blue, magenta, cyan, white].map { ansi($0.0, $0.1, $0.2) }
        let brights = normals.map { lightenForBright($0) }
        return normals + brights
    }

    /// 显式 16 色（normal 0-7 + bright 8-15）。浅色方案用，brights 取官方值。
    private static func makeAnsi(normals: [(UInt8, UInt8, UInt8)],
                                 brights: [(UInt8, UInt8, UInt8)]) -> [SwiftTerm.Color] {
        (normals + brights).map { ansi($0.0, $0.1, $0.2) }
    }

    // MARK: VS Code 深 / 浅

    static let vscodeDark = TerminalColorScheme(
        displayName: "VS Code Dark",
        backgroundColor: NSColor(srgbRed: 0x10/255, green: 0x10/255, blue: 0x12/255, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0xD4/255, green: 0xD4/255, blue: 0xD4/255, alpha: 1),
        accentColor: NSColor(srgbRed: 0x56/255, green: 0x9C/255, blue: 0xD6/255, alpha: 1),
        cursorColor: NSColor(srgbRed: 0xAE/255, green: 0xAF/255, blue: 0xAD/255, alpha: 1),
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

    /// VS Code Light Modern 终端色。源：microsoft/vscode 内置主题。
    /// yellow/brightYellow 在浅色提示符灰底上太浅，改为更深的琥珀色以保证可读性。
    static let vscodeLight = TerminalColorScheme(
        displayName: "VS Code Light",
        backgroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0x3B/255, green: 0x3B/255, blue: 0x3B/255, alpha: 1),
        accentColor: NSColor(srgbRed: 0x00/255, green: 0x5F/255, blue: 0xB8/255, alpha: 1),
        cursorColor: NSColor(srgbRed: 0x3B/255, green: 0x3B/255, blue: 0x3B/255, alpha: 1),
        ansiColors: makeAnsi(
            normals: [(0x00,0x00,0x00),(0xCD,0x31,0x31),(0x00,0xBC,0x00),(0x3F,0x32,0x00),
                      (0x04,0x51,0xA5),(0xBC,0x05,0xBC),(0x05,0x98,0xBC),(0x55,0x55,0x55)],
            brights: [(0x66,0x66,0x66),(0xCD,0x31,0x31),(0x14,0xCE,0x14),(0x3F,0x32,0x00),
                      (0x04,0x51,0xA5),(0xBC,0x05,0xBC),(0x05,0x98,0xBC),(0xA5,0xA5,0xA5)])
    )

    /// 按 app 外观取深 / 浅变体。dark=true 返回 VS Code Dark，false 返回 VS Code Light。
    static func resolve(dark: Bool) -> TerminalColorScheme {
        dark ? .vscodeDark : .vscodeLight
    }
}
