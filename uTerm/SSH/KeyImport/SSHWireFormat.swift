/// SSH 线格式写入器。
nonisolated struct SSHWireWriter {
    private(set) var bytes: [UInt8] = []

    mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    /// `string`：uint32 长度前缀 + 原始字节。
    mutating func writeString(_ value: [UInt8]) {
        writeUInt32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func writeString(_ value: String) { writeString([UInt8](value.utf8)) }

    /// `mpint`：去前导零；若结果最高位为 1 则前补 0x00；再按 `string` 写出。
    mutating func writeMPInt(_ magnitude: [UInt8]) {
        var m = magnitude
        while m.count > 1, m.first == 0x00 { m.removeFirst() }
        if m == [0x00] { m = [] }                       // 数值 0 -> 空 string
        if let first = m.first, first & 0x80 != 0 { m.insert(0x00, at: 0) }
        writeString(m)
    }

    mutating func writeRawBytes(_ value: [UInt8]) { bytes.append(contentsOf: value) }
}

/// SSH 线格式读取器。
nonisolated struct SSHWireReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else {
            throw PrivateKeyImportError.malformedKey(reason: "SSH 线格式：读 uint32 越界")
        }
        defer { offset += 4 }
        return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
             | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    mutating func readString() throws -> [UInt8] {
        let length = Int(try readUInt32())
        guard offset + length <= bytes.count else {
            throw PrivateKeyImportError.malformedKey(reason: "SSH 线格式：读 string 越界")
        }
        defer { offset += length }
        return Array(bytes[offset..<offset + length])
    }

    /// 读 `mpint`，返回无符号大端幅值（去掉符号 0x00）。
    mutating func readMPInt() throws -> [UInt8] {
        var m = try readString()
        while m.count > 1, m.first == 0x00 { m.removeFirst() }
        return m
    }
}
