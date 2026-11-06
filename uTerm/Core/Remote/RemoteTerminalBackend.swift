import Foundation

/// 远控终端后端：接入 Mac 上一个正在运行的终端，接进现有的 `MobileTerminalController`
///（与 SSH 同一个 `TerminalBackend` 抽象，终端视图与键盘条零改动）。
///
/// - 输出：第一帧是 Mac 发来的快照（以 RIS 开头），之后是原始字节，原样喂给 SwiftTerm。
/// - 输入 / 尺寸：直接交给连接发出去，不经过主线程。手机的行列数就是终端的行列数（接管尺寸），
///   每次变化 Mac 都会调整 PTY 并重发一份快照。
/// - 断线：在后端内部按退避重连并重新接入，快照到了屏幕自然对齐。控制器看到的是一条不断的流；
///   只有 Mac 明确结束了这个终端（关闭、被别的设备接管）才当作会话结束。
actor RemoteTerminalBackend: TerminalImageReceiving {
    nonisolated let outputStream: AsyncStream<Data>
    nonisolated let exitStream: AsyncStream<Void>
    /// 断线重连的进度：true = 断了正在重连（这期间的输入发不出去），false = 接回了。界面据此提示。
    nonisolated let reconnecting: AsyncStream<Bool>
    private let reconnectingContinuation: AsyncStream<Bool>.Continuation
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let exitContinuation: AsyncStream<Void>.Continuation

    private let client: RemoteMacClient
    private let sessionID: UUID
    private var size = RemoteGridSize(cols: 80, rows: 24)
    private var attachment: RemoteAttachment?
    private var isClosed = false
    private var reconnectTask: Task<Void, Never>?

    init(client: RemoteMacClient, sessionID: UUID) {
        self.client = client
        self.sessionID = sessionID
        (outputStream, outputContinuation) = AsyncStream<Data>.makeStream()
        (exitStream, exitContinuation) = AsyncStream<Void>.makeStream()
        (reconnecting, reconnectingContinuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func connect() async throws {
        try await attach()
    }

    private func attach() async throws {
        let output = outputContinuation
        let sink = RemoteChannelSink(
            onOutput: { output.yield($0) },
            onClosed: { [weak self] reason, ended in
                Task { await self?.channelClosed(reason: reason, sessionEnded: ended) }
            }
        )
        let requested = size
        let attached = try await client.attach(sessionID: sessionID, size: requested, sink: sink)
        // 接入请求在路上时标签已经关了：close() 那会儿还没有 attachment 可 detach，这里补上，
        // 否则 Mac 上的会话一直按手机尺寸、标成被手机接管。
        guard !isClosed else {
            await client.detach(attached)
            return
        }
        attachment = attached
        reconnectingContinuation.yield(false)
        // 接入请求在路上时视图可能刚布局完、报来了真实尺寸（那时还没有通道，发不出去）：补发一次。
        if size != requested {
            attached.link.send(RemoteMessage(.resize, channel: attached.channel, payload: size.encoded()))
        }
    }

    func write(_ data: Data) {
        guard let attachment else { return }
        attachment.link.send(RemoteMessage(.input, channel: attachment.channel, payload: data))
    }

    /// 交给 Mac 处理（它知道这个终端是本机 shell 还是 SSH）。
    /// 手机上的程序读不到 Mac 剪贴板；这个后端只在手机端用，本来也不走 Mac 的粘贴判断。
    nonisolated var programsCanReadMacClipboard: Bool { false }

    func deliverImage(_ image: TerminalImage) async throws -> TerminalImageDelivery {
        guard let attachment else { throw TerminalImageError.notConnected }
        return try await client.sendTerminalImage(image, over: attachment)
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard cols > 0, rows > 0 else { return }
        let next = RemoteGridSize(cols: cols, rows: rows)
        guard next != size || attachment == nil else { return }
        size = next
        guard let attachment else { return }
        attachment.link.send(RemoteMessage(.resize, channel: attachment.channel, payload: next.encoded()))
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        reconnectingContinuation.finish()
        reconnectTask?.cancel()
        reconnectTask = nil
        if let attachment {
            await client.detach(attachment)
        }
        attachment = nil
        outputContinuation.finish()
        exitContinuation.finish()
    }

    func verifyConnectionAlive() async -> Bool {
        attachment != nil || reconnectTask != nil
    }

    private func channelClosed(reason: String, sessionEnded: Bool) {
        attachment = nil
        guard !isClosed else { return }
        if sessionEnded {
            end(reason)
            return
        }
        reconnectingContinuation.yield(true)
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in await self?.reconnectLoop() }
    }

    /// 连接断了（Wi-Fi 切换、App 被挂起、Mac 睡眠唤醒）：退避重连，接上后 Mac 会先发一份快照。
    /// App 在后台时任务本来就被挂起，回到前台自然继续，不需要另外接生命周期事件。
    private func reconnectLoop() async {
        var delay: Duration = .milliseconds(500)
        while !Task.isCancelled && !isClosed {
            if await client.retryGate.wait(delay) { delay = .milliseconds(500) }
            guard !Task.isCancelled, !isClosed else { break }
            do {
                try await attach()
                break
            } catch RemoteAttachError.rejected(let message) {
                end(message)
                break
            } catch {
                delay = min(delay * 2, .seconds(5))
            }
        }
        reconnectTask = nil
    }

    private func end(_ reason: String) {
        isClosed = true
        reconnectingContinuation.finish()
        let note = "\r\n\u{1b}[2m[\(reason.isEmpty ? "远程会话已结束" : reason)]\u{1b}[0m\r\n"
        outputContinuation.yield(Data(note.utf8))
        exitContinuation.yield(())
        exitContinuation.finish()
        outputContinuation.finish()
    }
}
