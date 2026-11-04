import Darwin
import Foundation

/// 到一个 `uterm-holder` 的连接：切帧、排队发送。socket 由 XPC 服务连好交过来（沙盒 app 连不了容器外的 socket）。
/// 收发都在自己的串行队列上；回调也在这条队列上。回调要在 `start()` 之前设好。
nonisolated final class HolderConnection: @unchecked Sendable {
    private let handle: FileHandle
    private let fd: Int32
    private let queue = DispatchQueue(label: "com.uozi.uTerm.HolderConnection")
    private var reader = HolderFrameReader()
    private var outgoing = HolderByteQueue()
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var isWriteArmed = false
    private var isClosed = false

    var onFrame: (@Sendable (HolderFrame) -> Void)?
    /// 连接断了（对端关闭、读写出错、或本端 `close()`）。只来一次。
    var onClosed: (@Sendable () -> Void)?

    init(_ handle: FileHandle) {
        self.handle = handle
        fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler { [weak self] in self?.readAvailable() }
        let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        write.setEventHandler { [weak self] in self?.flush() }
        // 两个源都取消完才释放 fd。
        let keepAlive = HolderSourceCounter(count: 2, handle: handle)
        read.setCancelHandler { keepAlive.sourceCancelled() }
        write.setCancelHandler { keepAlive.sourceCancelled() }
        queue.async {
            self.readSource = read
            self.writeSource = write
            read.resume()
        }
    }

    func send(_ frame: HolderFrame) {
        let bytes = frame.encoded()
        queue.async { [self] in
            guard !isClosed else { return }
            outgoing.append(bytes)
            flush()
        }
    }

    /// 尽量把已排队的字节写完再关。退出流程用：之后进程就没了，异步的写来不及。
    func flushAndClose(timeout: TimeInterval) {
        queue.sync { [self] in
            let deadline = Date().addingTimeInterval(timeout)
            while !isClosed, !outgoing.isEmpty, Date() < deadline {
                flush()
                if !outgoing.isEmpty {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&poller, 1, 50)
                }
            }
            shutDown()
        }
    }

    func close() {
        queue.async { [self] in
            flush()
            shutDown()
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count > 0 {
            buffer.withUnsafeBytes { reader.append(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            do {
                while !isClosed, let frame = try reader.next() { onFrame?(frame) }
            } catch {
                shutDown()
            }
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            shutDown()
        }
    }

    private func flush() {
        guard !isClosed else { return }
        while !outgoing.isEmpty {
            let written = outgoing.withReadable { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                outgoing.consume(written)
            } else if written < 0, errno == EINTR {
                continue
            } else if written < 0, errno == EAGAIN {
                if !isWriteArmed {
                    writeSource?.resume()
                    isWriteArmed = true
                }
                return
            } else {
                shutDown()
                return
            }
        }
        if isWriteArmed {
            writeSource?.suspend()
            isWriteArmed = false
        }
    }

    private func shutDown() {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        if !isWriteArmed { writeSource?.resume() }
        writeSource?.cancel()
        let closed = onClosed
        onClosed = nil
        onFrame = nil
        closed?()
    }
}

nonisolated private final class HolderSourceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int
    private var handle: FileHandle?

    init(count: Int, handle: FileHandle) {
        self.count = count
        self.handle = handle
    }

    func sourceCancelled() {
        lock.lock()
        count -= 1
        let last = count == 0
        let closing = last ? handle : nil
        if last { handle = nil }
        lock.unlock()
        try? closing?.close()
    }
}

/// 后端和发帧的人（终端会话要在主线程上同步发检查点）共用的把手。连接建立前发的帧直接丢。
nonisolated final class HolderLink: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: HolderConnection?

    func install(_ connection: HolderConnection?) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    private var current: HolderConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connection
    }

    func send(_ frame: HolderFrame) {
        current?.send(frame)
    }

    func checkpoint(offset: UInt64, cols: UInt16, rows: UInt16, blob: [UInt8]) {
        send(HolderFrame(.checkpoint, payload: HolderCheckpoint(offset: offset, cols: cols, rows: rows, hasGap: false, blob: blob).encoded()))
    }

    /// 退出流程用：写完（或超时）才返回。
    func flushAndClose(timeout: TimeInterval) {
        current?.flushAndClose(timeout: timeout)
    }
}

/// 接回一个会话时要补上的东西：`checkpoint.blob` + 它之后的字节。全新的会话这里只有 shell 刚输出的那点字节。
nonisolated struct HolderReplay: Sendable {
    var hello: HolderHelloReply
    var checkpoint: HolderCheckpoint
    var output: [UInt8]
    /// `output` 之后下一个字节在整条输出流里的位置。
    var endOffset: UInt64

    /// 这是接回了一个活了一段时间的会话，而不是刚起的 shell。
    var isReattach: Bool { !checkpoint.blob.isEmpty || checkpoint.hasGap }
}

/// 持有 PTY 的后端。`TerminalSession` 靠它恢复画面、存检查点。
protocol HeldTerminalBackend: TerminalBackend {
    nonisolated var holderLink: HolderLink { get }
    /// 取走接回时的回放（只给一次）。
    func takeReplay() async -> HolderReplay?
    /// 断开连接但不结束 shell：App 退出、被替换时用。
    func detach() async
}
