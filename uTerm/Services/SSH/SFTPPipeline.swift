import Foundation
import Citadel
import NIOCore

/// 流水线读写需要的最小文件面 —— 只有「在某个 offset 写一片」「从某个 offset 读一段」。
///
/// 抽出来是为了让 `SFTPPipelineTests` 能塞一个会计数在途请求的假实现：真实的
/// `Citadel.SFTPFile` 只能靠一条活着的 SSH 通道拿到，单测里造不出来。
nonisolated protocol SFTPPipelineFile: Sendable {
    /// 写一片（调用方保证 ≤ `SFTPPipeline.chunkSize`，即一个 SFTP WRITE 请求）。
    func writeChunk(_ data: ByteBuffer, at offset: UInt64) async throws
    /// 读一段；服务端可以少给（短读 / EOF），由调用方补发。
    func readChunk(from offset: UInt64, length: UInt32) async throws -> ByteBuffer
}

/// 把 `Citadel.SFTPFile` 包成 `SFTPPipelineFile`。
///
/// `@unchecked Sendable` 的依据：`SFTPFile` 唯一的可变状态是 `isActive`（只在
/// `close()` 里翻），读写路径只读它，随后全部转给 `SFTPClient`（本身 `Sendable`：
/// requestId 走 `NIOLockedValueBox`，`sendRequest` 一律 `eventLoop.flatSubmit`
/// 到通道自己的 EventLoop 上串行执行，requestId→promise 表也只在那条线程上改）。
/// 因此并发调用 `write` / `read` 是安全的 —— 前提是**不与 `close()` 并发**，
/// 本文件的两个入口都在流水线跑完之后才关文件。
nonisolated struct CitadelPipelineFile: SFTPPipelineFile, @unchecked Sendable {
    private let file: SFTPFile

    init(_ file: SFTPFile) { self.file = file }

    func writeChunk(_ data: ByteBuffer, at offset: UInt64) async throws {
        // 片长 ≤ 32 000，`SFTPFile.write` 内部循环只会发一个请求。
        try await file.write(data, at: offset)
    }

    func readChunk(from offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        try await file.read(from: offset, length: length)
    }
}

nonisolated enum SFTPPipelineError: Error, Sendable, Equatable {
    /// 内部错误：切片越界（只可能是本文件的算术写错了）。
    case sliceOutOfRange
}

/// SFTP 的**流水线**读写：一条 SFTP 通道上同时压 `inFlight` 个请求，而不是
/// 每 32 000 B 一个串行往返。
///
/// 为什么这样就快：`SFTPClient.sendRequest` 按 requestId → promise 映射，天生允许
/// 同一通道多请求并发；瓶颈从来是 `SFTPFile.write(_:at:)` 内部「发一片 → 等 ack →
/// 再发下一片」的串行循环（8 MiB = 262 个往返，13 ms RTT 就是 3.9 s）。把切片摊到
/// TaskGroup 里并发发，耗时退化成 `总片数 / inFlight × RTT` + 带宽时间。
///
/// 两个常量不要乱调：
/// - `chunkSize` = 32 000 B 是 Citadel 照 swift-nio-ssh #99 定的单请求上限；
/// - `inFlight` = 64（≈2 MiB 在途）在 LAN 与广域网都够吃满，再大只是压通道窗口。
nonisolated enum SFTPPipeline {

    /// 单个 SFTP READ / WRITE 请求的净荷上限（Citadel 同款常量，见 swift-nio-ssh #99）。
    static let chunkSize = 32_000

    /// 默认在途请求数（≈ 64 × 32 000 B = 2 MiB）。
    static let defaultInFlight = 64

    // MARK: - 写

    /// 把 `data` 按 `chunkSize` 切片写到 `base` 起的区间，最多 `inFlight` 个请求同时在途。
    ///
    /// 任一片失败 → TaskGroup 取消其余、等它们收尾，然后把**原错误**抛出去
    ///（不包一层，`ControlFilePayloadBuilder.errorCode(for:)` 还要认服务端状态码）。
    static func write(
        _ file: some SFTPPipelineFile,
        data: ByteBuffer,
        at base: UInt64,
        inFlight: Int = defaultInFlight
    ) async throws {
        let total = data.readableBytes
        guard total > 0 else { return }
        let window = max(1, inFlight)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0
            var start = 0
            while start < total {
                try Task.checkCancellation()
                if running >= window {
                    // 窗口满了：等最早完成的一个腾位置。它若失败，错误在这里抛出，
                    // 退出 body 时 TaskGroup 自动取消并等待其余子任务。
                    try await group.next()
                    running -= 1
                }
                let end = min(start + chunkSize, total)
                guard let slice = data.getSlice(
                    at: data.readerIndex + start, length: end - start) else {
                    throw SFTPPipelineError.sliceOutOfRange
                }
                let offset = base + UInt64(start)
                group.addTask { try await file.writeChunk(slice, at: offset) }
                running += 1
                start = end
            }
            try await group.waitForAll()
        }
    }

    // MARK: - 读

    /// 读 `[offset, offset + length)`。按 `chunkSize` 分段并发发 READ，段内**短读补发**；
    /// 撞到 EOF 时返回的字节数会少于 `length`（调用方据此判文件到头）。
    ///
    /// 拼装时遇到第一个「没读满」的段就停 —— 它是 EOF，后面的段全在文件之外，
    /// 即便某个后段因为文件在传输期间变长而拿到了数据，也不能接在空洞后面。
    static func read(
        _ file: some SFTPPipelineFile,
        offset: UInt64,
        length: Int,
        inFlight: Int = defaultInFlight
    ) async throws -> ByteBuffer {
        guard length > 0 else { return ByteBuffer() }
        let window = max(1, inFlight)
        let segments = (length + chunkSize - 1) / chunkSize
        var collected: [Int: ByteBuffer] = [:]
        try await withThrowingTaskGroup(of: (Int, ByteBuffer).self) { group in
            var running = 0
            var next = 0
            while next < segments {
                try Task.checkCancellation()
                if running >= window, let done = try await group.next() {
                    collected[done.0] = done.1
                    running -= 1
                }
                let index = next
                let start = index * chunkSize
                let want = min(chunkSize, length - start)
                let base = offset + UInt64(start)
                group.addTask {
                    (index, try await readSegment(file, at: base, length: want))
                }
                running += 1
                next += 1
            }
            while let done = try await group.next() {
                collected[done.0] = done.1
            }
        }
        var result = ByteBuffer()
        result.reserveCapacity(length)
        for index in 0..<segments {
            guard var piece = collected[index] else { break }
            let want = min(chunkSize, length - index * chunkSize)
            let got = piece.readableBytes
            result.writeBuffer(&piece)
            if got < want { break }   // 短读 = EOF，后面的段不要
        }
        return result
    }

    /// 一段的读取：服务端可以少给（SFTP 允许短读），就对剩下的区间补发，
    /// 直到读满 `length` 或读到 0 字节（EOF）。
    private static func readSegment(
        _ file: some SFTPPipelineFile,
        at base: UInt64,
        length: Int
    ) async throws -> ByteBuffer {
        var buffer = ByteBuffer()
        var done = 0
        while done < length {
            try Task.checkCancellation()
            var piece = try await file.readChunk(
                from: base + UInt64(done), length: UInt32(length - done))
            let count = piece.readableBytes
            if count == 0 { break }
            buffer.writeBuffer(&piece)
            done += count
        }
        return buffer
    }
}
