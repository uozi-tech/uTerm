import Darwin

/// `uterm-holder` 与 App 之间的线上格式。holder 同时编进主程序（只放行这个文件和 `HolderOutputLog.swift`）。
///
/// **协议冻结**：holder 要活过 App 的多次升级，运行中的旧 holder 会遇到新 App。所以只能加新的帧类型，
/// 不能改已有帧的含义；双方都忽略不认识的帧，不断连。
///
/// 帧：`[u32 小端：kind + payload 的长度][u8 kind][payload]`。整数一律小端。
nonisolated enum HolderProtocol {
    static let version: UInt32 = 1
    /// 单帧上限。最大的帧是检查点（默认 3000 行约 200 KB，上限 20000 行）。超过视为对端出错，断开。
    static let maxFrameBytes = 64 * 1024 * 1024
    /// 回放时每帧输出的字节数。
    static let outputChunkBytes = 256 * 1024
}

nonisolated enum HolderFrameKind: UInt8, Sendable {
    // App → holder
    case hello = 1
    case attach = 2
    case input = 3
    case resize = 4
    case checkpoint = 5
    case setAttributes = 6
    case terminate = 7
    /// 给前台进程组发 SIGWINCH。尺寸没变时 `TIOCSWINSZ` 不会发，TUI 不知道要重画。
    case redraw = 8
    /// 让子进程确认连接还活着（发 SIGUSR1）。只有 `uterm-ssh` 会话才处理，本机 shell 收到这个信号会被杀。
    case probe = 9
    // holder → App
    case helloReply = 101
    case replayCheckpoint = 102
    case output = 103
    case replayEnd = 104
    case exited = 105
    /// 另一个客户端接入了这个会话，这条连接到此为止。
    case replaced = 106
}

nonisolated struct HolderFrame: Equatable, Sendable {
    /// 保留原始值：不认识的类型也要能被读出来再忽略。
    var kindRaw: UInt8
    var payload: [UInt8]

    var kind: HolderFrameKind? { HolderFrameKind(rawValue: kindRaw) }

    init(_ kind: HolderFrameKind, payload: [UInt8] = []) {
        self.kindRaw = kind.rawValue
        self.payload = payload
    }

    init(kindRaw: UInt8, payload: [UInt8]) {
        self.kindRaw = kindRaw
        self.payload = payload
    }

    func encoded() -> [UInt8] {
        var writer = HolderByteWriter()
        writer.u32(UInt32(payload.count + 1))
        writer.u8(kindRaw)
        writer.bytes(payload)
        return writer.bytes
    }
}

nonisolated struct HolderByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func bytes(_ value: [UInt8]) { bytes.append(contentsOf: value) }
}

/// 读不够就返回 nil，调用方把整帧当作无效。对端是另一个版本的程序，不能假定字段都在。
nonisolated struct HolderByteReader {
    private let bytes: [UInt8]
    private var cursor = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    private mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
        guard count <= bytes.count - cursor else { return nil }
        defer { cursor += count }
        return bytes[cursor..<(cursor + count)]
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
        guard let slice = take(MemoryLayout<T>.size) else { return nil }
        var value: T = 0
        for (index, byte) in slice.enumerated() { value |= T(truncatingIfNeeded: byte) << (index * 8) }
        return value
    }

    mutating func u8() -> UInt8? { integer(UInt8.self) }
    mutating func u16() -> UInt16? { integer(UInt16.self) }
    mutating func u32() -> UInt32? { integer(UInt32.self) }
    mutating func u64() -> UInt64? { integer(UInt64.self) }
    mutating func i32() -> Int32? { integer(UInt32.self).map(Int32.init(bitPattern:)) }
    mutating func rest() -> [UInt8] {
        defer { cursor = bytes.count }
        return Array(bytes[cursor...])
    }
}

/// 从字节流里切帧。
nonisolated struct HolderFrameReader {
    private var buffer = HolderByteQueue()

    enum Failure: Error { case frameTooLarge }

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        buffer.append(bytes)
    }

    mutating func next() throws -> HolderFrame? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.withReadable { raw -> Int in
            Int(UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24)
        }
        guard length >= 1, length <= HolderProtocol.maxFrameBytes else { throw Failure.frameTooLarge }
        guard buffer.count >= 4 + length else { return nil }
        let frame = buffer.withReadable { raw in
            HolderFrame(kindRaw: raw[4], payload: Array(raw[5..<(4 + length)]))
        }
        buffer.consume(4 + length)
        return frame
    }
}

