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

    // MARK: 5 个预定义 scheme

    static let vscodeDark = TerminalColorScheme(
        id: .vscodeDark, displayName: "VS Code Dark",
        backgroundColor: NSColor(srgbRed: 0x1E/255, green: 0x1E/255, blue: 0x1E/255, alpha: 1),
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

    static let tokyoNight = TerminalColorScheme(
        id: .tokyoNight, displayName: "Tokyo Night",
        backgroundColor: NSColor(srgbRed: 0x1A/255, green: 0x1B/255, blue: 0x26/255, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0xC0/255, green: 0xCA/255, blue: 0xF5/255, alpha: 1),
        accentColor: NSColor(srgbRed: 0x7A/255, green: 0xA2/255, blue: 0xF7/255, alpha: 1),
        cursorColor: NSColor(srgbRed: 0xAE/255, green: 0xAF/255, blue: 0xAD/255, alpha: 1),
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
        cursorColor: NSColor(srgbRed: 0xAE/255, green: 0xAF/255, blue: 0xAD/255, alpha: 1),
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
        cursorColor: NSColor(srgbRed: 0xAE/255, green: 0xAF/255, blue: 0xAD/255, alpha: 1),
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
        cursorColor: NSColor(srgbRed: 0xAE/255, green: 0xAF/255, blue: 0xAD/255, alpha: 1),
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

    // MARK: 5 套浅色姊妹（官方 Light 版）

    /// VS Code Light Modern 终端色。源：microsoft/vscode 内置主题。
    static let vscodeLight = TerminalColorScheme(
        id: .vscodeDark, displayName: "VS Code Light",
        backgroundColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0x3B/255, green: 0x3B/255, blue: 0x3B/255, alpha: 1),
        accentColor: NSColor(srgbRed: 0x00/255, green: 0x5F/255, blue: 0xB8/255, alpha: 1),
        cursorColor: NSColor(srgbRed: 0x3B/255, green: 0x3B/255, blue: 0x3B/255, alpha: 1),
        ansiColors: makeAnsi(
            normals: [(0x00,0x00,0x00),(0xCD,0x31,0x31),(0x00,0xBC,0x00),(0x94,0x98,0x00),
                      (0x04,0x51,0xA5),(0xBC,0x05,0xBC),(0x05,0x98,0xBC),(0x55,0x55,0x55)],
            brights: [(0x66,0x66,0x66),(0xCD,0x31,0x31),(0x14,0xCE,0x14),(0xB5,0xBA,0x00),
                      (0x04,0x51,0xA5),(0xBC,0x05,0xBC),(0x05,0x98,0xBC),(0xA5,0xA5,0xA5)])
    )

    /// Tokyo Night Day。源：folke/tokyonight.nvim（tokyonight-day）。
    static let tokyoNightDay = TerminalColorScheme(
        id: .tokyoNight, displayName: "Tokyo Night Day",
        backgroundColor: NSColor(srgbRed: 0xE1/255, green: 0xE2/255, blue: 0xE7/255, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0x37/255, green: 0x60/255, blue: 0xBF/255, alpha: 1),
        accentColor: NSColor(srgbRed: 0x2E/255, green: 0x7D/255, blue: 0xE9/255, alpha: 1),
        cursorColor: NSColor(srgbRed: 0x37/255, green: 0x60/255, blue: 0xBF/255, alpha: 1),
        ansiColors: makeAnsi(
            normals: [(0xB4,0xB5,0xB9),(0xF5,0x2A,0x65),(0x58,0x75,0x39),(0x8C,0x6C,0x3E),
                      (0x2E,0x7D,0xE9),(0x98,0x54,0xF1),(0x00,0x71,0x97),(0x61,0x72,0xB0)],
            brights: [(0xA1,0xA6,0xC5),(0xF5,0x2A,0x65),(0x58,0x75,0x39),(0x8C,0x6C,0x3E),
                      (0x2E,0x7D,0xE9),(0x98,0x54,0xF1),(0x00,0x71,0x97),(0x37,0x60,0xBF)])
    )

    /// Solarized Light。源：altercation/solarized（base3 底 / base00 字）。
    static let solarizedLight = TerminalColorScheme(
        id: .solarized, displayName: "Solarized Light",
        backgroundColor: NSColor(srgbRed: 0xFD/255, green: 0xF6/255, blue: 0xE3/255, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0x65/255, green: 0x7B/255, blue: 0x83/255, alpha: 1),
        accentColor: NSColor(srgbRed: 0x26/255, green: 0x8B/255, blue: 0xD2/255, alpha: 1),
        cursorColor: NSColor(srgbRed: 0x65/255, green: 0x7B/255, blue: 0x83/255, alpha: 1),
        ansiColors: makeAnsi(
            normals: [(0x07,0x36,0x42),(0xDC,0x32,0x2F),(0x85,0x99,0x00),(0xB5,0x89,0x00),
                      (0x26,0x8B,0xD2),(0xD3,0x36,0x82),(0x2A,0xA1,0x98),(0xEE,0xE8,0xD5)],
            brights: [(0x00,0x2B,0x36),(0xCB,0x4B,0x16),(0x58,0x6E,0x75),(0x65,0x7B,0x83),
                      (0x83,0x94,0x96),(0x6C,0x71,0xC4),(0x93,0xA1,0xA1),(0xFD,0xF6,0xE3)])
    )

    /// Gruvbox Light（medium）。源：morhetz/gruvbox。
    static let gruvboxLight = TerminalColorScheme(
        id: .gruvbox, displayName: "Gruvbox Light",
        backgroundColor: NSColor(srgbRed: 0xFB/255, green: 0xF1/255, blue: 0xC7/255, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0x3C/255, green: 0x38/255, blue: 0x36/255, alpha: 1),
        accentColor: NSColor(srgbRed: 0xB5/255, green: 0x76/255, blue: 0x14/255, alpha: 1),
        cursorColor: NSColor(srgbRed: 0x3C/255, green: 0x38/255, blue: 0x36/255, alpha: 1),
        ansiColors: makeAnsi(
            normals: [(0xFB,0xF1,0xC7),(0xCC,0x24,0x1D),(0x98,0x97,0x1A),(0xD7,0x99,0x21),
                      (0x45,0x85,0x88),(0xB1,0x62,0x86),(0x68,0x9D,0x6A),(0x7C,0x6F,0x64)],
            brights: [(0x92,0x83,0x74),(0x9D,0x00,0x06),(0x79,0x74,0x0E),(0xB5,0x76,0x14),
                      (0x07,0x66,0x78),(0x8F,0x3F,0x71),(0x42,0x7B,0x58),(0x3C,0x38,0x36)])
    )

    /// Atom One Light。源：atom/one-light-syntax。
    static let oneLight = TerminalColorScheme(
        id: .oneDark, displayName: "One Light",
        backgroundColor: NSColor(srgbRed: 0xFA/255, green: 0xFA/255, blue: 0xFA/255, alpha: 1),
        foregroundColor: NSColor(srgbRed: 0x38/255, green: 0x3A/255, blue: 0x42/255, alpha: 1),
        accentColor: NSColor(srgbRed: 0x40/255, green: 0x78/255, blue: 0xF2/255, alpha: 1),
        cursorColor: NSColor(srgbRed: 0x38/255, green: 0x3A/255, blue: 0x42/255, alpha: 1),
        ansiColors: makeAnsi(
            normals: [(0x00,0x00,0x00),(0xE4,0x56,0x49),(0x50,0xA1,0x4F),(0xC1,0x84,0x01),
                      (0x40,0x78,0xF2),(0xA6,0x26,0xA4),(0x01,0x84,0xBC),(0xA0,0xA1,0xA7)],
            brights: [(0x5C,0x63,0x70),(0xE4,0x56,0x49),(0x50,0xA1,0x4F),(0x98,0x68,0x01),
                      (0x40,0x78,0xF2),(0xA6,0x26,0xA4),(0x01,0x84,0xBC),(0x38,0x3A,0x42)])
    )

    static let all: [TerminalColorScheme] = [.vscodeDark, .tokyoNight, .solarized, .gruvbox, .oneDark]

    static func scheme(for id: TerminalColorSchemeID) -> TerminalColorScheme {
        all.first { $0.id == id } ?? .vscodeDark
    }

    /// 按 app 外观解析家族的深 / 浅变体。dark=true 返回深色姊妹，false 返回浅色姊妹。
    static func resolve(_ id: TerminalColorSchemeID, dark: Bool) -> TerminalColorScheme {
        switch id {
        case .vscodeDark: return dark ? .vscodeDark : .vscodeLight
        case .tokyoNight: return dark ? .tokyoNight : .tokyoNightDay
        case .solarized:  return dark ? .solarized  : .solarizedLight
        case .gruvbox:    return dark ? .gruvbox    : .gruvboxLight
        case .oneDark:    return dark ? .oneDark    : .oneLight
        }
    }
}
