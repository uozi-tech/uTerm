import Foundation

/// `~/.claude/history.jsonl`：Claude Code 每次提问追加一行（`{display, pastedContents, timestamp, project, sessionId}`），
/// 只往后长。`ClaudeHistorySource` 记着读到哪，每次重列只读新长出来的那一段，看这期间哪些会话有了新的提问。
///
/// 用处是知道哪些记录变了：往已有的记录后面追加不改项目目录的修改时间，没有它就得每次都把全部项目目录列一遍
/// （本机 245 个；SSH 上每个都是几个来回）。它不是完整的会话清单（只记命令行里的提问，旧的会被 Claude Code 删掉），
/// 新建、删除记录照旧看项目目录的修改时间。
nonisolated struct ClaudeHistoryLog: Equatable, Sendable {
    /// 读到哪了（下一行的开头）与它前面那几个字节（下次一起读回来核对，文件被换掉了就对不上）；nil = 还没有基线。
    private(set) var position: ClaudeReadPosition?

    /// 一次最多读这么多新长出来的；多了不读（当成没有基线，整个重列一次）。
    static let maxReadBytes = 4 * 1024 * 1024

    /// 这一趟读到的：有新提问的会话 ID 与它们的项目目录名（`ClaudeProjectPath.encode` 换算的）。
    nonisolated struct Touches: Equatable, Sendable {
        var sessionIDs: Set<String> = []
        var projects: Set<String> = []
    }

    /// 文件现在多大，下一步怎么读。
    nonisolated enum Plan: Equatable, Sendable {
        /// 没变。
        case unchanged
        /// 从 `offset` 读 `length` 字节（连着上次读到的位置前面那几个字节）。
        case read(offset: UInt64, length: Int)
        /// 没有基线（第一次、变短了、一下子长了太多）：从头读一遍建基线（太大就只记位置），这一趟整个重列。
        case rebase(offset: UInt64, length: Int)
    }

    func plan(size: UInt64) -> Plan {
        guard let position, size >= position.offset, size - position.offset <= UInt64(Self.maxReadBytes) else {
            // 建基线要知道最后一个整行在哪，读末尾一小块就够。
            let length = Int(min(size, 64 * 1024))
            return .rebase(offset: size - UInt64(length), length: length)
        }
        if size == position.offset { return .unchanged }
        return .read(offset: position.start, length: Int(size - position.start))
    }

    /// 建基线：末尾那一块（`plan` 给的 `rebase`）里最后一个整行的末尾。
    mutating func rebase(_ data: Data, from start: UInt64) {
        position = ClaudeReadPosition(lastLineEndIn: data, from: start)
    }

    /// 文件不在了（或者读不了）：下次从头建基线。
    mutating func reset() {
        position = nil
    }

    /// 读回来的那一段（`plan` 给的 `read`）。核对不上（文件换过了）返回 nil 并且下次重建基线；否则返回读到的提问，
    /// 最后半行（正写着）留到下次。
    mutating func consume(_ data: Data, from start: UInt64) -> Touches? {
        guard let position, let body = position.newBytes(in: data, from: start) else {
            self.position = nil
            return nil
        }
        guard let lastNewline = body.lastIndex(of: 0x0A) else { return Touches() }
        var touches = Touches()
        for line in body[body.startIndex..<lastNewline].split(separator: 0x0A) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let sessionID = object["sessionId"] as? String, !sessionID.isEmpty else { continue }
            touches.sessionIDs.insert(sessionID)
            if let project = object["project"] as? String, !project.isEmpty {
                touches.projects.insert(ClaudeProjectPath.encode(project))
            }
        }
        self.position = ClaudeReadPosition(lastLineEndIn: data, from: start) ?? position
        return touches
    }
}

