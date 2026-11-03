import Darwin
import Foundation

/// 本机 shell 的终端后端：shell 由辅助进程起（见 `LocalShellService`），伪终端主端的 fd 交过来以后，
/// 读写都在这里直接对 fd 做，不再经过辅助进程；只有调尺寸、结束走 XPC。
///
/// 读：fd 设成非阻塞，读源在自己的队列上把能读的一次读完再交给 `outputStream`。读到 0 或出错（shell 退出后
/// 从端全部关闭，主端读返回 EIO）就是会话结束，`exitStream` 产出一个元素。
/// 写：键盘字节很少，偶尔粘贴一大段；写满内核缓冲（EAGAIN）就 poll 等可写再继续，不丢字节。
actor LocalShellBackend: TerminalBackend {
    nonisolated let outputStream: AsyncStream<Data>
    nonisolated let exitStream: AsyncStream<Void>
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let exitContinuation: AsyncStream<Void>.Continuation

    private let client: LocalShellAgentClient
    private let initialColumns: Int
    private let initialRows: Int
    private let readQueue = DispatchQueue(label: "com.uozi.uTerm.LocalShell.read")

    private var handle: LocalShellHandle?
    private var readSource: DispatchSourceRead?
    private var closed = false

    init(client: LocalShellAgentClient, columns: Int, rows: Int) {
        self.client = client
        initialColumns = max(1, columns)
        initialRows = max(1, rows)
        (outputStream, outputContinuation) = AsyncStream.makeStream(of: Data.self)
        (exitStream, exitContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    /// 本机 shell 的进程号（已结束 / 未启动时 nil）。
    var pid: Int32? { handle?.pid }

    func connect() async throws {
        let opened = try await client.openShell(columns: initialColumns, rows: initialRows)
        guard !closed else {
            client.terminate(pid: opened.pid)
            return
        }
        handle = opened
        let fd = opened.master.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        let output = outputContinuation
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var chunk = Data()
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    chunk.append(buffer, count: count)
                    if chunk.count >= 256 * 1024 { break }
                    continue
                }
                if count < 0, errno == EAGAIN || errno == EINTR { break }
                // 0 = 对端关闭；其余错误（EIO：shell 已退出、从端全关）同样是会话结束。
                if !chunk.isEmpty { output.yield(chunk) }
                Task { await self?.ended() }
                return
            }
            if !chunk.isEmpty { output.yield(chunk) }
        }
        // fd 由读源的取消回调关：取消与正在跑的读在同一条队列上串行，关之后不会再有人读它。
        let master = opened.master
        source.setCancelHandler { try? master.close() }
        readSource = source
        source.resume()
    }

    func write(_ data: Data) async {
        guard let fd = handle?.master.fileDescriptor, !closed else { return }
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written > 0 {
                    pointer += written
                    remaining -= written
                } else if written < 0, errno == EAGAIN || errno == EINTR {
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&poller, 1, 1000)
                } else {
                    return
                }
            }
        }
    }

    func resize(cols: UInt16, rows: UInt16) async {
        guard let pid = handle?.pid, !closed else { return }
        client.resize(pid: pid, columns: Int(cols), rows: Int(rows))
    }

    func close() async {
        guard !closed else { return }
        closed = true
        if let pid = handle?.pid { client.terminate(pid: pid) }
        finish()
    }

    private func ended() {
        guard !closed else { return }
        closed = true
        finish()
        exitContinuation.yield()
    }

    private func finish() {
        readSource?.cancel()
        readSource = nil
        handle = nil
        outputContinuation.finish()
        exitContinuation.finish()
    }
}
