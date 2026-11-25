import Foundation

/// 远程文件名（SFTP 上是不透明的字节串）在界面与路径里的**无损**写法。
///
/// 服务器上的名字不一定是 UTF-8（老系统、GBK 编码的中文名）。按 UTF-8 有损解码（非法字节换成 U+FFFD）的话，
/// 「测试.txt」「报告.txt」「附件.txt」的 GBK 字节全都解成 `"����.txt"`：界面上一模一样、标识重复，拿它回去操作
/// 根本找不回原来那个文件。这里定一个一一对应、可逆的写法，界面显示它、路径里就用它，发给服务器前还原成字节
/// （`SFTPSession` 与拼 shell 命令的地方各调一次），不需要任何「见过的名字」映射表：
///
/// - 合法的 UTF-8 原样保留——**绝大多数名字（以及用户手打、命令行传来的不带 U+FFFD 的路径）一个字节都不变**；
/// - 每个非法字节写成 `U+FFFD` + 两位大写十六进制 + `U+2060`（WORD JOINER，看不见），例如 GBK 的「测」
///   （`B2 E2`）显示成 `�B2�E2`，不同的名字显示也不同；
/// - 名字里本来就有的 U+2060 写成 `U+FFFD U+2060`，所以「真 U+FFFD 后面跟着 `B2` 再跟一个真 U+2060」也不会被
///   误认成字节 `B2`。
///
/// 还原时只认这两种序列，其余的 U+FFFD（用户粘贴进来的、从 exec 输出有损解码来的）都当普通字符：有损文本里
/// 非法字节后面紧跟「两位十六进制 + U+2060」在真实文件名里不会出现，所以这类路径只会像迁移前一样「找不到」，
/// 不会打到别的文件上。
nonisolated enum RemoteName {
    /// 引出转义的字符（同时也是有损解码放的替换符，显示上让人一眼看出「这里不是正常字符」）。
    static let escape: Unicode.Scalar = "\u{FFFD}"
    /// 字节转义的收尾：看不见，有损文本里不会恰好出现在「U+FFFD + 两位十六进制」后面。
    static let terminator: Unicode.Scalar = "\u{2060}"

    /// 字节 → 界面与路径里用的字符串（无损、可逆）。
    static func display<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let bytes = Array(bytes)
        // 快路径：合法 UTF-8 又没有 U+2060（几乎所有名字）。
        if isPlain(bytes) {
            return String(decoding: bytes, as: UTF8.self)
        }
        var scalars = String.UnicodeScalarView()
        var index = 0
        while index < bytes.count {
            let length = validSequenceLength(bytes, at: index)
            if length > 0 {
                let text = String(decoding: bytes[index..<(index + length)], as: UTF8.self)
                for scalar in text.unicodeScalars {
                    if scalar == terminator { scalars.append(escape) }
                    scalars.append(scalar)
                }
                index += length
            } else {
                appendEscaped(bytes[index], to: &scalars)
                index += 1
            }
        }
        return String(scalars)
    }

    /// `display` 的逆：界面 / 路径里的字符串 → 发给服务器的字节。不含转义序列的字符串就是它的 UTF-8。
    static func bytes(_ text: String) -> [UInt8] {
        guard text.unicodeScalars.contains(escape) else { return Array(text.utf8) }
        var result: [UInt8] = []
        result.reserveCapacity(text.utf8.count)
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == escape {
                if index + 1 < scalars.count, scalars[index + 1] == terminator {
                    result.append(contentsOf: String(terminator).utf8)
                    index += 2
                    continue
                }
                if index + 3 < scalars.count, scalars[index + 3] == terminator,
                   let high = hexValue(scalars[index + 1]), let low = hexValue(scalars[index + 2]) {
                    result.append(high << 4 | low)
                    index += 4
                    continue
                }
            }
            result.append(contentsOf: String(scalar).utf8)
            index += 1
        }
        return result
    }

    /// 这个字符串里有没有字节转义（即它对应的名字不是合法 UTF-8）。
    static func containsEscapedBytes(_ text: String) -> Bool {
        text.unicodeScalars.contains(escape) && bytes(text) != Array(text.utf8)
    }

    // MARK: - 私有

    private static func appendEscaped(_ byte: UInt8, to scalars: inout String.UnicodeScalarView) {
        let digits = Array("0123456789ABCDEF".unicodeScalars)
        scalars.append(escape)
        scalars.append(digits[Int(byte >> 4)])
        scalars.append(digits[Int(byte & 0x0F)])
        scalars.append(terminator)
    }

    /// 合法 UTF-8 且不含 U+2060（UTF-8 是 E2 81 A0）：显示就是它本身。
    private static func isPlain(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < bytes.count {
            let length = validSequenceLength(bytes, at: index)
            guard length > 0 else { return false }
            if length == 3, bytes[index] == 0xE2, bytes[index + 1] == 0x81, bytes[index + 2] == 0xA0 { return false }
            index += length
        }
        return true
    }

    /// 从 `index` 起是不是一个完整、合法的 UTF-8 序列（Unicode 表 3-7：排除过长编码、代理区、超出 U+10FFFF）；
    /// 是就返回它的长度，否则 0（这个字节要转义）。
    private static func validSequenceLength(_ bytes: [UInt8], at index: Int) -> Int {
        let lead = bytes[index]
        let length: Int
        let second: ClosedRange<UInt8>
        switch lead {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: length = 2; second = 0x80...0xBF
        case 0xE0: length = 3; second = 0xA0...0xBF
        case 0xE1...0xEC, 0xEE...0xEF: length = 3; second = 0x80...0xBF
        case 0xED: length = 3; second = 0x80...0x9F
        case 0xF0: length = 4; second = 0x90...0xBF
        case 0xF1...0xF3: length = 4; second = 0x80...0xBF
        case 0xF4: length = 4; second = 0x80...0x8F
        default: return 0
        }
        guard index + length <= bytes.count, second.contains(bytes[index + 1]) else { return 0 }
        for offset in 2..<length where !(0x80...0xBF).contains(bytes[index + offset]) {
            return 0
        }
        return length
    }

    private static func hexValue(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 0x30...0x39: return UInt8(scalar.value - 0x30)
        case 0x41...0x46: return UInt8(scalar.value - 0x41 + 10)
        default: return nil
        }
    }
}

