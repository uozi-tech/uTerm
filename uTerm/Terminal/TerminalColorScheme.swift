import Foundation
import AppKit
import SwiftTerm

/// 终端配色方案 ID。UserDefaults key: `terminalColorScheme`。默认 `.vscodeDark`。
enum TerminalColorSchemeID: String, CaseIterable, Identifiable {
    case vscodeDark = "vscode-dark"
    case tokyoNight = "tokyonight"
    case solarized
    case gruvbox
    case oneDark    = "one-dark"

    var id: String { rawValue }
}

/// 一套完整的终端配色：背景 / 前景 / accent + 16 色 ANSI 表。
/// bright 8-15 由 normal 0-7 经 lighten 公式生成。
struct TerminalColorScheme {
    let id: TerminalColorSchemeID
    let displayName: String
    let backgroundColor: NSColor
    let foregroundColor: NSColor
    let accentColor: NSColor
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

    // MARK: 5 个预定义 scheme

    static let vscodeDark = TerminalColorScheme(
        id: .vscodeDark, displayName: "VS Code Dark",
        backgroundColor: NSColor(srgbRed: 0x1E/255, green: 0x1E/255, blue: 0x1E/255, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0xD4/255, green: 0xD4/255, blue: 0xD4/255, alpha: 1),
        accentColor: NSColor(srgbRed: 0x56/255, green: 0x9C/255, blue: 0xD6/255, alpha: 1),
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

    static let tokyoNight = TerminalColorScheme(
        id: .tokyoNight, displayName: "Tokyo Night",
        backgroundColor: NSColor(srgbRed: 0x1A/255, green: 0x1B/255, blue: 0x26/255, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0xC0/255, green: 0xCA/255, blue: 0xF5/255, alpha: 1),
        accentColor: NSColor(srgbRed: 0x7A/255, green: 0xA2/255, blue: 0xF7/255, alpha: 1),
        ansiColors: makeAnsi(
            black:   (0x1A, 0x1B, 0x26),
            red:     (0xF7, 0x76, 0x8E),
            green:   (0x9E, 0xCE, 0x6A),
            yellow:  (0xE0, 0xAF, 0x68),
            blue:    (0x7A, 0xA2, 0xF7),
            magenta: (0xBB, 0x9A, 0xF7),
            cyan:    (0x7D, 0xCF, 0xFF),
            white:   (0xC0, 0xCA, 0xF5))
    )

    static let solarized = TerminalColorScheme(
        id: .solarized, displayName: "Solarized Dark",
        backgroundColor: NSColor(srgbRed: 0x00/255, green: 0x2B/255, blue: 0x36/255, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0x93/255, green: 0xA1/255, blue: 0xA1/255, alpha: 1),
        accentColor: NSColor(srgbRed: 0x26/255, green: 0x8B/255, blue: 0xD2/255, alpha: 1),
        ansiColors: makeAnsi(
            black:   (0x00, 0x2B, 0x36),
            red:     (0xDC, 0x32, 0x2F),
            green:   (0x85, 0x99, 0x00),
            yellow:  (0xB5, 0x89, 0x00),
            blue:    (0x26, 0x8B, 0xD2),
            magenta: (0xD3, 0x36, 0x82),
            cyan:    (0x2A, 0xA1, 0x98),
            white:   (0x93, 0xA1, 0xA1))
    )

    static let gruvbox = TerminalColorScheme(
        id: .gruvbox, displayName: "Gruvbox Dark",
        backgroundColor: NSColor(srgbRed: 0x28/255, green: 0x28/255, blue: 0x28/255, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0xEB/255, green: 0xDB/255, blue: 0xB2/255, alpha: 1),
        accentColor: NSColor(srgbRed: 0xB8/255, green: 0xBB/255, blue: 0x26/255, alpha: 1),
        ansiColors: makeAnsi(
            black:   (0x28, 0x28, 0x28),
            red:     (0xFB, 0x49, 0x34),
            green:   (0xB8, 0xBB, 0x26),
            yellow:  (0xFA, 0xBD, 0x2F),
            blue:    (0x83, 0xA5, 0x98),
            magenta: (0xD3, 0x86, 0x9B),
            cyan:    (0x8E, 0xC0, 0x7C),
            white:   (0xEB, 0xDB, 0xB2))
    )

    static let oneDark = TerminalColorScheme(
        id: .oneDark, displayName: "One Dark",
        backgroundColor: NSColor(srgbRed: 0x28/255, green: 0x2C/255, blue: 0x34/255, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0xAB/255, green: 0xB2/255, blue: 0xBF/255, alpha: 1),
        accentColor: NSColor(srgbRed: 0x61/255, green: 0xAF/255, blue: 0xEF/255, alpha: 1),
        ansiColors: makeAnsi(
            black:   (0x28, 0x2C, 0x34),
            red:     (0xE0, 0x6C, 0x75),
            green:   (0x98, 0xC3, 0x79),
            yellow:  (0xE5, 0xC0, 0x7B),
            blue:    (0x61, 0xAF, 0xEF),
            magenta: (0xC6, 0x78, 0xDD),
            cyan:    (0x56, 0xB6, 0xC2),
            white:   (0xAB, 0xB2, 0xBF))
    )

    static let all: [TerminalColorScheme] = [.vscodeDark, .tokyoNight, .solarized, .gruvbox, .oneDark]

    static func scheme(for id: TerminalColorSchemeID) -> TerminalColorScheme {
        all.first { $0.id == id } ?? .vscodeDark
    }
}
