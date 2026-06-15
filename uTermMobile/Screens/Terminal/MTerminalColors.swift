import SwiftUI
import SwiftTerm
import UIKit

/// iOS 终端配色（对齐 macOS `TerminalColorScheme`：VS Code Dark / Light）。
/// 背景 / 前景 / 光标 / 选区 + 16 色 ANSI 表，按 app 外观取深 / 浅。
/// 日间终端为白底（设计稿 `--u-term-bg:#ffffff`），暗夜为 #101012。
nonisolated struct MTerminalColors: @unchecked Sendable {
    let background: UIColor
    let foreground: UIColor
    let cursor: UIColor
    let selection: UIColor
    let ansi: [SwiftTerm.Color]   // 16：0-7 normal、8-15 bright

    /// 渲染期最低对比度（对齐 macOS / VS Code `minimumContrastRatio`）：服务器端按深色
    /// 背景硬编码的 256 / 真彩色 prompt 不走 16 色表，靠渲染期钳制保证浅底可读。
    static let minimumContrastRatio: CGFloat = 3.0

    nonisolated static func resolve(dark: Bool) -> MTerminalColors { dark ? .vscodeDark : .vscodeLight }
    /// 终端区域的 SwiftUI 背景色（头部 / 键盘条之外的留白随终端底色）。
    nonisolated static func background(dark: Bool) -> SwiftUI.Color {
        SwiftUI.Color(uiColor: resolve(dark: dark).background)
    }

    // MARK: 构造助手
    nonisolated private static func a(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }
    /// bright (8-15) = normal × 0.7 + white × 0.3（对齐 macOS lightenForBright）。
    nonisolated private static func bright(_ c: SwiftTerm.Color) -> SwiftTerm.Color {
        let f: (UInt16) -> UInt16 = { v in UInt16((UInt32(v) * 7 + UInt32(0xFFFF) * 3) / 10) }
        return SwiftTerm.Color(red: f(c.red), green: f(c.green), blue: f(c.blue))
    }
    nonisolated private static func ui(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    nonisolated static let vscodeDark: MTerminalColors = {
        let n = [a(0, 0, 0), a(0xF1, 0x4C, 0x4C), a(0x73, 0xC9, 0x91), a(0xE2, 0xC0, 0x8D),
                 a(0x5C, 0xC8, 0xFF), a(0xC5, 0x86, 0xC0), a(0x56, 0xB6, 0xC2), a(0xCC, 0xCC, 0xCC)]
        return MTerminalColors(background: ui(0x10, 0x10, 0x12), foreground: ui(0xD4, 0xD4, 0xD4),
                               cursor: ui(0xAE, 0xAF, 0xAD), selection: ui(0x26, 0x4F, 0x78),
                               ansi: n + n.map(bright))
    }()

    nonisolated static let vscodeLight: MTerminalColors = {
        let n = [a(0, 0, 0), a(0xCD, 0x31, 0x31), a(0x00, 0xBC, 0x00), a(0x94, 0x98, 0x00),
                 a(0x04, 0x51, 0xA5), a(0xBC, 0x05, 0xBC), a(0x05, 0x98, 0xBC), a(0x55, 0x55, 0x55)]
        let b = [a(0x66, 0x66, 0x66), a(0xCD, 0x31, 0x31), a(0x14, 0xCE, 0x14), a(0xB5, 0xBA, 0x00),
                 a(0x04, 0x51, 0xA5), a(0xBC, 0x05, 0xBC), a(0x05, 0x98, 0xBC), a(0xA5, 0xA5, 0xA5)]
        return MTerminalColors(background: ui(0xFF, 0xFF, 0xFF), foreground: ui(0x3B, 0x3B, 0x3B),
                               cursor: ui(0x3B, 0x3B, 0x3B), selection: ui(0xAD, 0xD6, 0xFF),
                               ansi: n + b)
    }()
}
