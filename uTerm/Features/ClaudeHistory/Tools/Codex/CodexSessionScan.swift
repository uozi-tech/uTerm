import Foundation

/// 列表一行要的东西，从一份 Codex 记录的开头与末尾各读一段得到（不整份读）。
///
/// - 开头：第一行 `session_meta` 末尾的 `git.branch`；第一句你说的话（当标题，Codex 没给会话起名时用）。
///   第一句话前面是系统提示、权限说明、AGENTS.md、环境说明这些注入的内容，实测本机第一句话中位数在第 91 KB、
///   九成在 236 KB 以内，所以按块往后读，读到为止，最多读 `CodexListing.headScanLimit`。
/// - 末尾（只有明文的）：最后活动时间、最后的工作目录（`turn_context.cwd`）、最后一句话（开头没找到第一句时的标题）。
///   压缩的没法只读末尾，最后活动时间用文件的修改时间（Codex 压缩时把修改时间原样带过去了，且只压 7 天没动过的）。
nonisolated struct CodexSessionScan: Equatable, Sendable {
    var firstUserText: String?
    var lastUserText: String?
    /// 有没有真正的对话（你说的话、回答、工具调用）。
    var hasConversation = false
    /// 整份都读过了（小文件）：没有对话就是真没有。
    var readWholeFile = false
    var gitBranch: String?
    var lastDirectory: String?
    var lastTimestamp: Date?
    /// 最后一次记下的账号额度（`token_count` 每次都带一份）与它的时间。侧栏底部取所有会话里最新的一份。
    var rateLimits: AgentRateLimits?
    var rateLimitsAt: Date?

    /// 第一行最多多大（实测最大 49 KB）。
    static let firstLineLimit = 256 * 1024

    static func scan(_ record: CodexRecordFile, provider: any SFTPProviding, limits: CodexListing) async throws -> CodexSessionScan {
        var scan = CodexSessionScan()
        var lines = ClaudeForwardLineScanner(position: 0, maxLineBytes: limits.headScanLimit)
        var reachedEnd = false
        var decoded = 0
        let stream = record.isCompressed ? CodexZstdStream() : nil
        var offset: UInt64 = 0
        var tracker = LastValues()
        reading: while decoded < limits.headScanLimit {
            let length = offset == 0 ? limits.tailBytes : (stream == nil ? limits.headChunkBytes : limits.compressedNextRead)
            let raw = try await provider.readRange(record.path, offset: offset, length: length)
            offset += UInt64(raw.count)
            let atEOF = raw.count < length || offset >= record.size
            var chunk = raw
            if let stream {
                do {
                    chunk = try stream.decompress(raw, limit: limits.headScanLimit + 4 * 1024 * 1024)
                } catch CodexZstdError.tooLarge {
                    break reading
                }
                if atEOF, !stream.isAtFrameEnd { throw CodexZstdError.corrupt }
            }
            decoded += chunk.count
            var found = lines.feed(chunk)
            if atEOF, lines.hasPartialLine { found += lines.feed(Data([0x0A])) }
            for line in found {
                tracker.absorb(line.bytes)
                if line.offset == 0 {
                    scan.gitBranch = gitBranch(inFirstLine: line.bytes)
                    continue
                }
                guard !line.isTruncated else { continue }
                scan.absorb(line)
                if scan.firstUserText != nil, scan.hasConversation, !atEOF { break reading }
            }
            if atEOF {
                reachedEnd = true
                break
            }
        }
        scan.readWholeFile = reachedEnd
        if reachedEnd {
            scan.lastTimestamp = tracker.timestamp
            scan.lastDirectory = tracker.directory
            return scan
        }
        // 压缩的只读了开头：最后的时间与目录不知道（调用方用修改时间与记录开头的目录）。
        if record.isCompressed { return scan }
        // 明文的末尾一块。
        let tailLength = Int(min(record.size, UInt64(limits.tailBytes)))
        let tailOffset = record.size - UInt64(tailLength)
        let tail = try await provider.readRange(record.path, offset: tailOffset, length: tailLength)
        var tailScan = CodexSessionScan()
        var tailTracker = LastValues()
        for line in ClaudeJSONLScan.lines(in: tail, dropsLeadingPartial: tailOffset > 0, dropsTrailingPartial: false) {
            tailTracker.absorb(line)
            tailScan.absorb(ClaudeReverseLineScanner.Line(offset: 1, length: line.count, bytes: line, isTruncated: false))
        }
        scan.lastUserText = tailScan.lastUserText
        if tailScan.rateLimits != nil {
            scan.rateLimits = tailScan.rateLimits
            scan.rateLimitsAt = tailScan.rateLimitsAt
        }
        scan.hasConversation = scan.hasConversation || tailScan.hasConversation
        scan.lastTimestamp = tailTracker.timestamp
        scan.lastDirectory = tailTracker.directory
        return scan
    }

    /// 一行消息：记下第一句 / 最后一句你说的话、有没有对话。
    private mutating func absorb(_ line: ClaudeReverseLineScanner.Line) {
        guard CodexTranscriptParser.isMessageCandidate(head: line.bytes),
              line.bytes.count <= ClaudeSessionScan.maxTitleLineBytes * 16 else { return }
        for item in CodexTranscriptParser.items(fromJSON: line.bytes, idPrefix: "") {
            switch item.kind {
            case .userText(let text):
                let title = ClaudeSessionScan.singleLine(text)
                guard !title.isEmpty else { continue }
                if firstUserText == nil { firstUserText = title }
                lastUserText = title
                hasConversation = true
            case .assistantText, .toolCall:
                hasConversation = true
            case .usage(let usage):
                if let limits = usage.rateLimits {
                    rateLimits = limits
                    rateLimitsAt = item.timestamp
                }
            default:
                break
            }
        }
    }

    /// `session_meta` 末尾的 `"git":{"commit_hash":…,"branch":"…",…}`。
    static func gitBranch(inFirstLine line: Data) -> String? {
        guard let git = line.range(of: Data("\"git\":{".utf8), options: .backwards) else { return nil }
        let rest = Data(line[git.upperBound...])
        guard let close = rest.firstIndex(of: UInt8(ascii: "}")) else { return nil }
        let object = Data(rest[rest.startIndex..<close])
        return ClaudeJSONLScan.stringValues(forKey: "branch", in: object).first.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 读过的行里最后的时间与工作目录。
    private struct LastValues {
        var timestamp: Date?
        var directory: String?

        mutating func absorb(_ line: Data) {
            // 每行顶层第一个键就是 `timestamp`。
            let head = line.prefix(64)
            if let value = ClaudeJSONLScan.stringValues(forKey: "timestamp", in: head).first,
               let date = ClaudeTimestamp.parse(value) {
                timestamp = date
            }
            if ClaudeJSONLScan.contains("\"type\":\"turn_context\"", in: line.prefix(128)),
               let cwd = ClaudeJSONLScan.stringValues(forKey: "cwd", in: line.prefix(64 * 1024)).first, !cwd.isEmpty {
                directory = cwd
            }
        }
    }
}
