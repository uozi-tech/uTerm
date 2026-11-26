import Foundation

/// 远端 SQLite 库读不出来的几种情况（界面直接显示 `localizedDescription`）。
nonisolated enum SQLiteRemoteReadError: Error, Equatable, Sendable, LocalizedError {
    /// 库文件不在了（被删、会话被清掉）。
    case missing
    /// 主文件加 `-wal` 超过上限，不读。
    case tooLarge(bytes: UInt64, limit: Int)
    /// 不是 SQLite 的库。
    case notSQLite
    /// 读的时候一直在被改：前后两次看到的大小、时间或 WAL 头对不上，试了几次都这样。
    case unstable
    /// 打开或校验失败（读到的状态不完整，或者库本身坏了），试了几次都这样。
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .missing:
            return String(localized: "会话记录不见了")
        case .tooLarge(let bytes, let limit):
            let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
            let maximum = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            return String(localized: "会话记录有 \(size)，超过了能读的上限 \(maximum)")
        case .notSQLite:
            return String(localized: "会话记录不是 SQLite 数据库")
        case .unstable:
            return String(localized: "会话记录一直在写入，几次读到的都对不上，稍后再试")
        case .corrupt(let message):
            return String(localized: "会话记录读不了：\(message)")
        }
    }
}

/// 读的上限。
nonisolated struct SQLiteReadLimits: Equatable, Sendable {
    /// 主文件 + `-wal` 最多多大。整份读进内存（再加一份盖好 WAL 的库），所以要有个数。
    var maxTotalBytes: Int
    /// 前后对不上 / 校验失败时一共试几次。
    var attempts: Int

    static let standard = SQLiteReadLimits(maxTotalBytes: 64 * 1024 * 1024, attempts: 3)
}

/// 一个文件此刻的大小与修改时间（列目录得到）。
nonisolated struct SQLiteFileState: Equatable, Sendable {
    let size: UInt64
    let modifiedAt: Date?
}

/// 库的两个文件此刻的样子。两次一样就当没变（不再读字节）。
nonisolated struct SQLiteRemoteFingerprint: Equatable, Sendable {
    let main: SQLiteFileState
    /// 没有 `-wal`（或者是空的）为 nil。
    let wal: SQLiteFileState?

    var totalBytes: UInt64 { main.size + (wal?.size ?? 0) }
    /// 两个文件里新的那个修改时间。
    var modifiedAt: Date? { [main.modifiedAt, wal?.modifiedAt].compactMap { $0 }.max() }
}

/// 读一次的结果：用了哪份字节、读了多少（报数用）。
nonisolated struct SQLiteRemoteReadStats: Equatable, Sendable {
    var attempts = 0
    /// 这次从主机上实际读回来的字节（增量读 WAL 时远小于库的大小）。
    var bytesRead = 0
    var walFrames = 0
    var walCommittedFrames = 0
}

