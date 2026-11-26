import Foundation

/// 压缩过的记录（`.jsonl.zst`）多大才在 App 里打开。
nonisolated enum CodexArchiveLimits {
    /// 解开后的上限。实测本机 2057 份压缩记录：解开后中位数 0.35 MB、99% 在 19 MB 以内，最大的一份 298 MB。
    /// 整份要放在内存里（iOS 上也是），所以只开得了这么大的；更大的给出说得清的提示。
    static let maxDecodedBytes = 128 * 1024 * 1024
    /// 下载时一次读多少压缩字节（边读边解）。
    static let downloadChunkBytes = 1024 * 1024
}

/// 读一份压缩记录：zstd 帧没法只解末尾，所以第一次往前翻时整份下载、在内存里解开，之后一页一页往前读的都是内存里的那份。
/// 行的偏移是**解开后**的字节位置（主机上搜索时 `zstd -dc` 出来的也是这个位置），条目 ID 跟着它走，所以搜索命中处能对上。
///
/// 不跟随：Codex 只压 7 天没动过的记录；会话又被接着用时它先解回明文 `.jsonl` 再往后写（文件名也就变了），
/// 那是列表里的另一份。
actor CodexCompressedPager: AgentTranscriptPaging {
    private let provider: any SFTPProviding
    private let path: String
    private let parseLine: @Sendable (ClaudeReverseLineScanner.Line) -> [AgentTranscriptItem]
    private let maxDecodedBytes: Int
    private let chunkBytes: Int
    private let pageItems: Int
    private let pageBytes: Int
    private let maxLineBytes: Int

    private var data: Data?
    private var scanner: ClaudeReverseLineScanner?
    /// 从某一行打开时往后读到哪了。
    private var forward: ClaudeForwardLineScanner?
    private let anchor: AgentTranscriptAnchor?

    init(provider: any SFTPProviding, path: String, anchor: AgentTranscriptAnchor? = nil,
         maxDecodedBytes: Int = CodexArchiveLimits.maxDecodedBytes,
         chunkBytes: Int = AgentTranscriptLimits.chunkBytes,
         pageItems: Int = AgentTranscriptLimits.pageItems,
         pageBytes: Int = AgentTranscriptLimits.pageBytes,
         maxLineBytes: Int = AgentTranscriptLimits.maxLineBytes,
         lineParser: @escaping @Sendable (ClaudeReverseLineScanner.Line) -> [AgentTranscriptItem]) {
        self.provider = provider
        self.path = path
        self.anchor = anchor
        self.maxDecodedBytes = maxDecodedBytes
        self.chunkBytes = max(1, chunkBytes)
        self.pageItems = pageItems
        self.pageBytes = pageBytes
        self.maxLineBytes = maxLineBytes
        parseLine = lineParser
    }

    func loadPrevious() async throws -> (items: [AgentTranscriptItem], reachedStart: Bool) {
        let data = try await decoded()
        if scanner == nil {
            let size = UInt64(data.count)
            if let anchor {
                let end = min(size, anchor.lineOffset + UInt64(anchor.lineLength) + 1)
                scanner = ClaudeReverseLineScanner(fileSize: end, maxLineBytes: maxLineBytes)
                forward = ClaudeForwardLineScanner(position: end, maxLineBytes: maxLineBytes)
            } else {
                scanner = ClaudeReverseLineScanner(fileSize: size, maxLineBytes: maxLineBytes)
            }
        }
        guard var scanner else { return ([], true) }
        var newestFirst: [[AgentTranscriptItem]] = []
        var count = 0
        var bytesRead = 0
        while count < pageItems, bytesRead < pageBytes, let range = scanner.nextRange(chunkSize: chunkBytes) {
            let start = Int(range.offset)
            let chunk = data.subdata(in: start..<(start + range.length))
            bytesRead += chunk.count
            for line in scanner.feed(chunk) {
                let items = parseLine(line)
                if !items.isEmpty {
                    newestFirst.append(items)
                    count += items.filter(\.isDisplayed).count
                }
            }
            if scanner.nextRange(chunkSize: chunkBytes) == nil, let first = scanner.finish() {
                let items = parseLine(first)
                if !items.isEmpty { newestFirst.append(items) }
            }
        }
        if scanner.nextRange(chunkSize: chunkBytes) == nil, !scanner.isAtStart { _ = scanner.finish() }
        self.scanner = scanner
        return (newestFirst.reversed().flatMap { $0 }, scanner.isAtStart)
    }

    func loadNext() async throws -> AgentTranscriptGrowth {
        guard var forward, let data else { return .unchanged }
        let size = UInt64(data.count)
        var items: [AgentTranscriptItem] = []
        var bytesRead = 0
        while forward.position < size, items.filter(\.isDisplayed).count < pageItems, bytesRead < pageBytes {
            let start = Int(forward.position)
            let end = min(data.count, start + chunkBytes)
            let chunk = data.subdata(in: start..<end)
            bytesRead += chunk.count
            for line in forward.feed(chunk) { items.append(contentsOf: parseLine(line)) }
        }
        let reachedEnd = forward.position >= size
        // 最后一行没有换行结尾：读到末尾了也要交出来（这份记录不会再长了）。
        if reachedEnd, forward.hasPartialLine {
            items.append(contentsOf: forward.feed(Data([0x0A])).flatMap(parseLine))
        }
        self.forward = reachedEnd ? nil : forward
        return .appended(items, hasMore: !reachedEnd)
    }

    func loadNewer() async throws -> AgentTranscriptGrowth { .unchanged }

    /// 整份下载并解开；只做一次。
    private func decoded() async throws -> Data {
        if let data { return data }
        let result = try await Self.download(provider: provider, path: path, maxDecodedBytes: maxDecodedBytes)
        data = result
        return result
    }

    /// 边下载边解。帧头写着原始大小（Codex 压的时候都写了）时先看一眼，超了就不下载。
    static func download(provider: any SFTPProviding, path: String, maxDecodedBytes: Int,
                         chunkBytes: Int = CodexArchiveLimits.downloadChunkBytes) async throws -> Data {
        let compressedSize = UInt64(max(0, try await provider.stat(path).size))
        let stream = CodexZstdStream()
        var output = Data()
        var offset: UInt64 = 0
        while offset < compressedSize {
            try Task.checkCancellation()
            let length = Int(min(UInt64(chunkBytes), compressedSize - offset))
            let chunk = try await provider.readRange(path, offset: offset, length: length)
            guard !chunk.isEmpty else { break }
            if offset == 0, let declared = CodexZstdStream.contentSize(ofFramePrefix: chunk), declared > UInt64(maxDecodedBytes) {
                throw tooLarge(declared, limit: maxDecodedBytes)
            }
            do {
                output.append(try stream.decompress(chunk, limit: maxDecodedBytes))
            } catch CodexZstdError.tooLarge(let decoded) {
                throw tooLarge(UInt64(decoded), limit: maxDecodedBytes)
            } catch {
                throw damaged()
            }
            offset += UInt64(chunk.count)
        }
        guard stream.isAtFrameEnd else { throw damaged() }
        return output
    }

    private static func tooLarge(_ bytes: UInt64, limit maxBytes: Int) -> Error {
        let size = Int64(clamping: bytes).formatted(.byteCount(style: .file))
        let limit = Int64(maxBytes).formatted(.byteCount(style: .file))
        return RemoteFileError(.failed, String(localized: "这份 Codex 记录是压缩过的，解开后至少有 \(size)，超过了这里能打开的上限（\(limit)）。可以在终端里用 codex resume 继续它。"))
    }

    private static func damaged() -> Error {
        RemoteFileError(.failed, String(localized: "这份 Codex 记录是压缩过的，但解不开（文件可能不完整或者坏了）。"))
    }
}
