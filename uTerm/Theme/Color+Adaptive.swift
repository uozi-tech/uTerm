import SwiftUI
import AppKit

extension Color {
    /// 构造一个跟随 macOS appearance 自动切换 hex 的 `Color`。
    ///
    /// 底层用 `NSColor(name:dynamicProvider:)`，dynamic provider 在每次
    /// `setStroke` / `setFill` / `Color(nsColor:)` resolve 时调用，根据
    /// 当前线程的 `NSAppearance.current` 返回相应 NSColor。SwiftUI 把
    /// 视图 hierarchy 的 `\.colorScheme` 环境值映射到 NSAppearance，
    /// 触发自动重 resolve + 重绘。
    ///
    /// - Parameters:
    ///   - light: aqua (浅色) 下显示的 24-bit RGB hex（0xRRGGBB）。
    ///   - dark:  darkAqua 下显示的 24-bit RGB hex。
    /// - Returns: `Color` 实例，可像任何 `Color` 一样用 `.foregroundStyle(...)` 等。
    nonisolated static func adaptive(light: UInt32, dark: UInt32) -> Color {
        let nsColor = NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua:
                return NSColor(hex: dark)
            default:
                return NSColor(hex: light)
            }
        }
        return Color(nsColor: nsColor)
    }
}

extension NSColor {
    /// 从 24-bit RGB hex 构造 NSColor（sRGB color space, alpha 1.0）。
    /// 与 `Color(hex:)`（`uTerm/Theme/Color+Hex.swift`）语义一致。
    /// 仅供 `Color.adaptive(...)` 内部用——所以 fileprivate 即可。
    fileprivate convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8)  & 0xFF) / 255
        let b = CGFloat(hex         & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
