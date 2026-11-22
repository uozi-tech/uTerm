import Foundation

/// 从文件末尾一块一块往前读，切出完整的行。记录可能有几十 MB，打开会话只看最后一段，往上翻再读更早的。
///
/// 用法：`nextRange(chunkSize:)` 给出下一块该读的区间，读回来交给 `feed`，拿到这一块里结束的行
/// （新的在前）；读到文件开头后 `finish()` 交出第一行。跨块的行在内部拼好。
///
/// 超长的行（大的工具结果、附件）不整行留在内存里：超过 `maxLineBytes` 之后只留行首 `headBytes`
/// 字节（够判断是什么类型的行），交出去时标 `isTruncated`。
nonisolated struct ClaudeReverseLineScanner: Sendable {
    nonisolated struct Line: Equatable, Sendable {
        /// 行首在文件里的偏移。
        let offset: UInt64
        /// 整行多长（不含换行符）。
        let length: Int
        /// 行的内容；`isTruncated` 时只是开头一段。
        let bytes: Data
        let isTruncated: Bool
    }

    let maxLineBytes: Int
    let headBytes: Int
    /// 还没读的部分是 `[0, cursor)`。
    private(set) var cursor: UInt64
    /// 当前这行（行首还没读到）已经读到的部分，从 `cursor` 起。
    private var pending = Data()
    /// 当前这行在文件里的结尾（换行符的位置，或文件末尾）。
    private var pendingEnd: UInt64
    private var pendingIsTruncated = false
    private var finished = false

    init(fileSize: UInt64, maxLineBytes: Int = 8 * 1024 * 1024, headBytes: Int = 4096) {
        self.maxLineBytes = max(1, maxLineBytes)
        self.headBytes = max(1, min(headBytes, maxLineBytes))
        cursor = fileSize
        pendingEnd = fileSize
    }

    /// 读到了文件开头，第一行也交出去了。
    var isAtStart: Bool { finished }

    /// 下一块：`[offset, offset + length)`。已经到开头时为 nil。
    func nextRange(chunkSize: Int) -> (offset: UInt64, length: Int)? {
        guard cursor > 0 else { return nil }
        let length = Int(min(UInt64(max(1, chunkSize)), cursor))
        return (cursor - UInt64(length), length)
    }

    /// 交进紧挨在已读部分前面的一块（`[cursor - chunk.count, cursor)`），返回这一块里结束的行，新的在前。
    mutating func feed(_ chunk: Data) -> [Line] {
        let chunk = Data(chunk)
        guard !chunk.isEmpty, UInt64(chunk.count) <= cursor else { return [] }
        let start = cursor - UInt64(chunk.count)
        var lines: [Line] = []
        var segmentEnd = chunk.count
        var index = chunk.count - 1
        chunk.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            while index >= 0 {
                if bytes[index] == 0x0A {
                    let lineStart = start + UInt64(index + 1)
                    if let line = makeLine(head: chunk.subdata(in: (index + 1)..<segmentEnd), offset: lineStart) {
                        lines.append(line)
                    }
                    pending = Data()
                    pendingIsTruncated = false
                    pendingEnd = start + UInt64(index)
                    segmentEnd = index
                }
                index -= 1
            }
        }
        absorb(chunk.subdata(in: 0..<segmentEnd))
        cursor = start
        return lines
    }

    /// 读到开头之后调一次：交出文件的第一行。
    mutating func finish() -> Line? {
        guard cursor == 0, !finished else { return nil }
        finished = true
        let line = makeLine(head: Data(), offset: 0)
        pending = Data()
        return line
    }

    /// 这一行的行首段 `head`（从 `offset` 起）接上已经读到的 `pending`，就是完整的一行。
    private func makeLine(head: Data, offset: UInt64) -> Line? {
        let length = Int(pendingEnd - offset)
        guard length > 0 else { return nil }
        if pendingIsTruncated || length > maxLineBytes {
            var prefix = head.prefix(headBytes)
            if prefix.count < headBytes { prefix.append(pending.prefix(headBytes - prefix.count)) }
            return Line(offset: offset, length: length, bytes: Data(prefix), isTruncated: true)
        }
        var bytes = head
        bytes.append(pending)
        if bytes.last == 0x0D { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }
        return Line(offset: offset, length: length, bytes: bytes, isTruncated: false)
    }

    /// 这块里在第一个换行之前的部分属于还没读完的那一行，接到 `pending` 前面。
    private mutating func absorb(_ head: Data) {
        guard !head.isEmpty else { return }
        if pendingIsTruncated {
            var prefix = head.prefix(headBytes)
            if prefix.count < headBytes { prefix.append(pending.prefix(headBytes - prefix.count)) }
            pending = Data(prefix)
            return
        }
        var combined = head
        combined.append(pending)
        if combined.count > maxLineBytes {
            pendingIsTruncated = true
            pending = Data(combined.prefix(headBytes))
        } else {
            pending = combined
        }
    }
}
