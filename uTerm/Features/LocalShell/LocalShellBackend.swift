import Darwin
import Foundation

/// 本机 shell 的终端后端。shell 和伪终端都在 `uterm-holder` 里，App 退出、崩溃都不影响；这里只是连上去收发帧。
/// 连接由 XPC 服务建好交过来（见 `LocalShellAgentClient`）。
///
/// `close()` 结束 shell，`detach()` 只断开。退出原因分得开：holder 明说 shell 退出了（`exited`）、
/// 被别的客户端接走（`replaced`）、连接断了（holder 没了）。这三种对终端来说都是这条会话到头了。
actor LocalShellBackend: HeldTerminalBackend, TerminalImageReceiving {
    nonisolated let outputStream: AsyncStream<Data>
    nonisolated let exitStream: AsyncStream<Void>
    nonisolated let holderLink = HolderLink()
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let exitContinuation: AsyncStream<Void>.Continuation

    private let client: LocalShellAgentClient
    private let namespace: String
    private let sessionID: UUID
    private let initialColumns: Int
    private let initialRows: Int

    private var connection: HolderConnection?
    private var replay: HolderReplay?
    private var shellPID: Int32?
    private enum Teardown { case terminate, detach }
    /// 连接途中就被要求收尾时记在这，连上之后补做。
    private var teardown: Teardown?
    private var isFinished = false

    init(client: LocalShellAgentClient, namespace: String = LocalShellNamespace.current, sessionID: UUID = UUID(),
         columns: Int, rows: Int) {
        self.client = client
        self.namespace = namespace
        self.sessionID = sessionID
        initialColumns = max(1, columns)
        initialRows = max(1, rows)
        (outputStream, outputContinuation) = AsyncStream.makeStream(of: Data.self)
        (exitStream, exitContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    /// 本机 shell 的进程号（已结束 / 未启动时 nil）。
    var pid: Int32? { shellPID }

    func connect() async throws {
        let connection: HolderConnection
        let replay: HolderReplay
        do {
            (connection, replay) = try await openAndAttach()
        } catch let error as HolderSessionFailure {
            // 上一个 holder 正在退出时可能连上它又立刻断开（重新启动已退出的 shell）。socket 文件这时已经没了，再来一次就是新的。
            guard case .disconnected = error else { throw error }
            (connection, replay) = try await openAndAttach()
        }
        if let teardown {
            if teardown == .terminate { connection.send(HolderFrame(.terminate)) }
            connection.close()
            return
        }
        self.connection = connection
        self.replay = replay
        shellPID = replay.hello.shellPID
        holderLink.install(connection)
    }

    private func openAndAttach() async throws -> (HolderConnection, HolderReplay) {
        let handle = try await client.openSession(namespace: namespace, id: sessionID, columns: initialColumns, rows: initialRows)
        let connection = HolderConnection(handle)
        let output = outputContinuation
        let session = HolderSessionReceiver(output: output) { [weak self] in
            Task { await self?.ended() }
        }
        return try await withCheckedThrowingContinuation { continuation in
            session.onReplayFinished = { result in
                continuation.resume(with: result.map { (connection, $0) })
            }
            connection.onFrame = { session.receive($0) }
            connection.onClosed = { session.connectionClosed() }
            connection.start()
            connection.send(HolderFrame(.hello))
            connection.send(HolderFrame(.attach))
            // holder 卡死不能把窗口一直挂在「正在启动」。超过之后连接关掉，走上面的失败路径。
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak connection, weak session] in
                guard session?.isReplayPending == true else { return }
                connection?.close()
            }
        }
    }

    func takeReplay() -> HolderReplay? {
        defer { replay = nil }
        return replay
    }

    func write(_ data: Data) async {
        guard !isFinished else { return }
        connection?.send(HolderFrame(.input, payload: Array(data)))
    }

    /// 本机 shell 里的程序就在这台 Mac 上：图片放进系统剪贴板，再替用户按一下 Ctrl+V
    ///（Claude Code 等 CLI 在 Ctrl+V 时从剪贴板读图；不认得的程序最多收到一个 ^V）。
    func deliverImage(_ image: TerminalImage) async throws -> TerminalImageDelivery {
        guard connection != nil, !isFinished else { throw TerminalImageError.notConnected }
        RemotePasteboard.write(image)
        await write(Data([0x16]))
        return .clipboard
    }

    func resize(cols: UInt16, rows: UInt16) async {
        guard !isFinished else { return }
        var writer = HolderByteWriter()
        writer.u16(cols)
        writer.u16(rows)
        connection?.send(HolderFrame(.resize, payload: writer.bytes))
    }

    func setAttributes(_ attributes: Data) {
        connection?.send(HolderFrame(.setAttributes, payload: Array(attributes)))
    }

    func close() async {
        guard !isFinished else { return }
        teardown = .terminate
        connection?.send(HolderFrame(.terminate))
        shutDown()
    }

    func detach() async {
        guard !isFinished else { return }
        teardown = .detach
        shutDown()
    }

    private func shutDown() {
        isFinished = true
        holderLink.install(nil)
        connection?.close()
        connection = nil
        shellPID = nil
        outputContinuation.finish()
        exitContinuation.finish()
    }

    private func ended() {
        guard !isFinished else { return }
        // 先 yield 再 finish：finish 之后 yield 是空操作，会话结束就没人知道了。
        exitContinuation.yield()
        shutDown()
    }
}

