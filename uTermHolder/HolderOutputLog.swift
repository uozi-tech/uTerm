/// 会话输出的环形缓冲：最近 `capacity` 字节，以及它们在整条输出流里的位置。
///
/// 存储按需翻倍，安静的 shell 不占 16 MiB。写满后原地覆盖，再大的洪水也不增长。
nonisolated struct HolderOutputLog {
    static let defaultCapacity = 16 * 1024 * 1024

    private let capacity: Int
    private var storage: [UInt8]
    /// 整条输出流到目前为止的长度。
    private(set) var endOffset: UInt64 = 0

    init(capacity: Int = HolderOutputLog.defaultCapacity) {
        self.capacity = max(1, capacity)
        self.storage = [UInt8](repeating: 0, count: min(64 * 1024, self.capacity))
    }

    /// 还留着的最早字节的位置。
    var startOffset: UInt64 { endOffset - min(endOffset, UInt64(storage.count)) }

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        growIfNeeded(toFit: min(UInt64(capacity), endOffset + UInt64(bytes.count)))
        // 只有最后 storage.count 字节留得下。
        let kept = bytes.count > storage.count ? UnsafeRawBufferPointer(rebasing: bytes[(bytes.count - storage.count)...]) : bytes
        let start = Int((endOffset + UInt64(bytes.count - kept.count)) % UInt64(storage.count))
        let first = min(kept.count, storage.count - start)
        storage.withUnsafeMutableBytes { target in
            target.baseAddress!.advanced(by: start).copyMemory(from: kept.baseAddress!, byteCount: first)
            if first < kept.count {
                target.baseAddress!.copyMemory(from: kept.baseAddress!.advanced(by: first), byteCount: kept.count - first)
            }
        }
        endOffset += UInt64(bytes.count)
    }

    /// 存储还没到容量时环从没绕过（每次写之前都先长够），字节就从 0 开始放着，整段拷过去位置不变。
    private mutating func growIfNeeded(toFit needed: UInt64) {
        guard UInt64(storage.count) < needed else { return }
        var size = storage.count
        while UInt64(size) < needed { size = min(size * 2, capacity) }
        var grown = [UInt8](repeating: 0, count: size)
        grown.replaceSubrange(0..<Int(endOffset), with: storage[0..<Int(endOffset)])
        storage = grown
    }

    /// 取 `offset` 开始最多 `maxBytes` 字节。`offset` 不在缓冲范围内返回 nil。比较在前、相减在后：
    /// `offset` 来自对端，不能让它算出溢出。
    func read(from offset: UInt64, maxBytes: Int) -> [UInt8]? {
        guard offset >= startOffset, offset <= endOffset else { return nil }
        let count = Int(min(UInt64(maxBytes), endOffset - offset))
        guard count > 0 else { return [] }
        let start = Int(offset % UInt64(storage.count))
        let first = min(count, storage.count - start)
        return Array(storage[start..<(start + first)]) + Array(storage[0..<(count - first)])
    }
}
