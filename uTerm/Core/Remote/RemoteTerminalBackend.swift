import Foundation

/// 远控终端后端：接入 Mac 上一个正在运行的终端，接进现有的 `MobileTerminalController`
///（与 SSH 同一个 `TerminalBackend` 抽象，终端视图与键盘条零改动）。
///
/// - 输出：先是 Mac 发来的整屏快照（影子终端的二进制快照，输出泵把它还原进本地影子终端、再回放进画面），
///   之后是原始字节。两种都按到达顺序进 `outputItems`。
/// - 输入 / 尺寸：直接交给连接发出去，不经过主线程。手机的行列数就是终端的行列数（接管尺寸），
///   每次变化 Mac 都会调整 PTY 并重发一份快照。
/// - 断线：在后端内部按退避重连并重新接入，快照到了屏幕自然对齐。控制器看到的是一条不断的流；
///   只有 Mac 明确结束了这个终端（关闭、被别的设备接管）才当作会话结束。
actor RemoteTerminalBackend: TerminalImageReceiving, TerminalVideoReceiving {
    nonisolated let outputItems: AsyncStream<TerminalOutputItem>
    nonisolated var mirrorsRemoteGrid: Bool { true }
    nonisolated let exitStream: AsyncStream<Void>
    /// 断线重连的进度：true = 断了正在重连（这期间的输入发不出去），false = 接回了。界面据此提示。
    nonisolated let reconnecting: AsyncStream<Bool>
    private let reconnectingContinuation: AsyncStream<Bool>.Continuation
    private let outputContinuation: AsyncStream<TerminalOutputItem>.Continuation
    /// 正在收的那张快照（分段到达）。只在连接队列上读写。
    private nonisolated let snapshotAssembly = SnapshotAssembly()
    private let exitContinuation: AsyncStream<Void>.Continuation

    nonisolated let client: RemoteMacClient
    nonisolated let sessionID: UUID
    private var size = RemoteGridSize(cols: 80, rows: 24)
    private var attachment: RemoteAttachment?
    private var isClosed = false
    private var reconnectTask: Task<Void, Never>?
    /// 通道断开（`channelClosed`）的次数。接入要等 Mac 回话，等的这段时间里断开了就作废这次接入，见 `attach`。
    private var channelCloses = 0
    /// 有没有人在看这个标签（前台标签且 App 在前台）。决定断线久了以后退避能不能放长，见 `RemoteReconnectPolicy`。
    /// 放在锁里而不是 actor 状态：界面切标签时同步写进来，几次快速切换不会因为异步任务乱序而留下旧值。
    /// 默认 true：不告诉它的调用方（Mac 端、测试）保持以前的退避。
    private nonisolated let watchLock = NSLock()
    private nonisolated(unsafe) var watchedStorage = true
    /// 接入的是不是 Mac 的本机 shell（会话列表里的 `serverID`）。只有它收文件：传到 Mac 上的路径 shell 里的程序读得到，
    /// Mac 上开着的 SSH 终端读不到。每次接上从会话列表刷新；同 `watchedStorage`，放在锁里给 `receivesFiles` 同步读。
    private nonisolated(unsafe) var localShellStorage = false

    /// 视频和文件传到 Mac 上的哪个目录。测试宿主带沙盒，换成自己的临时目录。
    nonisolated let uploadDirectory: String

    init(client: RemoteMacClient, sessionID: UUID, uploadDirectory: String = "/private/tmp") {
        self.client = client
        self.sessionID = sessionID
        self.uploadDirectory = uploadDirectory
        (outputItems, outputContinuation) = AsyncStream<TerminalOutputItem>.makeStream()
        (exitStream, exitContinuation) = AsyncStream<Void>.makeStream()
        (reconnecting, reconnectingContinuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func connect() async throws {
        do {
            try await attach()
        } catch RemoteProtocolError.closed where reconnectTask != nil {
            // 接上的那一刻连接就断了，`channelClosed` 已经排上了重连：不算连接失败，交给重连接回。
        }
    }

    private func attach() async throws {
        let output = outputContinuation
        let assembly = snapshotAssembly
        let sink = RemoteChannelSink(
            onOutput: { output.yield(.bytes($0)) },
            onSnapshot: { piece, isFirst, isLast in
                if let snapshot = assembly.append(piece, isFirst: isFirst, isLast: isLast),
                   let restorable = RemoteTerminalReplay.restorable(snapshot) {
                    output.yield(.snapshot(restorable))
                }
            },
            onClosed: { [weak self] reason, ended in
                Task { await self?.channelClosed(reason: reason, sessionEnded: ended) }
            }
        )
        let requested = size
        let closesBefore = channelCloses
        let attached = try await client.attach(sessionID: sessionID, size: requested, sink: sink)
        // 接入请求在路上时标签已经关了：close() 那会儿还没有 attachment 可 detach，这里补上，
        // 否则 Mac 上的会话一直按手机尺寸、标成被手机接管。
        guard !isClosed else {
            await client.detach(attached)
            return
        }
        // Mac 回了「接入成功」，紧接着连接就断了（回前台时常见）：主线程先处理断开、通道的关闭通知先到了这里，
        // 接入的结果排在后面才交回来，拿到的是那条已经关掉的连接。不能收下：重连循环会以为接上了而退出，
        // 标签从此挂在死连接上，输出不来、按键发不出去。抛出去让重连循环再试。
        guard channelCloses == closesBefore else { throw RemoteProtocolError.closed }
        attachment = attached
        let sessionID = sessionID
        let local = await client.sessions.first { $0.id == sessionID }?.serverID == RemoteConstants.localShellServerID
        watchLock.withLock { localShellStorage = local }
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

    /// 图片交给 Mac 处理（它知道这个终端是本机 shell 还是 SSH）。
    /// 手机上的程序读不到 Mac 剪贴板；这个后端只在手机端用，本来也不走 Mac 的粘贴判断。
    nonisolated var programsCanReadMacClipboard: Bool { false }

    func deliverImage(_ image: TerminalImage) async throws -> TerminalImageDelivery {
        guard let attachment else { throw TerminalImageError.notConnected }
        return try await client.sendTerminalImage(image, over: attachment)
    }

    /// Mac 的本机 shell 收视频和文件；Mac 上的 SSH 终端只收图片（见 `TerminalVideoReceiving`）。
    nonisolated var receivesFiles: Bool { watchLock.withLock { localShellStorage } }

    /// 视频和文件经文件通道传成 Mac 上 `/private/tmp` 下一个只有自己能读写的文件，返回路径（调用方粘进终端，
    /// 终端里的 Agent 自己去读）。按段从本机文件读着传，不整份进内存；老版本 Mac 不认文件请求时直说。
    func deliverVideo(_ video: TerminalVideo) async throws -> String {
        guard attachment != nil else { throw TerminalImageError.notConnected }
        guard receivesFiles else {
            throw TerminalImageError.unsupported(String(localized: "Mac 上的 SSH 终端还不能贴视频和文件，只能贴图片"))
        }
        let path = video.temporaryRemotePath(in: uploadDirectory)
        let files = RemoteMacFileProvider(client: client)
        // 进度回调在传输的子任务上：接收方在这里先取出来。
        let sink = PasteProgressReporter.sink
        sink?(PasteProgress(.sending, fraction: 0))
        try await files.upload(localURL: video.localURL, toRemotePath: path) { progress in
            let fraction = progress.bytesTotal > 0 ? Double(progress.bytesDone) / Double(progress.bytesTotal) : 1
            sink?(PasteProgress(.sending, fraction: fraction))
        }
        try? await files.setPermissions(path: path, mode: 0o600)
        return path
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

    /// 界面告诉后端这个标签此刻有没有人看。从没人看变成有人看时立刻叫醒重连：它可能正睡在最长一分钟的退避里，
    /// 用户切过来不能对着「正在重连」干等。叫醒的是同一台 Mac 的所有等待者，它们同时醒来会合并成一次建连
    ///（`RemoteMacClient.connect` 复用在途的那次）；没在重连时没有等待者，叫醒什么也不做。
    nonisolated func setWatched(_ watched: Bool) {
        let becameWatched = watchLock.withLock { () -> Bool in
            defer { watchedStorage = watched }
            return watched && !watchedStorage
        }
        if becameWatched { client.retryGate.kick() }
    }

    private nonisolated var isWatched: Bool { watchLock.withLock { watchedStorage } }

    func verifyConnectionAlive() async -> Bool {
        attachment != nil || reconnectTask != nil
    }

    private func channelClosed(reason: String, sessionEnded: Bool) {
        attachment = nil
        channelCloses += 1
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
    /// 退避节奏见 `RemoteReconnectPolicy`：有人看着时与以前一样封顶 5 秒；没人看且断了很久才放长。
    private func reconnectLoop() async {
        let outageStart = ContinuousClock.now
        var failures = 0
        while !Task.isCancelled && !isClosed {
            let delay = RemoteReconnectPolicy.delay(failures: failures, outage: ContinuousClock.now - outageStart,
                                                    watched: isWatched)
            if await client.retryGate.wait(delay) { failures = 0 }
            guard !Task.isCancelled, !isClosed else { break }
            do {
                try await attach()
                break
            } catch RemoteAttachError.rejected(let message) {
                end(message)
                break
            } catch {
                failures += 1
            }
        }
        reconnectTask = nil
    }

    private func end(_ reason: String) {
        isClosed = true
        reconnectingContinuation.finish()
        let note = "\r\n\u{1b}[2m[\(reason.isEmpty ? "远程会话已结束" : reason)]\u{1b}[0m\r\n"
        outputContinuation.yield(.bytes(Data(note.utf8)))
        exitContinuation.yield(())
        exitContinuation.finish()
        outputContinuation.finish()
    }
}

nonisolated extension RemoteTerminalReplay {
    /// 收齐的一张交给输出泵之前：二进制快照原样；回放流（Mac 的引擎快照格式和本机不互认）按带来的网格在本机引擎里重画，
    /// 拍成本机格式的快照。重画失败、或 Mac 生成回放流失败发来的空的一张，返回 nil（不还原，画面从之后的字节接着画）。
    /// 在连接队列上调，重画一张几毫秒到几十毫秒。
    static func restorable(_ snapshot: Data) -> Data? {
        guard !snapshot.isEmpty else { return nil }
        guard let replay = decode(snapshot) else { return snapshot }
        return ShadowTerminal.snapshot(redrawing: replay.stream, cols: replay.cols, rows: replay.rows,
                                       scrollbackLines: redrawScrollback)
    }

    /// 重画用的临时终端的回滚上限：回放流只带 `RemoteConstants.snapshotScrollback` 行（引擎按页裁，实际略少），留足余量。
    private static let redrawScrollback = RemoteConstants.snapshotScrollback * 4
}

/// 把分段到达的快照拼起来。回调都在同一条连接队列上，按顺序来；换了连接（重连）时新快照的第一段会把旧的顶掉。
nonisolated final class SnapshotAssembly: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: Data?

    /// 收齐了返回整张快照。
    func append(_ piece: Data, isFirst: Bool, isLast: Bool) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if isFirst {
            // 整张一段就到齐了：直接交出去，不再拷进缓冲。
            if isLast {
                buffer = nil
                return piece
            }
            buffer = Data()
        }
        // 没见过开头的中间段（接入前的残留）：丢掉。
        guard buffer != nil else { return nil }
        buffer?.append(piece)
        guard isLast else { return nil }
        defer { buffer = nil }
        return buffer
    }
}