/// 先进先出的字节队列。删头只移动下标，死前缀超过一半才整理：不用 `removeFirst`（每次搬动全部字节），
/// 也不会一直攥着已发走的内存。
nonisolated struct HolderByteQueue {
    private var storage: [UInt8] = []
    private var head = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    mutating func append(_ bytes: [UInt8]) {
        storage.append(contentsOf: bytes)
    }

    mutating func append(_ bytes: UnsafeRawBufferPointer) {
        storage.append(contentsOf: bytes)
    }

    func withReadable<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try storage.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[head...])) }
    }

    mutating func consume(_ count: Int) {
        head += count
        if head == storage.count {
            storage.removeAll(keepingCapacity: storage.capacity <= 64 * 1024)
            head = 0
        } else if head > storage.count / 2 {
            storage.removeFirst(head)
            head = 0
        }
    }
}

/// `helloReply` 的内容：会话的基本情况。App 列会话、接入前都看它。
nonisolated struct HolderHelloReply: Equatable, Sendable {
    var version: UInt32
    var shellPID: Int32
    var createdAt: UInt64
    var cols: UInt16
    var rows: UInt16
    /// shell 已退出、等 App 回来看最后一屏时非 nil。
    var exitStatus: Int32?
    var attributes: [UInt8]

    func encoded() -> [UInt8] {
        var writer = HolderByteWriter()
        writer.u32(version)
        writer.i32(shellPID)
        writer.u64(createdAt)
        writer.u16(cols)
        writer.u16(rows)
        writer.u8(exitStatus == nil ? 0 : 1)
        writer.i32(exitStatus ?? 0)
        writer.bytes(attributes)
        return writer.bytes
    }

    init(version: UInt32, shellPID: Int32, createdAt: UInt64, cols: UInt16, rows: UInt16, exitStatus: Int32?,
         attributes: [UInt8]) {
        self.version = version
        self.shellPID = shellPID
        self.createdAt = createdAt
        self.cols = cols
        self.rows = rows
        self.exitStatus = exitStatus
        self.attributes = attributes
    }

    init?(decoding payload: [UInt8]) {
        var reader = HolderByteReader(payload)
        guard let version = reader.u32(), let shellPID = reader.i32(), let createdAt = reader.u64(),
              let cols = reader.u16(), let rows = reader.u16(), let exited = reader.u8(),
              let status = reader.i32() else { return nil }
        self.init(version: version, shellPID: shellPID, createdAt: createdAt, cols: cols, rows: rows,
                  exitStatus: exited == 0 ? nil : status, attributes: reader.rest())
    }
}

/// App 上传的检查点：`blob` 是终端状态（对 holder 不透明），`offset` 是它对应的输出流位置。
/// 接回时：喂 `blob`，再喂 `offset` 之后的字节。
nonisolated struct HolderCheckpoint: Equatable, Sendable {
    var offset: UInt64
    var cols: UInt16
    var rows: UInt16
    /// 仅 holder → App：`offset` 之后的字节有一部分已被缓冲丢弃（App 不在期间输出太多）。
    var hasGap: Bool
    var blob: [UInt8]

    func encoded() -> [UInt8] {
        var writer = HolderByteWriter()
        writer.u64(offset)
        writer.u16(cols)
        writer.u16(rows)
        writer.u8(hasGap ? 1 : 0)
        writer.bytes(blob)
        return writer.bytes
    }

    init(offset: UInt64, cols: UInt16, rows: UInt16, hasGap: Bool, blob: [UInt8]) {
        self.offset = offset
        self.cols = cols
        self.rows = rows
        self.hasGap = hasGap
        self.blob = blob
    }

    init?(decoding payload: [UInt8]) {
        var reader = HolderByteReader(payload)
        guard let offset = reader.u64(), let cols = reader.u16(), let rows = reader.u16(),
              let gap = reader.u8() else { return nil }
        self.init(offset: offset, cols: cols, rows: rows, hasGap: gap != 0, blob: reader.rest())
    }
}