/// 经 `SFTPProviding` 只读地打开一份远端 SQLite 库：把主文件和 `-wal` 的字节读进内存，盖好 WAL 再在内存里打开
/// （`SQLiteMemoryDatabase`）。不往主机上写任何东西（不跑 `sqlite3`，它会写 `-shm`），本机也不落盘。
///
/// 怎么认出读到了写到一半的状态：先列一次目录记下两个文件的大小与时间，先读 WAL、再读主文件，读完再列一次、
/// 再读一次 WAL 头，任何一样对不上就重来（写的一方往 WAL 后面追加帧不会动已经写好的帧；把 WAL 并回主文件之后
/// 重置时会换 salt，头就变了）。打开后跑一次 `quick_check`，没过也重来。重来 `attempts` 次仍不行就报错。
///
/// 同一个读取器再读一次（会话还开着，跟着看新消息）：两个文件都没变就什么都不读；只有 WAL 变长了、头没变，
/// 只读上次最后一个提交帧之后新长出来的那段；主文件变了或 WAL 被重置才整份重读。
///
/// 不管旧式的回滚日志（`-journal`）：写的一方正在提交时读到的主文件可能不完整，`quick_check` 不一定看得出来。
actor SQLiteRemoteReader {
    let provider: any SFTPProviding
    let path: String
    let limits: SQLiteReadLimits

    private var walPath: String { path + "-wal" }
    private var directory: String { (path as NSString).deletingLastPathComponent }
    private var fileName: String { (path as NSString).lastPathComponent }

    /// 上一次读成功的字节，下次增量读用。
    private var cached: Cached?
    private struct Cached {
        let fingerprint: SQLiteRemoteFingerprint
        let main: Data
        let wal: Data
        let walIndex: SQLiteWALIndex?
    }

    private(set) var lastStats = SQLiteRemoteReadStats()

    init(provider: any SFTPProviding, path: String, limits: SQLiteReadLimits = .standard) {
        self.provider = provider
        self.path = path
        self.limits = limits
    }

    /// 两个文件此刻的大小与时间：列一次所在的目录（一次往返拿到两个）。列出来没带大小的退回 `stat`。
    func fingerprint() async throws -> SQLiteRemoteFingerprint {
        let entries: [RemoteEntry]
        do {
            entries = try await provider.list(path: directory)
        } catch {
            if (try? await provider.stat(path)) == nil { throw SQLiteRemoteReadError.missing }
            throw error
        }
        guard let main = entries.first(where: { $0.name.remoteKey == fileName.remoteKey && !$0.isDirectory }) else {
            throw SQLiteRemoteReadError.missing
        }
        let wal = entries.first(where: { $0.name.remoteKey == (fileName + "-wal").remoteKey && !$0.isDirectory })
        let mainState = try await state(of: main, at: path)
        var walState: SQLiteFileState?
        if let wal { walState = try await state(of: wal, at: walPath) }
        return SQLiteRemoteFingerprint(main: mainState, wal: (walState?.size ?? 0) > 0 ? walState : nil)
    }

    private func state(of entry: RemoteEntry, at path: String) async throws -> SQLiteFileState {
        if let size = entry.size { return SQLiteFileState(size: size, modifiedAt: entry.modifiedAt) }
        let stat = try await provider.stat(path)
        return SQLiteFileState(size: UInt64(max(0, stat.size)), modifiedAt: stat.mtime)
    }

    /// 读出最新的库交给 `body`（在这个读取器里同步执行，库不出这个调用）。`previous` 和此刻一样时什么都不读，返回 nil。
    /// `body` 里 SQLite 报库坏了（读到的状态不完整）也算一次失败，重读。
    func read<T: Sendable>(ifChangedFrom previous: SQLiteRemoteFingerprint? = nil,
                           _ body: @Sendable (SQLiteMemoryDatabase) throws -> T) async throws -> (fingerprint: SQLiteRemoteFingerprint, value: T)? {
        var stats = SQLiteRemoteReadStats()
        defer { lastStats = stats }
        var lastProblem: SQLiteRemoteReadError = .unstable
        let attempts = max(1, limits.attempts)
        for attempt in 1...attempts {
            stats.attempts = attempt
            guard let snapshot = try await fetch(stats: &stats) else { continue }
            if snapshot.fingerprint == previous, attempt == 1 { return nil }
            do {
                let database = try SQLiteMemoryDatabase(main: snapshot.main, wal: snapshot.wal, walIndex: snapshot.walIndex)
                try database.quickCheck()
                let value = try body(database)
                cached = snapshot
                stats.walFrames = snapshot.walIndex?.validFrames ?? 0
                stats.walCommittedFrames = snapshot.walIndex?.committedFrames ?? 0
                return (snapshot.fingerprint, value)
            } catch let error as SQLiteError where error.isCorruption {
                // 字节对不上：缓存的也不可信，整份重读。
                cached = nil
                lastProblem = .corrupt(error.message)
            }
        }
        throw lastProblem
    }

    /// 读一份前后一致的字节；中途发现变了返回 nil（由调用方重来）。
    private func fetch(stats: inout SQLiteRemoteReadStats) async throws -> Cached? {
        let before = try await fingerprint()
        guard before.totalBytes <= UInt64(limits.maxTotalBytes) else {
            throw SQLiteRemoteReadError.tooLarge(bytes: before.totalBytes, limit: limits.maxTotalBytes)
        }
        if let cached, cached.fingerprint == before { return cached }

        // 先读 WAL：读主文件的时候即便正好在把 WAL 并回去，并回去的也只是这里已经读到的帧，盖上去是同样的内容。
        var wal = Data()
        // WAL 没了（并回之后截成 0）或被重置过：主文件一定被改过，哪怕列目录看不出来（同一秒、大小没变）也要重读。
        var walReset = before.wal == nil && cached?.wal.isEmpty == false
        if let state = before.wal {
            if let cached, let index = cached.walIndex, state.size >= UInt64(index.committedEnd) {
                let header = try await readExactly(walPath, offset: 0, length: SQLiteWAL.headerBytes, stats: &stats)
                guard let header else { return nil }
                if header == index.header {
                    let start = index.committedEnd
                    guard let tail = try await readExactly(walPath, offset: UInt64(start), length: Int(state.size) - start,
                                                           stats: &stats) else { return nil }
                    wal = cached.wal.prefix(start) + tail
                } else {
                    walReset = true
                }
            }
            if wal.isEmpty {
                guard let full = try await readExactly(walPath, offset: 0, length: Int(state.size), stats: &stats) else { return nil }
                wal = full
                if cached != nil { walReset = true }
            }
        }

        let main: Data
        if let cached, cached.fingerprint.main == before.main, !walReset {
            main = cached.main
        } else {
            guard let full = try await readExactly(path, offset: 0, length: Int(before.main.size), stats: &stats) else { return nil }
            main = full
        }

        let after = try await fingerprint()
        guard after == before else { return nil }
        let index = SQLiteWAL.index(wal)
        if !wal.isEmpty {
            // 头在读的这段时间里被重置过（同一秒里、大小没变的话列目录看不出来）。
            guard let header = try await readExactly(walPath, offset: 0, length: SQLiteWAL.headerBytes, stats: &stats),
                  header == wal.prefix(SQLiteWAL.headerBytes) else { return nil }
        }
        return Cached(fingerprint: before, main: main, wal: wal, walIndex: index)
    }

    /// 读 `[offset, offset + length)`；读回来的比要的短（文件变短了）返回 nil。
    private func readExactly(_ path: String, offset: UInt64, length: Int, stats: inout SQLiteRemoteReadStats) async throws -> Data? {
        guard length > 0 else { return Data() }
        let data = try await provider.readRange(path, offset: offset, length: length)
        stats.bytesRead += data.count
        return data.count == length ? data : nil
    }
}
