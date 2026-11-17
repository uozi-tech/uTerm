import Foundation

/// 定长数字码输入（配对码、设备组的加入码）两端共用的规则：Mac 的 `UCodeField`、iOS 的 `MCodeField` 都只管画和收键。
nonisolated enum CodeFieldInput {
    /// 只留数字、截到 `length` 位。粘贴「123 456」「123-456」只取数字；全角数字（中文输入法下打出来的）换成半角。
    static func normalize(_ text: String, length: Int) -> String {
        var digits = ""
        for character in text {
            guard digits.count < length else { break }
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { continue }
            switch scalar.value {
            case 0x30...0x39: digits.unicodeScalars.append(scalar)
            case 0xFF10...0xFF19:
                if let ascii = Unicode.Scalar(scalar.value - 0xFF10 + 0x30) { digits.unicodeScalars.append(ascii) }
            default: continue
            }
        }
        return digits
    }

    /// 在已有的码后面接着输入（打字、粘贴）。已经满了就不动。
    static func appending(_ input: String, to code: String, length: Int) -> String {
        normalize(code + input, length: length)
    }

    /// 粘贴：整串换掉已有的（剪贴板里是完整的码时不该接在输了一半的后面）；剪贴板里没有数字就不动。
    static func pasting(_ input: String, over code: String, length: Int) -> String {
        let pasted = normalize(input, length: length)
        return pasted.isEmpty ? code : pasted
    }

    /// 退格：删最后一位。
    static func deletingLast(from code: String) -> String {
        String(code.dropLast())
    }

    /// 读屏念的值：一位一位念，不念成一个六位数。
    static func spoken(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }
}
