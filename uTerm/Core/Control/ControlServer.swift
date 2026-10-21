import Darwin
import Foundation
import OSLog

/// Unix domain socket 服务端：一次连接 = 一条 JSON 请求 + 一条 JSON 响应。
///
/// 结构照搬 uService 的 `ServiceControlServer`（同一套并发不变式在那边已经被真实
/// 使用磨过）：所有可能阻塞的 socket I/O 都留在 GCD 队列上，只有 handler 那一跳进
/// Swift 并发；`token` 区分复用了同一个 FD 号的不同连接，让「handler 超时」与
/// 「handler 晚到」不会各关一次同一个 fd。
nonisolated final class ControlServer: @unchecked Sendable {
    typealias RequestHandler = @MainActor @Sendable (ControlRequest) async -> ControlResponse
    typealias AcceptConnection = @Sendable (Int32) -> Int32

    private enum ClientPhase: Sendable {
        /// A clientQueue worker owns poll/recv and must perform the final close.
        case reading
        /// No socket worker is active while the MainActor handler is suspended.
        case handling
        /// A clientQueue worker has won the response race and owns send/close.
        case completing
    }

    /// `token` distinguishes different connections that happen to reuse the same
    /// numeric FD. This is essential once a handler deadline can close a socket
    /// before the late MainActor handler eventually returns.
    private struct ActiveClient {
        let token: UInt64
        let generation: UInt64
        var phase: ClientPhase
        var handlerTimer: DispatchSourceTimer?
        /// 上一次往这条连接写东西（心跳 / 进度行）的时刻（uptime ns）。只在 `.handling`
        /// 阶段有意义。
        var lastHeartbeat: UInt64 = 0
        /// 处理期间还没写出去的字节（进度行写了一半）。收尾时先把它写完再写响应，
        /// 行才不会被响应截断。
        var pendingOutbound = Data()
        /// handler 的任务：客户端断开（写心跳 / 进度撞 EPIPE）或 `stop()` 时取消它 ——
        /// 没人要结果的传输不该继续占着带宽和 SFTP 通道。
        var handlerTask: Task<Void, Never>?
        /// 占的是传输槽位（`sftp-get` / `sftp-put` / `run -t`），见 `maxTransferClients`。
        var isTransfer = false
    }

    private enum Admission {
        case started
        /// 连接已经不是这一代的了（stop / 重启），不回响应直接收尾。
        case stale
        /// 传输槽位满了：回 `server_busy`，客户端退避重试。
        case transferBusy
    }

    /// handler 最近一次「有进展」的时刻。handler 通过 `IOActivity.touch()` 打点
    /// （SFTP 每个回包、`run` 看门狗的每一拍），监督定时器据此判静默。
    private final class ProgressClock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = DispatchTime.now().uptimeNanoseconds

        func touch() {
            let now = DispatchTime.now().uptimeNanoseconds
            lock.withLock { last = now }
        }

        func idleNanoseconds(now: UInt64) -> UInt64 {
            lock.withLock { now > last ? now - last : 0 }
        }
    }

    static let shared = ControlServer()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.uozi.uTerm",
        category: "ControlServer"
    )

    private let socketURL: URL
    private let acceptQueue = DispatchQueue(label: "com.uozi.uTerm.control-server.accept")
    /// All potentially-blocking socket I/O lives on this GCD queue, never on a
    /// Swift cooperative-executor worker. `activeClients` bounds the number of
    /// concurrent jobs that can occupy this queue.
    private let clientQueue = DispatchQueue(
        label: "com.uozi.uTerm.control-server.clients",
        qos: .utility,
        attributes: .concurrent
    )
    private let stateLock = NSLock()
    /// 同时持有的连接总数（含还在读请求的）。超了在 accept 时就回 `server_busy`。
    private let maxActiveClients: Int
    /// 其中传输请求最多占多少。**剩下的永远留给 `run` / `ping` / `sftp-ls` 这类短请求**：
    /// 并行分片传输一次就要好几条连接，与短请求共用一个池子的话，两三个下载就能把
    /// `run` 挤成 `server_busy`。传输槽位的上限也是内存上限：一片在途约 30 MB
    /// （8 MiB 原文 + base64 + JSON 编码的拷贝）。
    private let maxTransferClients: Int
    private let ioTimeoutNanoseconds: UInt64
    private let handlerIdleTimeoutNanoseconds: UInt64
    private let heartbeatIntervalNanoseconds: UInt64
    /// 监督定时器的拍子：进度间隔、心跳间隔、静默预算 1/4 三者取小。
    private let supervisionTickNanoseconds: UInt64
    /// 传输进度行最快多久发一行。
    private static let progressInterval: TimeInterval = 0.5
    private let requestHandler: RequestHandler
    private let acceptConnection: AcceptConnection
    private var listenFD: Int32 = -1
    private var running = false
    private var generation: UInt64 = 0
    private var nextClientToken: UInt64 = 0
    private var activeClients: [Int32: ActiveClient] = [:]

    init(
        socketURL: URL = ControlProtocol.socketURL,
        maxActiveClients: Int = ControlProtocol.maxControlClients + ControlProtocol.maxTransferClients,
        maxTransferClients: Int = ControlProtocol.maxTransferClients,
        ioTimeout: TimeInterval = 5,
        // 静默预算，不是总时长：handler 只要还在 `IOActivity.touch()`（SFTP 回包、
        // `run` 看门狗）就一直续期；连续这么久没有任何进展才判它卡死、回
        // `handler_timeout` 放掉 FD。`run` 的超时由它自己的看门狗管，不靠这里。
        handlerIdleTimeout: TimeInterval = 120,
        // 处理期间每隔这么久往连接里写一个 `\n`：客户端据此区分「还在干活」与
        // 「uTerm 卡死」，自己的 socket 超时就能按静默设，而不必猜最长命令要跑多久。
        // JSON 解析会跳过前导空白，所以心跳不影响读响应。
        heartbeatInterval: TimeInterval = 10,
        requestHandler: @escaping RequestHandler = { request in
            await ControlHandler.shared.handle(request)
        },
        acceptConnection: @escaping AcceptConnection = { fd in
            Darwin.accept(fd, nil, nil)
        }
    ) {
        self.socketURL = socketURL
        self.maxActiveClients = max(1, maxActiveClients)
        self.maxTransferClients = max(1, min(maxTransferClients, self.maxActiveClients))
        self.ioTimeoutNanoseconds = UInt64(max(0.05, ioTimeout) * 1_000_000_000)
        let idle = max(0.05, handlerIdleTimeout)
        let heartbeat = max(0.01, heartbeatInterval)
        self.handlerIdleTimeoutNanoseconds = UInt64(idle * 1_000_000_000)
        self.heartbeatIntervalNanoseconds = UInt64(heartbeat * 1_000_000_000)
        self.supervisionTickNanoseconds = UInt64(
            max(0.01, min(Self.progressInterval, heartbeat, idle / 4)) * 1_000_000_000)
        self.requestHandler = requestHandler
        self.acceptConnection = acceptConnection
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    /// 起服务端。返回 nil 表示已开始监听（或本来就在跑）；返回非 nil 是**不会自愈**的
    /// 启动失败原因，调用方应写进 `ControlSettings.startupError` 让设置页显示出来。
    ///
    /// 目前唯一的失败是 socket 路径超过 `sun_path` 上限：沙盒容器路径 + 长用户名会顶穿
    /// 104 字节。这种情况绝不能进 accept 循环 —— 那会变成每 2 秒重试一次的死循环。
    @discardableResult
    func start() -> String? {
        let pathBytes = socketURL.path.utf8.count
        guard pathBytes <= ControlProtocol.maxSunPathLength - 1 else {
            let message = "socket 路径过长（\(pathBytes) 字节，上限 \(ControlProtocol.maxSunPathLength - 1)）："
                + "\(socketURL.path)。用 UTERM_CONTROL_SOCKET 指定一条更短的路径，或缩短用户名。"
            Self.logger.error("\(message, privacy: .public)")
            return message
        }

        stateLock.lock()
        if running {
            stateLock.unlock()
            return nil
        }
        running = true
        generation &+= 1
        let runGeneration = generation
        stateLock.unlock()

        acceptQueue.async { [weak self] in
            self?.run(generation: runGeneration)
        }
        return nil
    }

    func stop() {
        var handlerTimers: [DispatchSourceTimer] = []
        var handlerTasks: [Task<Void, Never>] = []
        stateLock.lock()
        running = false
        generation &+= 1
        let fd = listenFD
        listenFD = -1
        let clients = activeClients
        // Reading/completing clients have a clientQueue I/O owner: only shutdown
        // them here, then let that owner remove + close the FD. Cross-thread close
        // could otherwise race with FD-number reuse. A handling client has no
        // socket worker at all, so stop() can safely invalidate its token, close
        // it, and immediately release the capacity slot for the next generation.
        for (clientFD, client) in clients {
            Darwin.shutdown(clientFD, SHUT_RDWR)
            if case .handling = client.phase {
                if let handlerTimer = client.handlerTimer {
                    handlerTimers.append(handlerTimer)
                }
                if let handlerTask = client.handlerTask {
                    handlerTasks.append(handlerTask)
                }
                activeClients.removeValue(forKey: clientFD)
                Darwin.close(clientFD)
            }
        }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        // Keep start() excluded until the old pathname has been removed. If we
        // unlocked between close and unlink, the serial accept queue could bind
        // a new generation in that gap and this stale stop() would unlink the
        // new listener's pathname.
        unlink(socketURL.path)
        stateLock.unlock()
        for handlerTimer in handlerTimers {
            handlerTimer.cancel()
        }
        // 主开关关了 / app 退出：没人会收到结果了，别让传输继续占着 SFTP 通道。
        for handlerTask in handlerTasks {
            handlerTask.cancel()
        }
    }

    private func run(generation runGeneration: UInt64) {
        guard isRunning(generation: runGeneration) else { return }

        var retryDelayMicroseconds: useconds_t = 50_000
        while isRunning(generation: runGeneration) {
            var fd: Int32 = -1
            do {
                fd = try makeListeningSocket()
                stateLock.lock()
                guard running, generation == runGeneration, listenFD < 0 else {
                    stateLock.unlock()
                    Darwin.close(fd)
                    unlink(socketURL.path)
                    return
                }
                listenFD = fd
                stateLock.unlock()
                retryDelayMicroseconds = 50_000

                while isRunning(generation: runGeneration, listenFD: fd) {
                    let clientFD = acceptConnection(fd)
                    if clientFD < 0 {
                        let errorNumber = errno
                        if errorNumber == EINTR { continue }
                        guard isRunning(generation: runGeneration, listenFD: fd) else {
                            break
                        }
                        Self.logger.error(
                            "accept failed for \(self.socketURL.path, privacy: .public): \(String(cString: strerror(errorNumber)), privacy: .public) (\(errorNumber)); rebuilding listener"
                        )
                        break
                    }
                    handle(clientFD: clientFD, generation: runGeneration)
                }
            } catch let error as ControlSocketError {
                // 「已被别人服务」是正常的待命状态，不是故障 —— 走 debug，否则退避到
                // 2 秒后会每 2 秒刷一条 error。
                if isRunning(generation: runGeneration) {
                    if case .alreadyServed = error {
                        Self.logger.debug(
                            "\(error.localizedDescription, privacy: .public)"
                        )
                    } else {
                        Self.logger.error(
                            "start failed for \(self.socketURL.path, privacy: .public): \(error.localizedDescription, privacy: .public); retrying"
                        )
                    }
                }
            } catch {
                if isRunning(generation: runGeneration) {
                    Self.logger.error(
                        "start failed for \(self.socketURL.path, privacy: .public): \(error.localizedDescription, privacy: .public); retrying"
                    )
                }
            }
            finishListening(fd: fd, generation: runGeneration, keepRunning: true)

            guard isRunning(generation: runGeneration) else { return }
            Darwin.usleep(retryDelayMicroseconds)
            retryDelayMicroseconds = min(retryDelayMicroseconds * 2, 2_000_000)
        }
    }

    private func isRunning(generation runGeneration: UInt64, listenFD expectedFD: Int32? = nil) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running, generation == runGeneration else { return false }
        if let expectedFD {
            return listenFD == expectedFD
        }
        return true
    }

    private func finishListening(
        fd: Int32,
        generation runGeneration: UInt64,
        keepRunning: Bool = false
    ) {
        guard fd >= 0 else {
            stateLock.lock()
            if generation == runGeneration, !keepRunning {
                running = false
            }
            stateLock.unlock()
            return
        }

        stateLock.lock()
        let stillOwnsListener = generation == runGeneration && listenFD == fd
        if stillOwnsListener {
            listenFD = -1
            if !keepRunning {
                running = false
            }
        }
        stateLock.unlock()

        // If stop() already took ownership, it also closed the descriptor. Avoid
        // a second close after the descriptor number may have been reused.
        if stillOwnsListener {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            unlink(socketURL.path)
        }
    }

    private func makeListeningSocket() throws -> Int32 {
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // 路径上已经有一个**连得通**的 socket，说明另一个实例正在服务这条路径
        // （第二个窗口进程、开发期的测试宿主 —— 测试宿主就是 app 本身，同样会读到
        // 开关并起服务）。此时绝不能抢：unlink + bind 会把对方的 listener 变成孤儿
        // ——它仍 listen 着已被摘掉的 inode，于是所有客户端从此只拿到 ECONNREFUSED，
        // 表现为「uTerm 明明开着，CLI 却连不上」。先到先得，后来者退让重试。
        if Self.isSocketServed(socketURL) {
            throw ControlSocketError.alreadyServed(socketURL.path)
        }
        // 走到这里说明文件要么不存在，要么是没人监听的残留（上个实例被强杀留下的）。
        unlink(socketURL.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

            var addr = sockaddr_un()
            let pathBytes = Array(socketURL.path.utf8) + [0]
            let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
            guard pathBytes.count <= maxPathLength else {
                throw ControlSocketError.pathTooLong(socketURL.path)
            }

            let addrLength = MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count
            addr.sun_len = UInt8(addrLength)
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
                buffer.copyBytes(from: pathBytes)
            }

            let bindResult = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(addrLength))
                }
            }
            guard bindResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            guard listen(fd, 16) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            chmod(socketURL.path, S_IRUSR | S_IWUSR)
            return fd
        } catch {
            Darwin.close(fd)
            unlink(socketURL.path)
            throw error
        }
    }

    private func handle(clientFD: Int32, generation runGeneration: UInt64) {
        var one: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)

        guard let token = register(clientFD: clientFD, generation: runGeneration) else {
            rejectAsBusy(clientFD: clientFD)
            return
        }

        clientQueue.async { [self] in
            readAndDispatch(
                clientFD: clientFD,
                token: token,
                generation: runGeneration
            )
        }
    }

    /// 槽位满时的拒绝路径：先回一条 `server_busy`，再拆连接。光 shutdown + close
    /// 的话客户端只看得到空响应，分不清「服务端忙」和「socket 坏了」—— 前者退避重试
    /// 就好，后者才该报错。
    ///
    /// **必须离开 accept 线程**：写走的是和正常响应同一条带 `ioTimeout` 预算的
    /// 非阻塞 send 路径，把它留在 accept 循环里，一次慢写就会把后面所有连接
    /// （包括本来拿得到槽位的）一起堵住。写不出去就算了，连接照关。
    ///
    /// 这条连接从没进过 `activeClients`，因此没有 token 之争：这个块独占该 fd，
    /// 也由它自己 shutdown + close。请求体一个字节都不读 —— 拒绝发生在读之前，
    /// 客户端 `sendall` 撞 EPIPE 时先读一次就能拿到这条响应（AF_UNIX 上已写回的
    /// 数据不因对端 close 丢失）。
    private func rejectAsBusy(clientFD: Int32) {
        let response = ControlResponse.failure(
            id: nil,
            code: .server_busy,
            message: "uTerm 命令行接口并发已满（上限 \(maxActiveClients) 条连接），稍后重试"
        )
        clientQueue.async { [self] in
            writeResponse(response, to: clientFD)
            Darwin.shutdown(clientFD, SHUT_RDWR)
            Darwin.close(clientFD)
        }
    }

    private func register(clientFD: Int32, generation runGeneration: UInt64) -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running,
              generation == runGeneration,
              activeClients.count < maxActiveClients
        else { return nil }
        nextClientToken &+= 1
        let token = nextClientToken
        activeClients[clientFD] = ActiveClient(
            token: token,
            generation: runGeneration,
            phase: .reading,
            handlerTimer: nil
        )
        return token
    }

    private func readAndDispatch(
        clientFD: Int32,
        token: UInt64,
        generation runGeneration: UInt64
    ) {
        let request: ControlRequest
        let context: ControlRequestContext
        do {
            let (data, passed) = try readRequest(from: clientFD)
            context = ControlRequestContext(fileDescriptors: passed)
            do {
                request = try ControlProtocol.decodeRequest(data)
            } catch {
                context.closeUntaken()
                throw error
            }
        } catch let error as ControlSocketError {
            writeAndFinish(
                response: .failure(id: nil, code: error.code, message: error.localizedDescription),
                clientFD: clientFD,
                token: token
            )
            return
        } catch {
            writeAndFinish(
                response: .failure(id: nil, code: "invalid_request", message: error.localizedDescription),
                clientFD: clientFD,
                token: token
            )
            return
        }

        // stop() may have shut this reading connection down while decode was in
        // progress. Do not launch a new action for a stale generation; the reader
        // still owns the final close in that case.
        let progress = ProgressClock()
        let handlerTimer = DispatchSource.makeTimerSource(queue: clientQueue)
        let tick = DispatchTimeInterval.nanoseconds(Int(clamping: supervisionTickNanoseconds))
        handlerTimer.schedule(deadline: .now() + tick, repeating: tick)
        handlerTimer.setEventHandler { [weak self, requestID = request.id] in
            self?.superviseHandler(
                clientFD: clientFD,
                token: token,
                requestID: requestID,
                progress: progress,
                context: context
            )
        }

        switch beginHandling(
            clientFD: clientFD,
            token: token,
            generation: runGeneration,
            handlerTimer: handlerTimer,
            isTransfer: ControlProtocol.occupiesLongLivedSlot(request)
        ) {
        case .started:
            break
        case .stale:
            context.closeUntaken()
            finishWithoutResponse(clientFD: clientFD, token: token)
            return
        case .transferBusy:
            context.closeUntaken()
            writeAndFinish(
                response: .failure(
                    id: request.id,
                    code: .server_busy,
                    message: "uTerm 的传输 / 交互并发已满（上限 \(maxTransferClients) 个），稍后重试"
                ),
                clientFD: clientFD,
                token: token
            )
            return
        }

        // Only the async handler runs in Swift concurrency. Socket I/O before
        // and after it stays on clientQueue. A timeout does not cancel work that
        // may already be changing database state; it only releases the IPC
        // response/FD. The connection token discards the late response.
        let task = Task { @MainActor [self] in
            let response = await ControlRequestContext.$current.withValue(context) {
                await IOActivity.$pulse.withValue({ progress.touch() }) {
                    await requestHandler(request)
                }
            }
            // handler 真正返回了才关没被取走的 fd（超时回了 `handler_timeout` 也不关：
            // 仍在跑的传输还在用它）。
            context.closeUntaken()
            clientQueue.async { [self] in
                writeAndFinish(response: response, clientFD: clientFD, token: token, context: context)
            }
        }
        attach(task, clientFD: clientFD, token: token)
    }

    private func attach(_ task: Task<Void, Never>, clientFD: Int32, token: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard var client = activeClients[clientFD], client.token == token else { return }
        client.handlerTask = task
        activeClients[clientFD] = client
    }

    private func beginHandling(
        clientFD: Int32,
        token: UInt64,
        generation runGeneration: UInt64,
        handlerTimer: DispatchSourceTimer,
        isTransfer: Bool
    ) -> Admission {
        stateLock.lock()
        guard running,
              generation == runGeneration,
              var client = activeClients[clientFD],
              client.token == token,
              client.generation == runGeneration,
              case .reading = client.phase
        else {
            stateLock.unlock()
            // A DispatchSource must be resumed before cancellation, even when
            // the connection became stale before the timer was installed.
            handlerTimer.resume()
            handlerTimer.cancel()
            return .stale
        }
        // 传输槽位按「已经在处理 / 在回响应的传输」计：还在读请求的不算（读完才知道是什么）。
        if isTransfer,
           activeClients.values.filter(\.isTransfer).count >= maxTransferClients {
            stateLock.unlock()
            handlerTimer.resume()
            handlerTimer.cancel()
            return .transferBusy
        }
        client.isTransfer = isTransfer
        client.phase = .handling
        client.handlerTimer = handlerTimer
        client.lastHeartbeat = DispatchTime.now().uptimeNanoseconds
        activeClients[clientFD] = client
        // Resume while holding stateLock so stop() can never observe and cancel
        // a still-suspended source.
        handlerTimer.resume()
        stateLock.unlock()
        return .started
    }

    /// 监督定时器的每一拍：静默超预算 → `handler_timeout`；否则到点写心跳。
    private func superviseHandler(
        clientFD: Int32,
        token: UInt64,
        requestID: String?,
        progress: ProgressClock,
        context: ControlRequestContext
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let idle = progress.idleNanoseconds(now: now)
        guard idle < handlerIdleTimeoutNanoseconds else {
            writeAndFinish(
                response: .failure(
                    id: requestID,
                    code: "handler_timeout",
                    message: "IPC operation made no progress for \(idle / 1_000_000_000) s"
                ),
                clientFD: clientFD,
                token: token,
                context: context
            )
            return
        }
        flushOutbound(clientFD: clientFD, token: token, now: now, context: context)
    }

    /// 处理期间往连接里写东西：先把上一拍没写完的续上；空了就取一行新进度；没有进度且
    /// 到了心跳间隔就写一个 `\n`。
    ///
    /// **整个写在 `stateLock` 里做**：`.handling` 阶段没有别的 socket 属主，而
    /// `claimCompletion`（转去写响应）与 `stop()`（直接 close 处理中的 FD）都要先拿
    /// 这把锁 —— 持锁写就保证这些字节既不会插进响应中间，也不会写到一个刚被关掉、
    /// 号码又被复用的 FD 上。`MSG_DONTWAIT`，不阻塞：缓冲区满（客户端没在读）就只写
    /// 进去一部分，剩下的留在 `pendingOutbound` 下一拍再写。撞上 EPIPE（客户端走了，
    /// 已设 SO_NOSIGPIPE）就取消 handler。
    private func flushOutbound(clientFD: Int32, token: UInt64, now: UInt64, context: ControlRequestContext) {
        var abandoned: Task<Void, Never>?
        stateLock.lock()
        guard var client = activeClients[clientFD],
              client.token == token,
              case .handling = client.phase
        else {
            stateLock.unlock()
            return
        }
        if client.pendingOutbound.isEmpty {
            if let line = context.drainProgress() {
                client.pendingOutbound = line
            } else if now &- client.lastHeartbeat >= heartbeatIntervalNanoseconds {
                client.pendingOutbound = Data([UInt8(ascii: "\n")])
            }
        }
        if !client.pendingOutbound.isEmpty {
            let sent = client.pendingOutbound.withUnsafeBytes {
                Darwin.send(clientFD, $0.baseAddress, $0.count, MSG_DONTWAIT)
            }
            if sent > 0 {
                client.pendingOutbound = client.pendingOutbound.dropFirst(sent)
                client.lastHeartbeat = now
            } else if sent < 0, errno == EPIPE || errno == ECONNRESET {
                abandoned = client.handlerTask
                client.handlerTask = nil
            }
        }
        activeClients[clientFD] = client
        stateLock.unlock()
        abandoned?.cancel()
    }

    /// 读一条请求，连同 `SCM_RIGHTS` 随附的 fd 一起收（`sftp-get` / `sftp-put` 把本地文件
    /// 交过来）。失败时已收到的 fd 在这里关掉。
    private func readRequest(from fd: Int32) throws -> (Data, [Int32]) {
        // The read budget grows with what has already arrived, mirroring the
        // write path. The total stays bounded because the body itself is capped below.
        var deadline = makeDeadline()
        var data = Data()
        var passed: [Int32] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // 装得下 `maxPassedFDs` 个 fd 的控制缓冲（cmsghdr 12 字节 + 每个 fd 4 字节，4 对齐）。
        var control = [UInt8](repeating: 0, count: 12 + 4 * Self.maxPassedFDs)
        do {
            while true {
                try waitForIO(
                    fd: fd,
                    events: Int16(POLLIN),
                    deadline: deadline,
                    timeoutError: .requestTimedOut
                )
                var flags: Int32 = 0
                var controlLength = 0
                let count = buffer.withUnsafeMutableBytes { bytes in
                    control.withUnsafeMutableBytes { controlBytes in
                        var vector = iovec(iov_base: bytes.baseAddress, iov_len: bytes.count)
                        return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                            var message = msghdr()
                            message.msg_iov = vectorPointer
                            message.msg_iovlen = 1
                            message.msg_control = controlBytes.baseAddress
                            message.msg_controllen = socklen_t(controlBytes.count)
                            let received = Darwin.recvmsg(fd, &message, MSG_DONTWAIT)
                            flags = message.msg_flags
                            controlLength = Int(message.msg_controllen)
                            return received
                        }
                    }
                }
                if controlLength > 0 {
                    passed += control.withUnsafeBytes {
                        Self.receivedFileDescriptors(UnsafeRawBufferPointer(rebasing: $0.prefix(controlLength)))
                    }
                }
                if flags & MSG_CTRUNC != 0 { throw ControlSocketError.tooManyDescriptors }
                if passed.count > Self.maxPassedFDs { throw ControlSocketError.tooManyDescriptors }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                data.append(contentsOf: buffer[0..<count])
                if data.count > ControlProtocol.maxRequestBytes {
                    throw ControlSocketError.requestTooLarge
                }
                deadline = max(deadline, makeDeadline(bytes: data.count))
            }
            guard !data.isEmpty else { throw ControlSocketError.emptyRequest }
            return (data, passed)
        } catch {
            for descriptor in passed { Darwin.close(descriptor) }
            throw error
        }
    }

    /// 一条请求最多随附几个 fd：传输 1 个（本地文件），`run -t` 3 个（stdin / stdout /
    /// 窗口尺寸通知管道）。
    private static let maxPassedFDs = 3

    /// 从 `recvmsg` 的控制缓冲里抠出 `SCM_RIGHTS` 的 fd。Darwin 的 `cmsghdr` 是 12 字节，
    /// `CMSG_DATA` 紧跟其后（4 字节对齐）。收到的 fd 一律设 `FD_CLOEXEC`。
    private static func receivedFileDescriptors(_ control: UnsafeRawBufferPointer) -> [Int32] {
        let headerSize = MemoryLayout<cmsghdr>.size
        var result: [Int32] = []
        var offset = 0
        while offset + headerSize <= control.count {
            let header = control.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
            let length = Int(header.cmsg_len)
            guard length >= headerSize, offset + length <= control.count else { break }
            if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS {
                let count = (length - headerSize) / MemoryLayout<Int32>.size
                for index in 0..<count {
                    let descriptor = control.loadUnaligned(
                        fromByteOffset: offset + headerSize + index * MemoryLayout<Int32>.size,
                        as: Int32.self)
                    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
                    result.append(descriptor)
                }
            }
            offset += (length + 3) & ~3
        }
        return result
    }

    private func writeAndFinish(
        response: ControlResponse,
        clientFD: Int32,
        token: UInt64,
        context: ControlRequestContext? = nil
    ) {
        // Handler completion, handler timeout, protocol error, and stop can all
        // race. Exactly one path may claim send/close ownership for this token.
        guard var prefix = claimCompletion(clientFD: clientFD, token: token) else { return }
        defer { finish(clientFD: clientFD, token: token) }
        // 先把写了一半的进度行写完，再补上最后一批已完成段 —— 客户端的续传账不能缺最后几段。
        if let tail = context?.drainProgress() { prefix.append(tail) }
        writeResponse(response, to: clientFD, prefix: prefix)
    }

    /// 只负责把一条响应编码后写到 fd 上：不碰 `activeClients`、不关 fd。归属与关闭
    /// 由调用方决定（`writeAndFinish` 靠 token 认领，`rejectAsBusy` 独占未登记的 fd）。
    private func writeResponse(_ response: ControlResponse, to clientFD: Int32, prefix: Data = Data()) {
        var data = prefix
        do {
            data.append(try ControlProtocol.encode(response))
        } catch {
            data.append(Data("{\"ok\":false,\"code\":\"encode_failed\",\"message\":\"failed to encode response\"}\n".utf8))
        }

        // A large result set can take longer than one I/O deadline to drain into
        // the peer, so the write budget scales with the payload instead of using
        // the fixed read deadline.
        let deadline = makeDeadline(bytes: data.count)
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                do {
                    try waitForIO(
                        fd: clientFD,
                        events: Int16(POLLOUT),
                        deadline: deadline,
                        timeoutError: .responseTimedOut
                    )
                } catch {
                    return
                }
                let result = Darwin.send(
                    clientFD,
                    base.advanced(by: sent),
                    data.count - sent,
                    MSG_DONTWAIT
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    return
                }
                if result == 0 { return }
                sent += result
            }
        }
    }

    /// 认领这条连接的收尾权。认领到返回处理期间还没写出去的字节（可能为空），没认领到
    /// 返回 nil。
    private func claimCompletion(clientFD: Int32, token: UInt64) -> Data? {
        var handlerTimer: DispatchSourceTimer?
        stateLock.lock()
        guard var client = activeClients[clientFD], client.token == token else {
            stateLock.unlock()
            return nil
        }
        guard case .completing = client.phase else {
            handlerTimer = client.handlerTimer
            client.handlerTimer = nil
            client.phase = .completing
            let pending = client.pendingOutbound
            client.pendingOutbound = Data()
            client.handlerTask = nil
            activeClients[clientFD] = client
            stateLock.unlock()
            handlerTimer?.cancel()
            return pending
        }
        stateLock.unlock()
        return nil
    }

    /// Used only by the current socket worker after stop invalidated its
    /// generation. Claiming first preserves the same single-close invariant as
    /// response paths without attempting a write to the shutdown peer.
    private func finishWithoutResponse(clientFD: Int32, token: UInt64) {
        guard claimCompletion(clientFD: clientFD, token: token) != nil else { return }
        finish(clientFD: clientFD, token: token)
    }

    private func finish(clientFD: Int32, token: UInt64) {
        stateLock.lock()
        let owned: Bool
        if activeClients[clientFD]?.token == token {
            activeClients.removeValue(forKey: clientFD)
            owned = true
        } else {
            owned = false
        }
        stateLock.unlock()
        guard owned else { return }
        Darwin.shutdown(clientFD, SHUT_RDWR)
        Darwin.close(clientFD)
    }

    /// 这条路径上是不是已经有活着的监听者。连得上就是有，`ECONNREFUSED`（残留文件）
    /// 和路径不存在都算没有。
    static func isSocketServed(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        let pathBytes = Array(url.path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        let addrLength = MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count
        addr.sun_len = UInt8(addrLength)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(addrLength))
            }
        }
        return result == 0
    }

    private func makeDeadline(bytes: Int = 0) -> UInt64 {
        // 1 MiB of extra payload buys one extra I/O budget.
        let extra = UInt64(bytes / 1_048_576) &* ioTimeoutNanoseconds
        return DispatchTime.now().uptimeNanoseconds &+ ioTimeoutNanoseconds &+ extra
    }

    private func waitForIO(
        fd: Int32,
        events: Int16,
        deadline: UInt64,
        timeoutError: ControlSocketError
    ) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw timeoutError }
            let remainingNanoseconds = deadline - now
            let roundedMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
            let timeoutMilliseconds = Int32(min(roundedMilliseconds, UInt64(Int32.max)))

            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            if result == 0 { throw timeoutError }
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                throw POSIXError(.EBADF)
            }
            if descriptor.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0 {
                return
            }
        }
    }

    private enum ControlSocketError: LocalizedError {
        case pathTooLong(String)
        case alreadyServed(String)
        case emptyRequest
        case requestTooLarge
        case requestTimedOut
        case responseTimedOut
        case tooManyDescriptors

        var code: String {
            switch self {
            case .alreadyServed: return "socket_already_served"
            case .pathTooLong: return "socket_path_too_long"
            case .emptyRequest: return "empty_request"
            case .requestTooLarge: return "request_too_large"
            case .requestTimedOut: return "request_timeout"
            case .responseTimedOut: return "response_timeout"
            case .tooManyDescriptors: return "invalid_request"
            }
        }

        var errorDescription: String? {
            switch self {
            case .pathTooLong(let path):
                return "Unix socket path is too long: \(path)"
            case .alreadyServed(let path):
                return "another uTerm instance already serves \(path); standing by"
            case .emptyRequest:
                return "IPC request body is empty"
            case .requestTooLarge:
                return "IPC request body is too large"
            case .requestTimedOut:
                return "IPC request did not complete before the I/O deadline"
            case .responseTimedOut:
                return "IPC response could not be written before the I/O deadline"
            case .tooManyDescriptors:
                return "IPC request carried more file descriptors than allowed"
            }
        }
    }
}
