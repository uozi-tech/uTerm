import Darwin
import Foundation
import NIOCore

/// CLI 大文件传输引擎：**一次传输 = 一条 IPC 请求**，并行在 uTerm 里面做。
///
/// 客户端（utermctl）打开本地文件，经 `SCM_RIGHTS` 把 fd 交过来；这里用最多 `channels`
/// 条 SFTP 会话（各自一条 SSH 连接）并发跑流水线，**每到一个 32 000 B 的回包就直接
/// `pwrite` 进那个 fd**（上传反过来 `pread` 出来发走）。文件字节从不经过 IPC、不做
/// base64、不在内存里攒段，所以：
/// - 并行度与 IPC 槽位脱钩：16 个传输槽位就是 16 个并发传输，每个传输自己开多少路由
///   `Tuning` 决定；
/// - 内存只和在途请求有关：每条通道 `inFlight × 32 000 B`；
/// - 沙盒进程往 fd 里写过的文件照样会被系统打上 `com.apple.quarantine`（实测，哪怕文件
///   是客户端建的）；客户端不在沙盒里，下载成功后由它去掉。
///
/// 工作分配：待传区间切成 `segmentBytes` 的段放进共享队列，每个工作者一次领一段、把段内
/// 的请求接在自己的流水线后面**连续**发（段与段之间不排空），整段落盘后回调 `onSegment`
/// —— 客户端据此记续传账。某条通道出错：它手上没做完的段退回队列交给别的工作者，那条
/// 会话从池里丢弃；同一段最多重试 `maxSegmentAttempts - 1` 次，全部工作者都倒下才整体失败。
nonisolated enum ParallelTransfer {

    struct Tuning: Sendable, Equatable {
        /// 这次传输最多用几条 SFTP 会话（还受池子的每主机上限约束）。
        var channels: Int
        /// 每条会话的在途请求数（× 32 000 B = 这条会话的在途字节）。
        var inFlight: Int
        /// 传输用 SSH 连接的通道窗口（字节）。每条会话的在途字节被它封顶。
        var windowBytes: Int
        /// 工作分配与续传的粒度。
        var segmentBytes: Int

        /// 下载：窗口 16 MiB、在途 640（≈ 20 MB，刚好压满窗口）。50 ms RTT 下单条连接
        /// 从 1 MiB 窗口的 8.8 MiB/s 提到 55 MiB/s，8 条 279 MiB/s（旧的逐片 IPC 协议
        /// 32 路才 93）。窗口在这里是**我们**的接收窗口，只对下载起作用。
        static let download = Tuning(
            channels: ControlProtocol.defaultTransferChannels, inFlight: 640,
            windowBytes: 16 << 20, segmentBytes: 8 << 20)
        /// 上传：在途量由**服务端**的接收窗口（OpenSSH 约 2 MiB）封顶，我们这边窗口多大
        /// 都一样；实测在途 128 与 640 同速（8 路约 110 MiB/s），取小的省内存。
        static let upload = Tuning(
            channels: ControlProtocol.defaultTransferChannels, inFlight: 128,
            windowBytes: 16 << 20, segmentBytes: 8 << 20)
        /// 传输连接统一用的窗口（池里的 SFTP 会话上下行共用）。
        static let standard = download

        func with(channels: Int) -> Tuning {
            var copy = self
            copy.channels = channels
            return copy
        }
    }

    typealias ByteRange = ControlByteRange

    enum TransferError: Error, LocalizedError {
        /// 远端给的字节比 `stat` 说的少：文件在传输期间被改了，或服务端出岔子。
        case shortRead(offset: Int64)
        /// 本地 fd 读写失败（errno 原话）。
        case localIO(String)
        /// 续传区间超出文件大小。
        case invalidRange(ByteRange, size: Int64)
        /// 上传完远端大小与本地对不上。
        case sizeMismatch(local: Int64, remote: Int64)

        var errorDescription: String? {
            switch self {
            case .shortRead(let offset):
                return String(localized: "远端在 \(String(offset)) 处提前结束（传输期间文件被改了？）")
            case .localIO(let message):
                return message
            case .invalidRange(let range, let size):
                return String(localized: "区间 [\(String(range.offset)), \(String(range.end))) 超出文件大小 \(String(size))")
            case .sizeMismatch(let local, let remote):
                return String(localized: "上传后远端大小 \(String(remote)) 与本地 \(String(local)) 不一致")
            }
        }
    }

    static let maxSegmentAttempts = 3

    // MARK: - 下载

    /// 远端 → `fd`。返回远端文件大小。`ranges` 为 nil = 整份；给了就只补这些区间（续传）。
    /// 下载开始前把 `fd` 截成远端大小（续传时已写的部分不受影响）。
    static func download(
        host: HostConnectionSpec,
        pool: any ControlConnectionPooling,
        remotePath: String,
        fd: Int32,
        ranges: [ByteRange]?,
        tuning: Tuning,
        onSize: @Sendable (Int64) -> Void = { _ in },
        onSegment: @escaping @Sendable (ByteRange) -> Void
    ) async throws -> Int64 {
        let size = try await pool.withSFTP(for: host) { try await $0.stat(remotePath).size }
        onSize(size)
        guard ftruncate(fd, off_t(size)) == 0 else { throw localError(String(localized: "截断本地文件失败")) }
        let wanted = try validated(ranges, size: size)
        try await run(
            host: host, pool: pool, remotePath: remotePath, writeMode: nil,
            segments: split(wanted, segmentBytes: tuning.segmentBytes), tuning: tuning,
            onSegment: onSegment
        ) { file, offset, length in
            try await readChunk(from: file, offset: offset, length: length, into: fd)
        }
        return size
    }

    // MARK: - 上传

    /// `fd` → 远端。`mode` 只作用于整份上传的开头（`create` 已存在即失败 / `overwrite`
    /// 截断）；给了 `ranges`（续传）就不再动远端已有内容。返回本地文件大小。
    static func upload(
        host: HostConnectionSpec,
        pool: any ControlConnectionPooling,
        fd: Int32,
        remotePath: String,
        mode: SFTPWriteMode,
        ranges: [ByteRange]?,
        tuning: Tuning,
        onSize: @Sendable (Int64) -> Void = { _ in },
        onSegment: @escaping @Sendable (ByteRange) -> Void
    ) async throws -> Int64 {
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else { throw localError(String(localized: "读取本地文件大小失败")) }
        let size = Int64(info.st_size)
        onSize(size)
        let wanted = try validated(ranges, size: size)
        if ranges == nil {
            // 覆盖语义只在这里定一次：之后所有工作者都用不截断的 `.write` 并行写。
            try await pool.withSFTP(for: host) { sftp in
                let handle = try await sftp.openTransferHandle(remotePath, writeMode: mode)
                await handle.close()
            }
        }
        try await run(
            host: host, pool: pool, remotePath: remotePath, writeMode: .write,
            segments: split(wanted, segmentBytes: tuning.segmentBytes), tuning: tuning,
            onSegment: onSegment
        ) { file, offset, length in
            try await writeChunk(to: file, offset: offset, length: length, from: fd)
        }
        let remote = try await pool.withSFTP(for: host) { try await $0.stat(remotePath).size }
        guard remote == size else { throw TransferError.sizeMismatch(local: size, remote: remote) }
        return size
    }

    // MARK: - 调度

    /// 一个请求单位：`(文件, 起点, 长度)` → 搬完这一小块。
    private typealias ChunkOperation = @Sendable (any SFTPPipelineFile, Int64, Int) async throws -> Void

    private static func run(
        host: HostConnectionSpec,
        pool: any ControlConnectionPooling,
        remotePath: String,
        writeMode: SFTPWriteMode?,
        segments: [ByteRange],
        tuning: Tuning,
        onSegment: @escaping @Sendable (ByteRange) -> Void,
        operation: @escaping ChunkOperation
    ) async throws {
        guard !segments.isEmpty else { return }
        let queue = SegmentQueue(segments)
        let workers = max(1, min(tuning.channels, segments.count))
        let window = max(1, tuning.inFlight)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    await worker(host: host, pool: pool, remotePath: remotePath, writeMode: writeMode,
                                 queue: queue, window: window, onSegment: onSegment, operation: operation)
                }
            }
        }
        try Task.checkCancellation()
        if let failure = queue.failure { throw failure }
    }

    /// 一个工作者：借一条会话、开一次文件，然后不停领段、把段内请求接在流水线后面发。
    /// 出错时退回手上所有没做完的段、丢弃这条会话，自己退出（别的工作者接着干）。
    private static func worker(
        host: HostConnectionSpec,
        pool: any ControlConnectionPooling,
        remotePath: String,
        writeMode: SFTPWriteMode?,
        queue: SegmentQueue,
        window: Int,
        onSegment: @escaping @Sendable (ByteRange) -> Void,
        operation: @escaping ChunkOperation
    ) async {
        guard queue.hasWork else { return }
        let session: any SFTPProviding
        do {
            session = try await borrow(host: host, pool: pool)
        } catch {
            queue.workerFailed(holding: [], error: error)
            return
        }
        var held: [Int: Int64] = [:]   // 段号 → 还差多少字节
        var opened: SFTPTransferHandle?
        do {
            let handle = try await session.openTransferHandle(remotePath, writeMode: writeMode)
            opened = handle
            try await withThrowingTaskGroup(of: (Int, Int).self) { group in
                var running = 0
                var cursor: (index: Int, range: ByteRange, next: Int64)?

                func nextChunk() -> (index: Int, offset: Int64, length: Int)? {
                    if cursor == nil || cursor!.next >= cursor!.range.end {
                        guard !Task.isCancelled, let (index, range) = queue.take() else { return nil }
                        cursor = (index, range, range.offset)
                        held[index] = range.length
                    }
                    let length = Int(min(Int64(SFTPPipeline.chunkSize), cursor!.range.end - cursor!.next))
                    defer { cursor!.next += Int64(length) }
                    return (cursor!.index, cursor!.next, length)
                }

                let file = handle.file
                while running < window, let chunk = nextChunk() {
                    group.addTask { try await operation(file, chunk.offset, chunk.length); return (chunk.index, chunk.length) }
                    running += 1
                }
                while let (index, length) = try await group.next() {
                    running -= 1
                    IOActivity.touch()
                    if let remaining = held[index] {
                        if remaining - Int64(length) <= 0 {
                            held[index] = nil
                            let range = queue.complete(index)
                            onSegment(range)
                        } else {
                            held[index] = remaining - Int64(length)
                        }
                    }
                    if let chunk = nextChunk() {
                        group.addTask { try await operation(file, chunk.offset, chunk.length); return (chunk.index, chunk.length) }
                        running += 1
                    }
                }
            }
            await handle.close()
            await pool.returnSFTP(session, for: host.id)
        } catch {
            queue.workerFailed(holding: Array(held.keys), error: error)
            await opened?.close()
            await pool.discardSFTP(session, for: host.id)
        }
    }

    /// 借会话：建连失败（sshd 忙着丢连接、网络抖一下）退避再试两次；主机密钥问题不重试。
    private static func borrow(host: HostConnectionSpec, pool: any ControlConnectionPooling) async throws -> any SFTPProviding {
        var attempt = 0
        while true {
            do {
                return try await pool.borrowSFTP(for: host)
            } catch let error as ControlConnectError where error.fingerprint == nil && attempt < 2 {
                attempt += 1
                try await Task.sleep(for: .milliseconds(500 * attempt))
            }
        }
    }

    // MARK: - 单块搬运

    private static func readChunk(from file: any SFTPPipelineFile, offset: Int64, length: Int, into fd: Int32) async throws {
        var done = 0
        while done < length {
            let piece = try await file.readChunk(from: UInt64(offset) + UInt64(done), length: UInt32(length - done))
            let count = piece.readableBytes
            // 大小是 stat 定的，读到 0 字节只能是文件在传输期间变短了。
            guard count > 0 else { throw TransferError.shortRead(offset: offset + Int64(done)) }
            // 服务端多给（协议不允许）也只收要的那部分。
            let useful = min(count, length - done)
            try piece.withUnsafeReadableBytes { raw in
                try pwriteAll(fd, UnsafeRawBufferPointer(rebasing: raw.prefix(useful)), at: offset + Int64(done))
            }
            done += useful
        }
    }

    private static func writeChunk(to file: any SFTPPipelineFile, offset: Int64, length: Int, from fd: Int32) async throws {
        var buffer = ByteBufferAllocator().buffer(capacity: length)
        let read = try buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: length) { raw in
            try preadAll(fd, raw, count: length, at: offset)
        }
        guard read == length else { throw TransferError.localIO(String(localized: "本地文件在 \(String(offset)) 处提前结束（上传期间被改短了？）")) }
        try await file.writeChunk(buffer, at: UInt64(offset))
    }

    private static func pwriteAll(_ fd: Int32, _ raw: UnsafeRawBufferPointer, at offset: Int64) throws {
        var written = 0
        while written < raw.count {
            let n = pwrite(fd, raw.baseAddress! + written, raw.count - written, off_t(offset) + off_t(written))
            if n < 0 {
                if errno == EINTR { continue }
                throw localError(String(localized: "写本地文件失败"))
            }
            written += n
        }
    }

    private static func preadAll(_ fd: Int32, _ raw: UnsafeMutableRawBufferPointer, count: Int, at offset: Int64) throws -> Int {
        var got = 0
        while got < count {
            let n = pread(fd, raw.baseAddress! + got, count - got, off_t(offset) + off_t(got))
            if n < 0 {
                if errno == EINTR { continue }
                throw localError(String(localized: "读本地文件失败"))
            }
            if n == 0 { break }
            got += n
        }
        return got
    }

    /// `what` 延后求值：先读 errno，再查文案（查本地化表可能动到 errno）。
    private static func localError(_ what: @autoclosure () -> String) -> TransferError {
        let reason = String(cString: strerror(errno))
        return .localIO(String(localized: "\(what())：\(reason)", comment: "本地文件操作失败：系统错误原文"))
    }

    // MARK: - 区间

    static func validated(_ ranges: [ByteRange]?, size: Int64) throws -> [ByteRange] {
        guard let ranges else { return size > 0 ? [ByteRange(offset: 0, length: size)] : [] }
        for range in ranges where range.offset < 0 || range.length < 0 || range.end > size {
            throw TransferError.invalidRange(range, size: size)
        }
        return ranges.filter { $0.length > 0 }
    }

    static func split(_ ranges: [ByteRange], segmentBytes: Int) -> [ByteRange] {
        let step = Int64(max(SFTPPipeline.chunkSize, segmentBytes))
        var segments: [ByteRange] = []
        for range in ranges {
            var offset = range.offset
            while offset < range.end {
                let length = min(step, range.end - offset)
                segments.append(ByteRange(offset: offset, length: length))
                offset += length
            }
        }
        return segments
    }
}

