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

    /// 关文件。调用方保证此时已没有在途的读写（见类型注释）。
    func close() async {
        try? await file.close()
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
        String(localized: "SFTP 读 \(String(offset)) 起的 \(expected) 字节只拿到 \(actual) 字节（数据不完整）")
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
    ///
    /// `paced`：这条连接上还开着交互终端时为 true，在途字节按送达情况限住（见 `SFTPUploadPacer`），
    /// 否则一传大文件，按键要排在几 MB 上传数据后面才发得出去。
    ///
    /// `progress`：每确认一片报一次「已写字节数 / 总字节数」，在调用方的任务里、调用方的隔离上调（不在子任务里）。
    /// 跑在调用方的隔离上（`isolation`）：从 actor / 主线程传进来的闭包按它所属的隔离调，不会在别的线程上被调到
    ///（那样 Swift 的运行时检查直接中断进程）。
    static func write(
        _ file: some SFTPPipelineFile,
        data: ByteBuffer,
        at base: UInt64,
        inFlight: Int = defaultInFlight,
        paced: Bool = false,
        isolation: isolated (any Actor)? = #isolation,
        progress: ((_ written: Int, _ total: Int) -> Void)? = nil
    ) async throws {
        var pacer = paced ? SFTPUploadPacer() : nil
        try await write(file, data: data, at: base, inFlight: inFlight, pacer: &pacer,
                        isolation: isolation, progress: progress)
    }

    /// 一片确认了：多少字节、什么时候发出、什么时候确认（`DispatchTime` 的纳秒）。
    private struct Acknowledgement: Sendable {
        var bytes: Int
        var sentAt: UInt64
        var ackedAt: UInt64
    }

    /// 同上，节奏由调用方持有：一个文件分好几段写时节奏跨段延续（不用每段重新量往返）。`pacer` 为 nil 时不按节奏。
    static func write(
        _ file: some SFTPPipelineFile,
        data: ByteBuffer,
        at base: UInt64,
        inFlight: Int = defaultInFlight,
        pacer: inout SFTPUploadPacer?,
        isolation: isolated (any Actor)? = #isolation,
        progress: ((_ written: Int, _ total: Int) -> Void)? = nil
    ) async throws {
        let total = data.readableBytes
        guard total > 0 else { return }
        let window = max(1, inFlight)
        var pace = pacer
        defer { pacer = pace }
        try await withThrowingTaskGroup(of: Acknowledgement.self) { group in
            // 捕获 `isolation`，闭包才跑在调用方的隔离上（SE-0420），`progress` 才在那里被调。
            _ = isolation
            var running = 0
            var outstanding = 0
            var start = 0
            var written = 0
            func acknowledged(_ ack: Acknowledgement) {
                running -= 1
                outstanding -= ack.bytes
                written += ack.bytes
                pace?.acknowledged(bytes: ack.bytes, sentAt: ack.sentAt, ackedAt: ack.ackedAt)
                progress?(written, total)
            }
            while start < total {
                try Task.checkCancellation()
                // 窗口满了（个数到顶，或在途字节到了节奏给的预算）：等最早完成的一个腾位置。它若失败，错误在这里抛出，
                // 退出 body 时 TaskGroup 自动取消并等待其余子任务。
                while running >= window || (running > 0 && pace?.allowsMore(outstanding: outstanding) == false) {
                    guard let ack = try await group.next() else { break }
                    acknowledged(ack)
                }
                let end = min(start + (pace?.chunkLength ?? chunkSize), total)
                guard let slice = data.getSlice(
                    at: data.readerIndex + start, length: end - start) else {
                    throw SFTPPipelineError.sliceOutOfRange
                }
                let offset = base + UInt64(start)
                let length = end - start
                let sentAt = DispatchTime.now().uptimeNanoseconds
                pace?.willSend(at: sentAt)
                group.addTask {
                    try await file.writeChunk(slice, at: offset)
                    // 每个 ack 都是一次进展：CLI 的静默看门狗靠它区分「慢」和「卡死」。
                    IOActivity.touch()
                    return Acknowledgement(bytes: length, sentAt: sentAt, ackedAt: DispatchTime.now().uptimeNanoseconds)
                }
                running += 1
                outstanding += length
                start = end
            }
            while let ack = try await group.next() { acknowledged(ack) }
        }
    }

    /// 一次从本机文件读多少交给流水线（内存里最多一段）。
    static let fileSegmentBytes = 4 * 1_048_576

    /// 把本机文件按段读出，逐段交给流水线写到远端从 0 起的位置。几百 MB 的视频也只占一段的内存。
    /// `paced` 同上，节奏跨段延续。
    ///
    /// `progress`：每确认一片报一次「已写字节数 / 文件总字节数」，同上在调用方的隔离上调。
    static func write(
        _ file: some SFTPPipelineFile,
        contentsOf localURL: URL,
        segmentBytes: Int = fileSegmentBytes,
        inFlight: Int = defaultInFlight,
        paced: Bool = false,
        isolation: isolated (any Actor)? = #isolation,
        progress: ((_ written: Int64, _ total: Int64) -> Void)? = nil
    ) async throws {
        let total = Int64(max(0, try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        let local = try FileHandle(forReadingFrom: localURL)
        defer { try? local.close() }
        var offset: UInt64 = 0
        var pacer = paced ? SFTPUploadPacer() : nil
        progress?(0, total)
        while let data = try local.read(upToCount: max(1, segmentBytes)), !data.isEmpty {
            try Task.checkCancellation()
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            let base = offset
            try await write(file, data: buffer, at: base, inFlight: inFlight, pacer: &pacer,
                            isolation: isolation) { written, _ in
                progress?(Int64(base) + Int64(written), max(total, Int64(base) + Int64(written)))
            }
            offset += UInt64(data.count)
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
            IOActivity.touch()
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

/// 和交互终端共用一条 SSH 连接时的上传节奏：按送达速率与最短往返限住在途字节。
///
/// 为什么要它：一条 SSH 连接上的各个通道（终端、SFTP）最后挤在同一条 TCP 上，先来先走。流水线固定压 64 个请求
///（≈2 MiB）时，慢网上（手机上行 1 Mbps）按键要排在这 2 MiB 后面十几秒才发得出去，看起来就是「上传期间打不了字」。
///
/// 闸门同 `RemoteLinkFlow`：在途 ≤ 送达速率 × (最短往返 + 30 ms) × 1.25 时才发下一片。链路吃得下时预算每轮涨
/// (1 + 30 ms / 往返) × 1.25 倍，一直涨到链路真正的上限，吞吐不掉；吃不下时链路里排着的只剩几十毫秒的量。
///
/// 往返量的是一片从发出到服务端确认，平时都含着排队，光取最小值会把排队当成往返、预算越涨越大。所以先单独发一小片
///（1 KB）量一次干净的往返（前面什么都没排），之后每 10 s 停一下、等在途的确认完再量一次。
/// 模拟读数见 `SFTPUploadPacerTests`：1 Mbps、往返 80 ms 时按键最多排 0.2 s（不按节奏 16 s），上传速率 97%。
nonisolated struct SFTPUploadPacer: Sendable {
    struct Config: Sendable {
        /// 允许在链路里排队的时长。
        var queueSlackNanos: UInt64 = 30_000_000
        var gain = 1.25
        /// 量往返的那一片多大。
        var probeChunk = 1024
        /// 片最小切到多大。
        var minimumChunk = 1024
        /// 多久重新量一次往返。
        var probeIntervalNanos: UInt64 = 10_000_000_000
        var rateWindowNanos: UInt64 = 2_000_000_000

        static let standard = Config()
    }

    private enum Phase: Equatable, Sendable {
        /// 等在途的都确认完，然后单独发一片量往返。
        case draining
        /// 量往返的那片在路上。
        case probing(sentAt: UInt64)
        case running
    }

    let config: Config

    init(config: Config = .standard) {
        self.config = config
    }

    private var phase = Phase.draining
    private var nextProbeAt: UInt64 = 0
    private var ackedBytes: UInt64 = 0
    private var lastAckedAt: UInt64 = 0
    /// 上次量往返以来的读数（往返, 片长）；第一个是量的那片。
    private var samples: [(trip: UInt64, bytes: Int)] = []
    private var acks: [(nanos: UInt64, bytes: UInt64)] = []
    private var rates: [(nanos: UInt64, value: Double)] = []

    /// 字节 / 秒。
    var deliveryRate: Double? { rates.map(\.value).max() }

    /// 最短往返（含这一片自己在链路上送的时间，所以量往返用一小片）。
    var minimumRoundTripNanos: UInt64? { samples.map(\.trip).min() }

    /// 在途字节的上限。还没量出来时是 0（只发量往返的那一片）。
    var budget: Int {
        guard let rate = deliveryRate, let trip = minimumRoundTripNanos else { return 0 }
        let seconds = Double(trip + config.queueSlackNanos) / 1e9
        return max(4 * config.minimumChunk, Int(rate * seconds * config.gain))
    }

    /// 下一片多大：量往返时是一小片；平时把预算切成至少 4 片、每片至多一个 SFTP 请求。确认要等整片送完才回来，
    /// 片太大时窗口里总有一整片在送、量出来的速率涨不上去。
    var chunkLength: Int {
        guard phase == .running else { return config.probeChunk }
        let budget = budget
        let pieces = max(4, (budget + SFTPPipeline.chunkSize - 1) / SFTPPipeline.chunkSize)
        return max(config.minimumChunk, min(SFTPPipeline.chunkSize, budget / pieces))
    }

    /// 在途 `outstanding` 字节时还能不能再发一片（在途最多比预算多一片：正在链路上送的那片）。
    /// 调用方在一片都没在途时总会发。
    func allowsMore(outstanding: Int) -> Bool {
        phase == .running && outstanding < budget
    }

    /// 要发一片了（`sentAt` 同 `acknowledged`）。等在途清空后发的这片就是量往返的。
    mutating func willSend(at sentAt: UInt64) {
        if phase == .draining { phase = .probing(sentAt: sentAt) }
    }

    /// 一片确认了。时刻是 `DispatchTime` 的纳秒（测试里是模拟的时钟）。
    mutating func acknowledged(bytes: Int, sentAt: UInt64, ackedAt: UInt64) {
        // 几个子任务几乎同时完成时，交回来的顺序和完成的先后可能差一点；时刻不往回走。
        let now = max(ackedAt, lastAckedAt)
        lastAckedAt = now
        ackedBytes &+= UInt64(bytes)
        let trip = now &- min(sentAt, now)
        if case .probing(let probeSentAt) = phase, probeSentAt == sentAt {
            samples = [(trip, bytes)]
            phase = .running
            nextProbeAt = now &+ config.probeIntervalNanos
            // 还没有速率时拿这一片垫底（偏低：分母含往返），之后一轮轮涨上去。
            if rates.isEmpty { rates.append((now, Double(bytes) / max(Double(trip) / 1e9, 1e-3))) }
        } else {
            samples.append((trip, bytes))
            if samples.count > 256 { samples.remove(at: 1) }
        }
        if phase == .running, now >= nextProbeAt { phase = .draining }
        // 送达速率：和至少一个往返（且至少 40 ms）之前的那次确认比。
        acks.append((now, ackedBytes))
        let span = max(minimumRoundTripNanos ?? 0, 40_000_000)
        if let base = acks.last(where: { now &- $0.nanos >= span }) {
            rates.append((now, Double(ackedBytes - base.bytes) / (Double(now &- base.nanos) / 1e9)))
        }
        acks.removeAll { now &- $0.nanos > config.rateWindowNanos }
        // 至少留一个读数：量往返之后头一个 2 s 里可能还没有新的。
        let fresh = rates.filter { now &- $0.nanos <= config.rateWindowNanos }
        rates = fresh.isEmpty ? Array(rates.suffix(1)) : fresh
    }
}
