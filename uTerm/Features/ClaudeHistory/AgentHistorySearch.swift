import Foundation

/// 跨会话搜索的搜索词：去掉首尾空白后 2–200 个字，不能有换行、NUL 之类的控制字符（搜索词要拿到主机上的命令里去，
/// 控制字符既没法在记录里匹配上，也不该进命令）。英文不分大小写（只折叠 ASCII 字母），中文按原样子串匹配。
nonisolated struct AgentHistorySearchQuery: Equatable, Sendable {
    let text: String

    static let minCharacters = 2
    static let maxCharacters = 200

    nonisolated enum Problem: Error, Equatable, Sendable {
        case tooShort, tooLong, controlCharacters
    }

    private init(text: String) { self.text = text }

    static func validate(_ raw: String) -> Result<AgentHistorySearchQuery, Problem> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.unicodeScalars.contains(where: isControl) { return .failure(.controlCharacters) }
        if text.count < minCharacters { return .failure(.tooShort) }
        if text.count > maxCharacters { return .failure(.tooLong) }
        return .success(AgentHistorySearchQuery(text: text))
    }

    /// C0 / C1 控制字符、DEL，以及 Unicode 的行分隔符与段分隔符（都算「换行」）。
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0..<0x20, 0x7F...0x9F, 0x2028, 0x2029: return true
        default: return false
        }
    }
}

/// 搜索的上限。数值的来历见 `standard`。
nonisolated struct AgentHistorySearchLimits: Equatable, Sendable {
    /// 一共最多出这么多条命中，到了就停（不再往主机上发命令），结果末尾说「只显示前 N 条」。
    var totalHits: Int
    /// 一个会话里最多出这么多条。
    var hitsPerSession: Int
    /// 主机上一份记录最多报回这么多个候选行（其中只在工具结果之类里出现的会在本机确认时丢掉）。
    var candidateLinesPerSession: Int
    /// 比这还长的行不读回来确认（大的工具结果、贴进来的大段文字）。
    var maxLineBytes: Int

    /// 本机 1635 份主记录、8.6 GB 实测（见报告）：常见英文词 grep 第一段几乎份份都命中，一屏能看的远不到 100 条。
    static let standard = AgentHistorySearchLimits(totalHits: 100, hitsPerSession: 5, candidateLinesPerSession: 30,
                                                   maxLineBytes: 1024 * 1024)
}

/// 命中那一行在记录文件里的位置。从这里打开对话（`AgentHistorySource.transcript(for:around:)`）。
nonisolated struct AgentTranscriptAnchor: Hashable, Sendable {
    let lineOffset: UInt64
    let lineLength: Int
}

/// 命中前后的一小段：`before` / `after` 已经把换行折成空格，截断处带「…」。界面把 `match` 加粗。
nonisolated struct AgentHistorySnippet: Equatable, Sendable {
    var before: String
    var match: String
    var after: String

    var plain: String { before + match + after }
}

/// 一条命中：对话里的哪一条（条目 ID 与打开对话后的一致）、谁说的、前后文。
nonisolated struct AgentHistorySearchHit: Identifiable, Equatable, Sendable {
    let itemID: String
    let role: AgentTranscriptItem.Role
    let snippet: AgentHistorySnippet
    let timestamp: Date?
    let anchor: AgentTranscriptAnchor

    var id: String { itemID }
}

/// 一个会话里的命中，按在对话里的先后排。
nonisolated struct AgentHistorySearchSession: Identifiable, Equatable, Sendable {
    let file: AgentHistorySessionFile
    let metadata: AgentHistorySessionMetadata
    var hits: [AgentHistorySearchHit]
    /// 确认到的比显示的多（显示到 `hitsPerSession` 为止）。
    var hasMoreHits: Bool

    var id: String { file.path }
}

/// 搜索过程中一批一批报回来的东西。
nonisolated enum AgentHistorySearchEvent: Equatable, Sendable {
    /// 在主机上找过了几份记录 / 一共几份。
    case progress(searched: Int, total: Int)
    /// 一个会话的命中（最近的会话先报）。
    case session(AgentHistorySearchSession)
    /// 搜完了。`truncated`：命中到了上限，后面没再找。
    case finished(truncated: Bool)
}

