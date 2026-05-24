import SwiftUI
import AppKit
import SwiftTerm

enum TerminalTheme {
    static let backgroundColor = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255, alpha: 1)
    static let foregroundColor = NSColor(srgbRed: 0xCC / 255, green: 0xCC / 255, blue: 0xCC / 255, alpha: 1)
    /// VS Code Dark+ `terminalCursor.foreground` (#AEAFAD). Used for the
    /// caret block fill; pairs with `backgroundColor` as the glyph color so
    /// the character under the solid block stays readable.
    static let cursorColor = NSColor(srgbRed: 0xAE / 255, green: 0xAF / 255, blue: 0xAD / 255, alpha: 1)

    static func applyDefaults(to view: SwiftTerm.TerminalView) {
        apply(to: view, fontSize: 13, scrollback: 3_000)
    }

    static func apply(to view: SwiftTerm.TerminalView, fontSize: CGFloat, scrollback: Int) {
        applyFont(to: view, fontSize: fontSize)
        applyScrollback(to: view, scrollback: scrollback)

        // VS Code Dark+ background/foreground/selection
        view.nativeBackgroundColor = backgroundColor
        view.nativeForegroundColor = foregroundColor
        view.selectedTextBackgroundColor = normalSelectionColor
        applyCursor(to: view)

        view.installColors(vscodeDarkPlus)

        // Round only the visual bottom corners (where the terminal meets the
        // pane's outer rounded bottom). Top corners stay straight to butt
        // flush against the header. `.layerMinXMinYCorner` / `.layerMaxXMinYCorner`
        // refer to the layer's MIN-Y edge, which on a non-flipped NSView layer
        // is the visual bottom.
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer?.masksToBounds = true
    }

    static func applyFont(to view: SwiftTerm.TerminalView, fontSize: CGFloat) {
        // Match VS Code's default on macOS: Menlo, fallback to system mono if
        // Menlo somehow isn't available (it's bundled since 10.6).
        let font = NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if view.font != font {
            view.font = font
        }
    }

    /// Match VS Code's integrated terminal default: steady (non-blinking)
    /// block painted with `terminalCursor.foreground` (#AEAFAD). SwiftTerm
    /// defaults to `.blinkBlock` and an unset `caretColor` that reads as the
    /// system text-cursor blue. The DECSCUSR `ESC [ 2 SP q` switches the
    /// caret to steady block — the same sequence shells emit to opt out of
    /// blinking — and `caretTextColor` keeps the glyph under the solid
    /// block readable against the light fill. `caretViewTracksFocus` stays
    /// at its default `true` so an unfocused pane shows a hollow outline,
    /// also matching VS Code's behaviour.
    static func applyCursor(to view: SwiftTerm.TerminalView) {
        view.caretColor = cursorColor
        view.caretTextColor = backgroundColor
        // `feed` on a fresh TerminalView is safe — the underlying Terminal
        // is constructed during `super.init` before this is called.
        view.feed(text: "\u{1B}[2 q")
    }

    static func applyScrollback(to view: SwiftTerm.TerminalView, scrollback: Int) {
        guard let terminal = view.terminal else { return }
        let target = max(0, scrollback)
        if terminal.options.scrollback != target {
            terminal.changeScrollback(target > 0 ? target : nil)
        }
    }

    /// Subtle blue overlay used for normal mouse-drag selections.
    static let normalSelectionColor = NSColor(srgbRed: 0x26 / 255, green: 0x4F / 255, blue: 0x78 / 255, alpha: 0.5)

    /// Bright amber overlay used while a search overlay is open so the active
    /// match is unmistakable against any cell background. Mirrors VS Code's
    /// `terminal.findMatchBackground` (`#A07D27`).
    static let searchMatchColor = NSColor(srgbRed: 0xF1 / 255, green: 0xB5 / 255, blue: 0x3C / 255, alpha: 0.6)

    private static func ansi(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }

    static let vscodeDarkPlus: [SwiftTerm.Color] = [
        ansi(0x00, 0x00, 0x00), // black
        ansi(0xCD, 0x31, 0x31), // red
        ansi(0x0D, 0xBC, 0x79), // green
        ansi(0xE5, 0xE5, 0x10), // yellow
        ansi(0x24, 0x72, 0xC8), // blue
        ansi(0xBC, 0x3F, 0xBC), // magenta
        ansi(0x11, 0xA8, 0xCD), // cyan
        ansi(0xE5, 0xE5, 0xE5), // white
        ansi(0x66, 0x66, 0x66), // bright black
        ansi(0xF1, 0x4C, 0x4C), // bright red
        ansi(0x23, 0xD1, 0x8B), // bright green
        ansi(0xF5, 0xF5, 0x43), // bright yellow
        ansi(0x3B, 0x8E, 0xEA), // bright blue
        ansi(0xD6, 0x70, 0xD6), // bright magenta
        ansi(0x29, 0xB8, 0xDB), // bright cyan
        ansi(0xE5, 0xE5, 0xE5), // bright white
    ]
}
