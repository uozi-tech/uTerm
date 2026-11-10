import GhosttyTerminal

/// `TerminalKeyCatalog` → GhosttyKit 按键。只映射「按键」，符号与提示词照旧当文字发。
///
/// 走按键而不是直接发目录里的字节，是为了让终端按当前模式编码：程序开了应用光标键（DECCKM，vim / less / htop）时方向键
/// 要发 `ESC O A` 而不是 `ESC [ A`，开了 kitty 键盘协议时发 CSI u；上膛的 Ctrl / Alt 也由按键路径带上（Ctrl+←）。
enum GhosttyKeyBarMapping {
    static func press(for key: uTermMobile.TerminalKey) -> TerminalKeyPress? {
        switch key.send {
        case "\u{1b}": return TerminalKeyPress(.escape)
        case "\t": return TerminalKeyPress(.tab)
        case "\u{1b}[Z": return TerminalKeyPress(.tab, modifiers: .shift)
        case "\r": return TerminalKeyPress(.enter)
        case "\u{7f}": return TerminalKeyPress(.backspace)
        case "\u{1b}[A": return TerminalKeyPress(.arrowUp)
        case "\u{1b}[B": return TerminalKeyPress(.arrowDown)
        case "\u{1b}[C": return TerminalKeyPress(.arrowRight)
        case "\u{1b}[D": return TerminalKeyPress(.arrowLeft)
        case "\u{1b}[H": return TerminalKeyPress(.home)
        case "\u{1b}[F": return TerminalKeyPress(.end)
        case "\u{1b}[5~": return TerminalKeyPress(.pageUp)
        case "\u{1b}[6~": return TerminalKeyPress(.pageDown)
        case "\u{1b}[3~": return TerminalKeyPress(.delete)
        case "\u{1b}[2~": return TerminalKeyPress(.insert)
        default: break
        }
        if let index = TerminalKeyCatalog.function.firstIndex(of: key) {
            let keys: [GhosttyTerminal.TerminalKey] = [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
            return TerminalKeyPress(keys[index])
        }
        // ^A … ^Z：Ctrl + 字母。
        if let scalar = key.send.unicodeScalars.first, key.send.unicodeScalars.count == 1,
           (1...26).contains(scalar.value),
           let letter = Character(UnicodeScalar(scalar.value + 0x60)!).lowercased().first,
           let press = TerminalKeyPress(typing: letter, modifiers: .ctrl) {
            return press
        }
        return nil
    }
}
