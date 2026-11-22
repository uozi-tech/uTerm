import Foundation

/// 不完整解析 JSON 就从一段 JSONL 字节里捞字段：会话列表每一行只读文件末尾一小块，
/// 块里可能是半行，大行（附件、工具结果）也不值得解析。
///
/// 找的是没转义的 `"键":"`。JSON 字符串里出现的引号一定带反斜杠（`\"cwd\":\"`），所以这样只会
/// 命中真正的键（任意层级的对象里）；调用方用到的字段（`entrypoint` / `cwd` / `timestamp`…）
/// 都在每行的顶层。Claude Code 写的是紧凑 JSON，键和值之间没有空格。
nonisolated enum ClaudeJSONLScan {
    /// 单个值最长多少字节。标题、路径都远小于它；超过的当作截断，不要。
    static let maxValueBytes = 16 * 1024

    /// `key` 在 `data` 里出现的每一个字符串值，按出现先后。值没有在块内结束（被块尾截断）的跳过。
    static func stringValues(forKey key: String, in data: Data) -> [String] {
        occurrences(ofKey: key, in: data).map(\.value)
    }

    /// 同上，带上每个值在 `data` 里的位置（键的起点），好把几个键的值按先后合在一起。
    static func occurrences(ofKey key: String, in data: Data) -> [(index: Data.Index, value: String)] {
        let pattern = Data("\"\(key)\":\"".utf8)
        var results: [(index: Data.Index, value: String)] = []
        var searchStart = data.startIndex
        while searchStart < data.endIndex,
              let hit = data.range(of: pattern, options: [], in: searchStart..<data.endIndex) {
            searchStart = hit.upperBound
            guard let end = closingQuote(in: data, from: hit.upperBound) else { continue }
            if let value = decodeString(data[hit.upperBound..<end]) { results.append((hit.lowerBound, value)) }
            searchStart = end
        }
        return results
    }

    /// 几个键的值合在一起，按在字节里出现的先后。
    static func stringValues(forKeys keys: [String], in data: Data) -> [String] {
        keys.flatMap { occurrences(ofKey: $0, in: data) }.sorted { $0.index < $1.index }.map(\.value)
    }

    static func lastStringValue(forKey key: String, in data: Data) -> String? {
        stringValues(forKey: key, in: data).last
    }

    /// 字节里有没有这个片段（不解析）。
    static func contains(_ fragment: String, in data: Data) -> Bool {
        data.range(of: Data(fragment.utf8)) != nil
    }

    /// 从值的第一个字节起找结尾的引号（跳过转义）。超过上限或到块尾都没找到为 nil。
    private static func closingQuote(in data: Data, from start: Data.Index) -> Data.Index? {
        var index = start
        let limit = data.index(start, offsetBy: maxValueBytes, limitedBy: data.endIndex) ?? data.endIndex
        while index < limit {
            switch data[index] {
            case UInt8(ascii: "\\"):
                index = data.index(index, offsetBy: 2, limitedBy: limit) ?? limit
                continue
            case UInt8(ascii: "\""):
                return index
            case 0x0A:
                return nil   // 字符串里不会有裸换行：跨到下一行了，这一处不完整。
            default:
                break
            }
            index += 1
        }
        return nil
    }

    /// 引号之间的原始字节按 JSON 字符串解码（处理 `\n`、`中` 之类）。
    private static func decodeString(_ raw: Data) -> String? {
        if !raw.contains(UInt8(ascii: "\\")) { return String(data: raw, encoding: .utf8) }
        var quoted = Data([UInt8(ascii: "\"")])
        quoted.append(raw)
        quoted.append(UInt8(ascii: "\""))
        return (try? JSONSerialization.jsonObject(with: quoted, options: [.fragmentsAllowed])) as? String
    }

    /// 把一块字节切成完整的行（不含换行符，去掉末尾的 `\r`、跳过空行）。
    /// - `dropsLeadingPartial`：块不是从行首开始的（从文件中间读起），第一段是半行，丢掉。
    /// - `dropsTrailingPartial`：块不是读到文件末尾的，最后一段可能是半行，丢掉。
    static func lines(in data: Data, dropsLeadingPartial: Bool, dropsTrailingPartial: Bool) -> [Data] {
        var pieces = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if dropsLeadingPartial, !pieces.isEmpty { pieces.removeFirst() }
        if dropsTrailingPartial, !pieces.isEmpty, data.last != 0x0A { pieces.removeLast() }
        return pieces.compactMap { piece in
            var line = piece
            if line.last == 0x0D { line = line.dropLast() }
            return line.isEmpty ? nil : Data(line)
        }
    }
}