nonisolated enum HolderSessionFailure: LocalizedError {
    case disconnected
    case badReply

    var errorDescription: String? {
        switch self {
        case .disconnected: return "本机终端的辅助进程断开了连接"
        case .badReply: return "本机终端的辅助进程回了看不懂的内容"
        }
    }
}

/// 收 holder 的帧：先攒回放，`replayEnd` 之后转成输出流。只在连接的队列上用。
nonisolated private final class HolderSessionReceiver: @unchecked Sendable {
    private let output: AsyncStream<Data>.Continuation
    private let onEnded: @Sendable () -> Void
    var onReplayFinished: (@Sendable (Result<HolderReplay, Error>) -> Void)?

    private var hello: HolderHelloReply?
    private var checkpoint: HolderCheckpoint?
    private var collected: [UInt8] = []
    private var isLive = false

    /// 其它线程只用它判断要不要放弃，读到旧值也只是晚一拍。
    private let pendingLock = NSLock()
    private var pending = true
    var isReplayPending: Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pending
    }

    init(output: AsyncStream<Data>.Continuation, onEnded: @escaping @Sendable () -> Void) {
        self.output = output
        self.onEnded = onEnded
    }

    func receive(_ frame: HolderFrame) {
        // 不认识的帧忽略：旧 App 可能连着新 holder。
        guard let kind = frame.kind else { return }
        switch kind {
        case .helloReply:
            hello = HolderHelloReply(decoding: frame.payload)
        case .replayCheckpoint:
            checkpoint = HolderCheckpoint(decoding: frame.payload)
        case .output:
            if isLive {
                output.yield(Data(frame.payload))
            } else {
                collected.append(contentsOf: frame.payload)
            }
        case .replayEnd:
            var reader = HolderByteReader(frame.payload)
            guard let hello, let checkpoint, let end = reader.u64() else {
                finishReplay(.failure(HolderSessionFailure.badReply))
                return
            }
            isLive = true
            finishReplay(.success(HolderReplay(hello: hello, checkpoint: checkpoint, output: collected, endOffset: end)))
            collected = []
        case .exited, .replaced:
            onEnded()
        case .hello, .attach, .input, .resize, .checkpoint, .setAttributes, .terminate, .redraw:
            break
        }
    }

    func connectionClosed() {
        if isReplayPending {
            finishReplay(.failure(HolderSessionFailure.disconnected))
        } else {
            onEnded()
        }
    }

    private func finishReplay(_ result: Result<HolderReplay, Error>) {
        pendingLock.lock()
        pending = false
        pendingLock.unlock()
        let finished = onReplayFinished
        onReplayFinished = nil
        finished?(result)
    }
}
