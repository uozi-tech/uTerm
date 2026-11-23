import Foundation

/// 从某个位置往后一块一块读，切出完整的行：会话还开着时接着读文件新长出来的部分（`ClaudeTranscriptPager.loadNewer`）。
///
/// 最后一行没写完（没有换行结尾）就先攒着，等下一块把它接完整再交出去。和 `ClaudeReverseLineScanner` 一样，
/// 超过 `maxLineBytes` 的行只留行首 `headBytes` 字节、标 `isTruncated`；交出的行用同一个 `Line`，行首偏移是文件里的绝对位置，
/// 所以条目 ID 和倒着读出来的一致。
nonisolated struct ClaudeForwardLineScanner: Sendable {
    typealias Line = ClaudeReverseLineScanner.Line

    let maxLineBytes: Int
    let headBytes: Int
    /// 已经读进来的位置（含攒着的半行）：下一块从这里读。
    private(set) var position: UInt64
    /// 攒着的那一行在文件里从哪开始。
    private var lineStart: UInt64
    private var pending = Data()
    private var pendingLength = 0
    private var pendingIsTruncated = false
    /// 第一行的开头不在这里（从一行中间开始读的）：丢到第一个换行为止。
    private var discardsUntilNewline: Bool

    init(position: UInt64, startsMidLine: Bool = false,
         maxLineBytes: Int = AgentTranscriptLimits.maxLineBytes, headBytes: Int = 4096) {
        self.maxLineBytes = max(1, maxLineBytes)
        self.headBytes = max(1, min(headBytes, maxLineBytes))
        self.position = position
        lineStart = position
        discardsUntilNewline = startsMidLine
    }

    /// 还攒着没写完的半行。
    var hasPartialLine: Bool { pendingLength > 0 || discardsUntilNewline }

    /// 交进紧接着 `position` 的一块，返回这一块里写完的行，先后顺序。
    mutating func feed(_ chunk: Data) -> [Line] {
        let chunk = Data(chunk)
        guard !chunk.isEmpty else { return [] }
        let start = position
        var lines: [Line] = []
        var segmentStart = 0
        chunk.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<bytes.count where bytes[index] == 0x0A {
                if discardsUntilNewline {
                    discardsUntilNewline = false
                } else {
                    absorb(chunk.subdata(in: segmentStart..<index))
                    if let line = finishLine() { lines.append(line) }
                }
                resetPending(at: start + UInt64(index + 1))
                segmentStart = index + 1
            }
        }
        if !discardsUntilNewline, segmentStart < chunk.count {
            absorb(chunk.subdata(in: segmentStart..<chunk.count))
        }
        position = start + UInt64(chunk.count)
        return lines
    }

    private mutating func absorb(_ segment: Data) {
        guard !segment.isEmpty else { return }
        pendingLength += segment.count
        if pendingIsTruncated { return }
        if pendingLength > maxLineBytes {
            pendingIsTruncated = true
            if pending.count < headBytes { pending.append(segment.prefix(headBytes - pending.count)) }
            pending = Data(pending.prefix(headBytes))
        } else {
            pending.append(segment)
        }
    }

    private func finishLine() -> Line? {
        guard pendingLength > 0 else { return nil }
        if pendingIsTruncated {
            return Line(offset: lineStart, length: pendingLength, bytes: pending, isTruncated: true)
        }
        var bytes = pending
        if bytes.last == 0x0D { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }
        return Line(offset: lineStart, length: pendingLength, bytes: bytes, isTruncated: false)
    }

    private mutating func resetPending(at offset: UInt64) {
        pending = Data()
        pendingLength = 0
        pendingIsTruncated = false
        lineStart = offset
    }
}
