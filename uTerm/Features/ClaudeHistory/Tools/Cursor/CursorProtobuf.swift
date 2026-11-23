import Foundation

/// 最小的 protobuf 线格式读取（只读、不认 schema）：Cursor 命令行把对话存成 protobuf 的 blob。
/// 只需要按字段号取字符串、子消息、整数，没必要为此引入 SwiftProtobuf 和生成代码。
nonisolated struct CursorProtobufMessage {
    nonisolated enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }

    nonisolated struct Malformed: Error {}

    private(set) var fields: [(number: Int, value: Value)] = []

    /// 坏的（截断、不认识的线类型）抛 `Malformed`。
    init(_ data: Data) throws {
        var index = data.startIndex
        let end = data.endIndex
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while index < end {
                let byte = data[index]
                index += 1
                guard shift < 64 else { throw Malformed() }
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
            throw Malformed()
        }
        while index < end {
            let key = try varint()
            let number = Int(key >> 3)
            guard number > 0 else { throw Malformed() }
            switch key & 7 {
            case 0:
                fields.append((number, .varint(try varint())))
            case 1:
                guard end - index >= 8 else { throw Malformed() }
                var value: UInt64 = 0
                for shift in 0..<8 { value |= UInt64(data[index + shift]) << UInt64(shift * 8) }
                index += 8
                fields.append((number, .fixed64(value)))
            case 2:
                let length = try varint()
                guard length <= UInt64(end - index) else { throw Malformed() }
                let next = index + Int(length)
                fields.append((number, .bytes(data[index..<next])))
                index = next
            case 5:
                guard end - index >= 4 else { throw Malformed() }
                var value: UInt32 = 0
                for shift in 0..<4 { value |= UInt32(data[index + shift]) << UInt32(shift * 8) }
                index += 4
                fields.append((number, .fixed32(value)))
            default:
                throw Malformed()
            }
        }
    }

    /// 同一个字段号的全部长度前缀值（repeated 的按出现顺序）。
    func allBytes(_ number: Int) -> [Data] {
        fields.compactMap { field in
            guard field.number == number, case .bytes(let data) = field.value else { return nil }
            return data
        }
    }

    /// 最后一个（proto3 里单值字段重复出现时以最后一个为准）。
    func bytes(_ number: Int) -> Data? { allBytes(number).last }

    func string(_ number: Int) -> String? { bytes(number).map { String(decoding: $0, as: UTF8.self) } }

    /// 非空的字符串。
    func text(_ number: Int) -> String? {
        guard let value = string(number), !value.isEmpty else { return nil }
        return value
    }

    func strings(_ number: Int) -> [String] { allBytes(number).map { String(decoding: $0, as: UTF8.self) } }

    func message(_ number: Int) -> CursorProtobufMessage? { bytes(number).flatMap { try? CursorProtobufMessage($0) } }

    func messages(_ number: Int) -> [CursorProtobufMessage] { allBytes(number).compactMap { try? CursorProtobufMessage($0) } }

    func varint(_ number: Int) -> UInt64? {
        for field in fields.reversed() where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }

    /// oneof：第一个出现的、在 `numbers` 里的字段号与它的子消息。
    func oneof(_ numbers: ClosedRange<Int>) -> (number: Int, message: CursorProtobufMessage)? {
        for field in fields where numbers.contains(field.number) {
            if case .bytes(let data) = field.value, let message = try? CursorProtobufMessage(data) {
                return (field.number, message)
            }
        }
        return nil
    }

    /// 不认识的消息里找一段像是给人看的文字：本层第一个是可打印 UTF-8 的长度前缀字段。子消息的头几个字节几乎都是
    /// 控制字符（字段 2、3 的标签是 0x12、0x1A），不会被当成文字。
    func firstPrintableString(maxBytes: Int = 4096) -> String? {
        for case let (_, .bytes(data)) in fields where !data.isEmpty && data.count <= maxBytes {
            if let text = Self.printable(data) { return text }
        }
        return nil
    }

    /// 本层与下面几层里所有可打印的字符串，按出现顺序。给不认识的工具结果凑一段文字。
    func printableStrings(depth: Int = 3, limit: Int = 64) -> [String] {
        var output: [String] = []
        collect(into: &output, depth: depth, limit: limit)
        return output
    }

    private func collect(into output: inout [String], depth: Int, limit: Int) {
        for case let (_, .bytes(data)) in fields where !data.isEmpty {
            guard output.count < limit else { return }
            if let text = Self.printable(data) {
                output.append(text)
            } else if depth > 0, let child = try? CursorProtobufMessage(data) {
                child.collect(into: &output, depth: depth - 1, limit: limit)
            }
        }
    }

    /// 合法的 UTF-8，除了换行、回车、制表符没有控制字符。
    static func printable(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value < 0x20, value != 0x0A, value != 0x0D, value != 0x09 { return nil }
            if value == 0x7F { return nil }
        }
        return text
    }
}
