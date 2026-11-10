import GhosttyTerminal
import UIKit

/// uTerm 的配色（`TerminalColorScheme`）→ Ghostty 配置。
enum GhosttyPalette {
    /// 一份配色：底色、前景、16 色、光标（块光标下的字用终端底色）、选区。
    static func colors(_ scheme: TerminalColorScheme) -> GhosttyTerminal.TerminalConfiguration {
        GhosttyTerminal.TerminalConfiguration { builder in
            let background = hex(scheme.backgroundColor)
            builder.withBackground(background)
            builder.withForeground(hex(scheme.foregroundColor))
            for (index, color) in scheme.ansiColors.prefix(16).enumerated() {
                builder.withPalette(index, color: color.hex)
            }
            builder.withCursorColor(hex(scheme.cursorColor))
            builder.withCursorText(background)
            builder.withSelectionBackground(hex(scheme.selectionColor, over: scheme.backgroundColor))
            builder.withSelectionForeground(hex(scheme.foregroundColor))
        }
    }

    static func rgb(_ color: UIColor) -> (UInt8, UInt8, UInt8) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ value: CGFloat) -> UInt8 { UInt8(max(0, min(255, Int(value * 255 + 0.5)))) }
        return (byte(r), byte(g), byte(b))
    }

    /// `over` 给了就按透明度合成到它上面（Ghostty 的颜色值不带 alpha）。
    static func hex(_ color: UIColor, over base: UIColor? = nil) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        if let base, a < 1 {
            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            r = r * a + br * (1 - a); g = g * a + bg * (1 - a); b = b * a + bb * (1 - a)
        }
        return String(format: "#%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))
    }
}
