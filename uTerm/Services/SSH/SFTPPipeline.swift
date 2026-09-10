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

/// 服务端在**不该短**的地方短给了。
///
/// 两种来源，都表示数据不完整，绝不能当成「读到头了」静默收尾：
/// - `requireFullLength` 的读（调用方先 `stat` 过，知道这段一定存在）拿到的段没读满；
/// - 某段读到 0 字节（EOF）之后，**后面**的段却又有数据 —— 中间凭空多出一个空洞，
///   这是服务端异常，不是文件到头。
///
/// 回归的是一个真实的数据完整性事故：一次短读 / 空读会让 12 MiB 的下载在 116 KiB
/// 处「成功」收尾，本地文件缺 99%，而且没有任何人报错。
nonisolated struct SFTPShortReadError: Error, Sendable, Equatable {
    /// 出问题那一段的**绝对**起点。
    let offset: UInt64
    /// 该段期望的字节数（EOF 之后的段期望 0）。
    let expected: Int
    /// 实际拿到的字节数。
    let actual: Int

    var localizedDescription: String {
        "SFTP 读 \(offset) 起的 \(expected) 字节只拿到 \(actual) 字节（数据不完整）"
    }
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

    /// 读 `[offset, offset + length)`。按 `chunkSize` 分段并发发 READ，段内**短读补发**
    /// （只有「读到 0 字节」才算这一段到头）。
    ///
    /// 两种收尾口径，由 `requireFullLength` 选：
    /// - `false`（默认，长度未知）：第一个「没读满」的段就是 EOF，返回的字节数会少于
    ///   `length`。但 EOF **之后**的段必须也是空的 —— 后段还有数据说明中间凭空多了个
    ///   空洞，抛 `SFTPShortReadError`，绝不把带洞的数据当成功交出去。
    /// - `true`（调用方先 `stat` 过，这 `length` 个字节一定存在）：任何一段没读满都是
    ///   `SFTPShortReadError`。下载路径走这一档 —— 一次短读就静默收尾的下载等于悄悄丢数据。
    static func read(
        _ file: some SFTPPipelineFile,
        offset: UInt64,
        length: Int,
        inFlight: Int = defaultInFlight,
        requireFullLength: Bool = false
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
        var reachedEOF = false
        for index in 0..<segments {
            let want = min(chunkSize, length - index * chunkSize)
            let base = offset + UInt64(index * chunkSize)
            // 每段都有账（TaskGroup 跑完才到这里）；缺一段只可能是本文件算错了下标。
            guard var piece = collected[index] else {
                throw SFTPShortReadError(offset: base, expected: want, actual: 0)
            }
            let got = piece.readableBytes
            if reachedEOF {
                // 已经到头了，后面的段必须也是空的；有数据 = 中间是个空洞。
                guard got == 0 else {
                    throw SFTPShortReadError(offset: base, expected: 0, actual: got)
                }
                continue
            }
            if got < want {
                guard !requireFullLength else {
                    throw SFTPShortReadError(offset: base, expected: want, actual: got)
                }
                reachedEOF = true
            }
            result.writeBuffer(&piece)
        }
        return result
    }

    /// 一段的读取：服务端可以少给（SFTP 允许短读），就在**同一 offset 上继续补发**，
    /// 直到读满 `length` 或读到 0 字节。
    ///
    /// 只有「读到 0 字节」才是这一段的终点；返回值短于 `length` 一律交给
    /// `read(_:offset:length:)` 按上面两种口径裁决，本函数自己不下 EOF 的结论。
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
            // 服务端多给（协议不允许，但别让它撑爆调用方的算术）：只收要的那部分。
            if count > length - done {
                guard var head = piece.readSlice(length: length - done) else { break }
                buffer.writeBuffer(&head)
                done = length
                break
            }
            buffer.writeBuffer(&piece)
            done += count
        }
        return buffer
    }
}
