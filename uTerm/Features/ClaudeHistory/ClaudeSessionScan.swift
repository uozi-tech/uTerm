import Foundation

/// 会话是从哪里起的。只列命令行起的：记录里每条 `user` / `assistant` 行带 `entrypoint`，
/// `cli` 是命令行，`claude-desktop` 是桌面版，`sdk-cli` 之类是程序调用的。
nonisolated enum ClaudeSessionOrigin: Equatable, Sendable {
    case cli
    /// 老版本不写 `entrypoint`：读到了消息行却没有这个字段，当作命令行。
    case legacy
    case other(String)
    /// 读过的部分里既没有 `entrypoint` 也没有消息行（只有标题行的空会话之类）。不列。
    case unknown

    var isListed: Bool {
        switch self {
        case .cli, .legacy: return true
        case .other, .unknown: return false
        }
    }

    init(entrypoint: String) {
        self = entrypoint == "cli" ? .cli : .other(entrypoint)
    }
}

/// 一块记录字节里捞到的会话信息。会话列表的每一行只读文件末尾一块（必要时加开头几块），不完整解析。
nonisolated struct ClaudeSessionScan: Equatable, Sendable {
    /// 出现过的 `entrypoint`，按先后。同一份记录里可能有两种（桌面版起的会话后来在命令行里接着用），
    /// 以最后一个为准：它说明最近一次是谁在写。
    var entrypoints: [String] = []
    /// 有没有完整的 `user` / `assistant` 消息行。
    var hasMessageLine = false
    /// 有没有真正的对话（用户的话、回答、工具调用）。只敲过 `/exit`、`/model` 的会话没有。
    var hasConversation = false
    /// 三种标题行各自最后一次出现的值。
    var customTitle: String?
    var aiTitle: String?
    var lastPrompt: String?
    /// 块里最后一句用户输入的文字（去掉系统注入之后）。标题行都没有时用它。
    var lastUserText: String?
    /// `cwd` 与 `relocatedCwd`，按先后。
    var directories: [String] = []
    var gitBranch: String?
    var version: String?
    var lastTimestamp: Date?
    /// `continued-in` 那一行记的新记录的会话 ID（上下文满了接着来，见 `AgentHistorySessionMetadata.continuedIn`）。
    /// 之后又有消息行（旧的会话后来又被继续了）就不算。
    var continuedIn: String?

    /// 标题行最多多大才解析（真实的标题行都只有几百字节）。
    static let maxTitleLineBytes = 64 * 1024

    static func scan(_ data: Data, dropsLeadingPartial: Bool, dropsTrailingPartial: Bool) -> ClaudeSessionScan {
        var scan = ClaudeSessionScan()
        scan.entrypoints = ClaudeJSONLScan.stringValues(forKey: "entrypoint", in: data)
        scan.directories = ClaudeJSONLScan.stringValues(forKeys: ["cwd", "relocatedCwd"], in: data)
        scan.gitBranch = ClaudeJSONLScan.lastStringValue(forKey: "gitBranch", in: data).flatMap { $0.isEmpty ? nil : $0 }
        scan.version = ClaudeJSONLScan.lastStringValue(forKey: "version", in: data)
        scan.lastTimestamp = ClaudeJSONLScan.stringValues(forKey: "timestamp", in: data)
            .reversed().lazy.compactMap(ClaudeTimestamp.parse).first

        for line in ClaudeJSONLScan.lines(in: data, dropsLeadingPartial: dropsLeadingPartial,
                                          dropsTrailingPartial: dropsTrailingPartial) {
            let head = line.prefix(ClaudeTranscriptParser.headBytes)
            let isMessage = ClaudeTranscriptParser.isMessageCandidate(head: head)
            if isMessage {
                scan.hasMessageLine = true
                scan.continuedIn = nil
            }
            guard line.count <= maxTitleLineBytes else { continue }
            if isMessage {
                // 没有标题行（只跑过 `claude -p`、最后一问是空的）时拿最后一句用户的话当标题。
                for item in ClaudeTranscriptParser.items(fromJSON: line, idPrefix: "") {
                    switch item.kind {
                    case .userText(let text):
                        scan.lastUserText = text
                        scan.hasConversation = true
                    case .assistantText, .toolCall:
                        scan.hasConversation = true
                    default:
                        break
                    }
                }
                continue
            }
            if ClaudeJSONLScan.contains("\"type\":\"continued-in\"", in: head) {
                scan.continuedIn = field("continuedInSessionId", ofLine: line)
                continue
            }
            switch titleLine(line, head: head) {
            case .customTitle(let value): scan.customTitle = value
            case .aiTitle(let value): scan.aiTitle = value
            case .lastPrompt(let value): scan.lastPrompt = value
            case nil: break
            }
        }
        return scan
    }

    /// 三种标题行。Claude Code 每轮提问时追加一次（`last-prompt` 紧跟着 `ai-title`），一轮长的工具调用之后
    /// 文件末尾几百 KB 里可能一行都没有。
    enum TitleLine: Equatable {
        case customTitle(String)
        case aiTitle(String)
        case lastPrompt(String)
    }

    /// 这一行是不是标题行、记的是什么。`head` 是行首一段（判断类型用）。
    static func titleLine(_ line: Data, head: Data) -> TitleLine? {
        guard line.count <= maxTitleLineBytes else { return nil }
        if ClaudeJSONLScan.contains("\"type\":\"custom-title\"", in: head) {
            return field("customTitle", ofLine: line).map(TitleLine.customTitle)
        }
        if ClaudeJSONLScan.contains("\"type\":\"ai-title\"", in: head) {
            return field("aiTitle", ofLine: line).map(TitleLine.aiTitle)
        }
        if ClaudeJSONLScan.contains("\"type\":\"last-prompt\"", in: head) {
            return field("lastPrompt", ofLine: line).map(TitleLine.lastPrompt)
        }
        return nil
    }

    /// 读到的块里有没有 Claude Code 起的名字（用户改的或 AI 起的）。
    var hasNameLine: Bool { customTitle != nil || aiTitle != nil }

    private static func field(_ key: String, ofLine line: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let value = object[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 合并另一块（`other` 比 `self` 在文件里更早）：标题、目录等以较新的为准，缺了才用较早的。
    func merged(withEarlier other: ClaudeSessionScan) -> ClaudeSessionScan {
        var result = self
        result.entrypoints = other.entrypoints + entrypoints
        result.hasMessageLine = hasMessageLine || other.hasMessageLine
        result.hasConversation = hasConversation || other.hasConversation
        result.customTitle = customTitle ?? other.customTitle
        result.aiTitle = aiTitle ?? other.aiTitle
        result.lastPrompt = lastPrompt ?? other.lastPrompt
        result.lastUserText = lastUserText ?? other.lastUserText
        result.directories = other.directories + directories
        result.gitBranch = gitBranch ?? other.gitBranch
        result.version = version ?? other.version
        result.lastTimestamp = lastTimestamp ?? other.lastTimestamp
        // 较新的一块里有消息行：那之后又聊过，较早那块里的 `continued-in` 不算。
        result.continuedIn = continuedIn ?? (hasMessageLine ? nil : other.continuedIn)
        return result
    }

    /// 标题：用户改过的名字 → Claude 起的名字 → 最后一次提问 → 读到的最后一句用户的话。
    var title: String? {
        (customTitle ?? aiTitle ?? lastPrompt ?? lastUserText).map { Self.singleLine($0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    var origin: ClaudeSessionOrigin {
        if let last = entrypoints.last { return ClaudeSessionOrigin(entrypoint: last) }
        return hasMessageLine ? .legacy : .unknown
    }

    /// 能不能下结论：读到了 `entrypoint`，或者读到了没带它的消息行。
    var isOriginDecided: Bool { !entrypoints.isEmpty || hasMessageLine }

    static func singleLine(_ text: String, limit: Int = 200) -> String {
        let collapsed = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}

/// 一份记录在 `size` 之前最近的标题行与工作目录（`ClaudeHistorySource` 按路径记着，文件变长后接着用）。
nonisolated struct ClaudeSessionNames: Equatable, Sendable {
    var size: UInt64
    var customTitle: String?
    var aiTitle: String?
    var lastPrompt: String?
    var lastDirectory: String?
}

nonisolated extension ClaudeSessionScan {
    /// 末尾那一块里没有的标题行用更早的补上（用户改的名字不管多早都算数，所以单独补）。
    mutating func fillNames(from earlier: ClaudeSessionNames) {
        if customTitle == nil { customTitle = earlier.customTitle }
        guard aiTitle == nil else { return }
        aiTitle = earlier.aiTitle
        if lastPrompt == nil { lastPrompt = earlier.lastPrompt }
    }
}

/// Claude Code 记录里的时间：ISO 8601，带毫秒（`2026-11-22T08:15:30.123Z`）。
nonisolated enum ClaudeTimestamp {
    static func parse(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }
}