/// 搜不了：主机上跑不了命令，或者缺搜索要用的工具。别的错误（断线）照原样抛。
nonisolated enum AgentHistorySearchError: Error, Equatable, Sendable {
    case cannotExecute
    case missingTools
    /// 命令的输出不完整（被截断、命令中途被结束）。
    case incompleteOutput
}

/// 哪些文字参与搜索、命中前后截一段：与具体是哪个 Agent 的记录无关。
nonisolated enum AgentHistorySearchMatcher {
    /// 命中前后各留多少字。
    static let contextBefore = 36
    static let contextAfter = 90

    /// 条目里参与搜索的文字：你说的话（含斜杠命令）、回答、工具调用的摘要行（工具名 + 摘要）。
    /// 思考、工具结果、命令输出、压缩摘要不搜。
    static func searchableText(_ item: AgentTranscriptItem) -> String? {
        switch item.kind {
        case .userText(let text), .command(let text), .assistantText(let text):
            return text
        case .toolCall(let call):
            return call.summary.isEmpty ? call.name : call.name + " " + call.summary
        case .commandOutput, .notice, .thinking, .toolResult, .image, .compactSummary, .oversized, .usage:
            return nil
        }
    }

    /// 一行解析出来的条目里第一条命中的。
    static func firstHit(in items: [AgentTranscriptItem], query: AgentHistorySearchQuery)
        -> (item: AgentTranscriptItem, snippet: AgentHistorySnippet)? {
        for item in items {
            guard let text = searchableText(item), let snippet = snippet(of: query.text, in: text) else { continue }
            return (item, snippet)
        }
        return nil
    }

    /// 在 `text` 里找 `query`（只折叠 ASCII 字母的大小写，同主机上 `LC_ALL=C` 的 `grep -i`），截出前后一段。
    static func snippet(of query: String, in text: String) -> AgentHistorySnippet? {
        let haystack = Array(text.unicodeScalars)
        let needle = query.unicodeScalars.map(fold)
        guard let start = firstIndex(of: needle, in: haystack) else { return nil }
        let end = start + needle.count
        let before = collapse(haystack[max(0, start - contextBefore * 3)..<start])
        let after = collapse(haystack[end..<min(haystack.count, end + contextAfter * 3)])
        let shownBefore = String(before.suffix(contextBefore))
        let shownAfter = String(after.prefix(contextAfter))
        let leading = start > 0 && (shownBefore.count < before.count || start > contextBefore * 3)
        let trailing = end < haystack.count && (shownAfter.count < after.count || end + contextAfter * 3 < haystack.count)
        return AgentHistorySnippet(before: (leading ? "…" : "") + trimLeading(shownBefore),
                                   match: String(String.UnicodeScalarView(haystack[start..<end])),
                                   after: trimTrailing(shownAfter) + (trailing ? "…" : ""))
    }

    private static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        (0x41...0x5A).contains(scalar.value) ? Unicode.Scalar(scalar.value + 0x20)! : scalar
    }

    private static func firstIndex(of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar]) -> Int? {
        guard let head = needle.first, haystack.count >= needle.count else { return nil }
        var index = 0
        let last = haystack.count - needle.count
        while index <= last {
            if fold(haystack[index]) == head {
                var offset = 1
                while offset < needle.count, fold(haystack[index + offset]) == needle[offset] { offset += 1 }
                if offset == needle.count { return index }
            }
            index += 1
        }
        return nil
    }

    /// 换行、制表符折成一个空格，连续的空白只留一个。
    private static func collapse(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var output = String.UnicodeScalarView()
        var lastWasSpace = false
        for scalar in scalars {
            if scalar.properties.isWhitespace {
                if !lastWasSpace { output.append(" ") }
                lastWasSpace = true
            } else {
                output.append(scalar)
                lastWasSpace = false
            }
        }
        return String(output)
    }

    private static func trimLeading(_ text: String) -> String {
        text.first == " " ? String(text.dropFirst()) : text
    }

    private static func trimTrailing(_ text: String) -> String {
        text.last == " " ? String(text.dropLast()) : text
    }
}