/// 只往后长的文件读到哪了：最后一个整行的末尾，连同它前面最多 `anchorBytes` 个字节。下次从那几个字节起往后读，
/// 读回来的开头和记下的一样才接着用（没有 inode 可看：SFTP 不给；文件被换成了别的，这几个字节基本不可能还一样）。
nonisolated struct ClaudeReadPosition: Equatable, Sendable {
    /// 下一行的开头。
    let offset: UInt64
    let anchor: Data

    static let anchorBytes = 64

    /// 下次从哪读。
    var start: UInt64 { offset - UInt64(anchor.count) }

    /// `data`（从 `start` 读起）里最后一个整行的末尾。一个换行都没有：从文件开头读的是 0，否则不知道，nil。
    init?(lastLineEndIn data: Data, from start: UInt64) {
        guard let newline = data.lastIndex(of: 0x0A) else {
            guard start == 0 else { return nil }
            self.init(offset: 0, anchor: Data())
            return
        }
        let end = data.distance(from: data.startIndex, to: newline) + 1
        let anchorStart = max(0, end - Self.anchorBytes)
        let slice = data[data.index(data.startIndex, offsetBy: anchorStart)..<data.index(data.startIndex, offsetBy: end)]
        self.init(offset: start + UInt64(end), anchor: Data(slice))
    }

    init(offset: UInt64, anchor: Data) {
        self.offset = offset
        self.anchor = anchor
    }

    /// 从 `start` 读回来的 `data` 里，记下的位置之后的字节；开头对不上（文件被换过、截过）为 nil。
    func newBytes(in data: Data, from start: UInt64) -> Data.SubSequence? {
        guard start == self.start, data.count >= anchor.count, data.prefix(anchor.count) == anchor else { return nil }
        return data.dropFirst(anchor.count)
    }
}

/// 一份记录读到哪了：读过的字节捞到的会话信息（`ClaudeSessionScan`，标题行、来源、目录……都在里面）与读到的最后一个整行的末尾。
/// 记录只往后长：变长了只读新长出来的那一段、并进来，不再读末尾 64 KB、往前找标题行。
nonisolated struct ClaudeTranscriptState: Equatable, Sendable {
    /// 读的时候文件多大。
    var size: UInt64
    /// 读过的最后一个整行的末尾；不知道（末尾那一块里一个换行都没有）为 nil，下次整份重读。
    var position: ClaudeReadPosition?
    var scan: ClaudeSessionScan

    /// 新长出来的超过这么多就不增量读了（同整份重读时往前找标题行的上限）。
    static let maxGrowth = UInt64(ClaudeHistorySource.titleSearchLimit)

    /// 这一份变成 `size` 之后能不能只读新长出来的：要从哪读、读多少。
    func growth(to size: UInt64) -> (offset: UInt64, length: Int)? {
        guard size > self.size, let position, size - position.offset <= Self.maxGrowth else { return nil }
        return (position.start, Int(size - position.start))
    }

    /// 把新长出来的那一段并进来。开头对不上（文件被换掉了）返回 nil。
    func appending(_ data: Data, from start: UInt64, size: UInt64) -> ClaudeTranscriptState? {
        guard let position, let body = position.newBytes(in: data, from: start) else { return nil }
        let part = ClaudeSessionScan.scan(Data(body), dropsLeadingPartial: false, dropsTrailingPartial: false)
        return ClaudeTranscriptState(size: size, position: ClaudeReadPosition(lastLineEndIn: data, from: start) ?? position,
                                     scan: part.merged(withEarlier: scan).bounded())
    }
}

nonisolated extension ClaudeSessionScan {
    /// 增量并了很多次之后，按先后攒的几样只留最近的一段（同一次只读末尾 64 KB 时看到的量级），不跟着记录一直涨。
    func bounded(entrypoints entrypointLimit: Int = 64, directories directoryLimit: Int = 256) -> ClaudeSessionScan {
        var result = self
        if result.entrypoints.count > entrypointLimit { result.entrypoints = Array(result.entrypoints.suffix(entrypointLimit)) }
        if result.directories.count > directoryLimit { result.directories = Array(result.directories.suffix(directoryLimit)) }
        return result
    }
}