/// 远端名字 / 路径的**身份**：按字符串的 UTF-8 字节比较、哈希、排序。
///
/// Swift 的 `String ==`、`Set<String>`、`[String: …]` 按「标准等价」比较：NFC 的 `café`（`63 61 66 C3 A9`）和
/// NFD 的 `café`（`63 61 66 65 CC 81`）是同一个串。可 Linux 的文件系统不做归一化，它们是两个文件（从 Mac 拷过去的
/// 目录里常见）；拿 `String` 当身份，列表里两行 id 一样，选中第二个、动的是第一个。凡是「这是哪个远端文件」的判断
/// ——列表项的 id、选中、按路径找已打开的标签 / 外部打开的会话 / 缓存——都用这个类型，不用 `String`。
nonisolated struct RemoteNameKey: Hashable, Sendable, Comparable, CustomStringConvertible, ExpressibleByStringLiteral {
    let utf8: [UInt8]

    init(_ text: String) { utf8 = Array(text.utf8) }
    init(stringLiteral value: String) { self.init(value) }

    static func < (lhs: RemoteNameKey, rhs: RemoteNameKey) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    var description: String { String(decoding: utf8, as: UTF8.self) }
}

nonisolated extension String {
    /// 远端名字 / 路径的逐字节身份（见 `RemoteNameKey`）。比较两个远端路径是不是同一个文件用 `a.remoteKey == b.remoteKey`。
    var remoteKey: RemoteNameKey { RemoteNameKey(self) }
}

nonisolated extension RemoteName {
    /// 把远端的名字 / 路径插进一句本地化的话里时用：包在 FSI … PDI（U+2068 … U+2069）里，从右往左的名字、名字里的
    /// 双向覆盖符都不会搅乱整句话的顺序（隔离区结束时里面没收尾的覆盖也跟着结束）。
    ///
    /// 和 `SSHPeerText.isolated` 的区别：这里**不消毒**——那一步会去掉 U+2060 之类的格式字符，转义过的名字（见上）
    /// 显示出来就和列表里的对不上了。只用于给人看的句子；日志与命令行接口给程序读的输出里别用。
    static func isolated(_ name: String) -> String {
        "\u{2068}" + name + "\u{2069}"
    }
}
