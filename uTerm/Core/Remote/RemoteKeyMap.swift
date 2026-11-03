import Foundation

/// 手机上的按键 → Mac 虚拟键码（`kVK_*`，Carbon `Events.h` 里的值，这里直接写数字：iOS 没有 Carbon）。
///
/// 两条来路：
/// - iPad 外接键盘：`UIKey.keyCode` 是 HID usage（键盘页 0x07），按物理位置映射，与键盘布局无关。
/// - 软键盘 + 修饰键条上膛（⌘C、⌃A……）：拿到的只是字符，按 **US 布局**反查是哪个键、要不要 Shift。
///   不带修饰的普通文字不走这里，直接按 Unicode 注入（见 `RemoteDesktopInput.text`）。
nonisolated enum RemoteKeyMap {
    enum Key {
        static let returnKey: UInt16 = 0x24
        static let tab: UInt16 = 0x30
        static let space: UInt16 = 0x31
        static let delete: UInt16 = 0x33
        static let escape: UInt16 = 0x35
        static let forwardDelete: UInt16 = 0x75
        static let home: UInt16 = 0x73
        static let end: UInt16 = 0x77
        static let pageUp: UInt16 = 0x74
        static let pageDown: UInt16 = 0x79
        static let left: UInt16 = 0x7B
        static let right: UInt16 = 0x7C
        static let down: UInt16 = 0x7D
        static let up: UInt16 = 0x7E
        /// 粘贴（⌘V）用。
        static let v: UInt16 = 0x09
        /// F1–F12。
        static let function: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
    }

    /// HID usage → kVK。修饰键本身（0xE0–0xE7）不在表里：修饰状态随每个按键的 `modifiers` 一起发。
    static func keyCode(hidUsage usage: Int) -> UInt16? {
        hidTable[usage]
    }

    /// 字符 → (kVK, 是否需要 Shift)，US 布局。大写字母 = 小写那个键 + Shift。
    static func keyCode(for character: Character) -> (code: UInt16, shift: Bool)? {
        if let entry = characterTable[character] { return entry }
        let lower = Character(character.lowercased())
        if lower != character, let entry = characterTable[lower], !entry.shift {
            return (entry.code, true)
        }
        return nil
    }

    private static let letters: [(Character, UInt16)] = [
        ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05), ("z", 0x06), ("x", 0x07),
        ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D), ("e", 0x0E), ("r", 0x0F), ("y", 0x10),
        ("t", 0x11), ("o", 0x1F), ("u", 0x20), ("i", 0x22), ("p", 0x23), ("l", 0x25), ("j", 0x26), ("k", 0x28),
        ("n", 0x2D), ("m", 0x2E),
    ]

    /// US 布局：未按 Shift 的字符 / 按住 Shift 的字符 / 键码。
    private static let symbols: [(Character, Character, UInt16)] = [
        ("1", "!", 0x12), ("2", "@", 0x13), ("3", "#", 0x14), ("4", "$", 0x15), ("5", "%", 0x17),
        ("6", "^", 0x16), ("7", "&", 0x1A), ("8", "*", 0x1C), ("9", "(", 0x19), ("0", ")", 0x1D),
        ("-", "_", 0x1B), ("=", "+", 0x18), ("[", "{", 0x21), ("]", "}", 0x1E), ("\\", "|", 0x2A),
        (";", ":", 0x29), ("'", "\"", 0x27), (",", "<", 0x2B), (".", ">", 0x2F), ("/", "?", 0x2C),
        ("`", "~", 0x32),
    ]

    private static let characterTable: [Character: (code: UInt16, shift: Bool)] = {
        var table: [Character: (code: UInt16, shift: Bool)] = [:]
        for (char, code) in letters { table[char] = (code, false) }
        for (plain, shifted, code) in symbols {
            table[plain] = (code, false)
            table[shifted] = (code, true)
        }
        table[" "] = (Key.space, false)
        table["\t"] = (Key.tab, false)
        table["\n"] = (Key.returnKey, false)
        table["\r"] = (Key.returnKey, false)
        return table
    }()

    private static let hidTable: [Int: UInt16] = {
        var table: [Int: UInt16] = [:]
        // a–z：HID 0x04…0x1D 按字母序。
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        let letterCodes = Dictionary(uniqueKeysWithValues: letters)
        for (index, char) in alphabet.enumerated() { table[0x04 + index] = letterCodes[char] }
        // 1–9、0：HID 0x1E…0x27。
        let digitCodes: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]
        for (index, code) in digitCodes.enumerated() { table[0x1E + index] = code }
        let fixed: [Int: UInt16] = [
            0x28: Key.returnKey, 0x29: Key.escape, 0x2A: Key.delete, 0x2B: Key.tab, 0x2C: Key.space,
            0x2D: 0x1B, 0x2E: 0x18, 0x2F: 0x21, 0x30: 0x1E, 0x31: 0x2A, 0x32: 0x2A, 0x33: 0x29, 0x34: 0x27,
            0x35: 0x32, 0x36: 0x2B, 0x37: 0x2F, 0x38: 0x2C, 0x39: 0x39,
            0x49: 0x72, 0x4A: Key.home, 0x4B: Key.pageUp, 0x4C: Key.forwardDelete, 0x4D: Key.end,
            0x4E: Key.pageDown, 0x4F: Key.right, 0x50: Key.left, 0x51: Key.down, 0x52: Key.up,
            // 小键盘。
            0x53: 0x47, 0x54: 0x4B, 0x55: 0x43, 0x56: 0x4E, 0x57: 0x45, 0x58: 0x4C,
            0x59: 0x53, 0x5A: 0x54, 0x5B: 0x55, 0x5C: 0x56, 0x5D: 0x57, 0x5E: 0x58, 0x5F: 0x59, 0x60: 0x5B,
            0x61: 0x5C, 0x62: 0x52, 0x63: 0x41, 0x67: 0x51,
            // ISO 键盘左下角多出的那个键。
            0x64: 0x0A,
            // F13–F20。
            0x68: 0x69, 0x69: 0x6B, 0x6A: 0x71, 0x6B: 0x6A, 0x6C: 0x40, 0x6D: 0x4F, 0x6E: 0x50, 0x6F: 0x5A,
        ]
        table.merge(fixed) { _, new in new }
        // F1–F12：HID 0x3A…0x45。
        for (index, code) in Key.function.enumerated() { table[0x3A + index] = code }
        return table
    }()
}