/// 待传段的共享队列。工作者在各自的 Task 里同步领 / 交，所以是带锁的类。
private nonisolated final class SegmentQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let segments: [ParallelTransfer.ByteRange]
    private var pending: [Int]
    private var attempts: [Int: Int] = [:]
    private var outstanding: Int
    private var fatal: (any Error)?
    private var lastError: (any Error)?

    init(_ segments: [ParallelTransfer.ByteRange]) {
        self.segments = segments
        self.pending = Array(segments.indices.reversed())
        self.outstanding = segments.count
    }

    var hasWork: Bool { lock.withLock { fatal == nil && !pending.isEmpty } }

    func take() -> (Int, ParallelTransfer.ByteRange)? {
        lock.withLock {
            guard fatal == nil, let index = pending.popLast() else { return nil }
            return (index, segments[index])
        }
    }

    func complete(_ index: Int) -> ParallelTransfer.ByteRange {
        lock.withLock {
            outstanding -= 1
            return segments[index]
        }
    }

    /// 工作者倒下：它手上的段退回队列（超过重试次数就整体判失败）。
    func workerFailed(holding indices: [Int], error: any Error) {
        lock.withLock {
            lastError = error
            if error is CancellationError { fatal = error; return }
            for index in indices {
                let tried = (attempts[index] ?? 1) + 1
                attempts[index] = tried
                if tried > ParallelTransfer.maxSegmentAttempts {
                    fatal = error
                    return
                }
                pending.append(index)
            }
        }
    }

    /// 结束后的判定：有段没传完（所有工作者都倒下了，或被判致命）就是失败。
    var failure: (any Error)? {
        lock.withLock {
            if let fatal { return fatal }
            return outstanding > 0 ? (lastError ?? CancellationError()) : nil
        }
    }
}
