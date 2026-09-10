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
    private let maxActiveClients: Int
    private let ioTimeoutNanoseconds: UInt64
    private let handlerTimeoutNanoseconds: UInt64
    private let requestHandler: RequestHandler
    private let acceptConnection: AcceptConnection
    private var listenFD: Int32 = -1
    private var running = false
    private var generation: UInt64 = 0
    private var nextClientToken: UInt64 = 0
    private var activeClients: [Int32: ActiveClient] = [:]

    init(
        socketURL: URL = ControlProtocol.socketURL,
        maxActiveClients: Int = 8,
        ioTimeout: TimeInterval = 5,
        // A schema sweep or a slow query legitimately takes a while; the deadline
        // only exists so a wedged handler cannot pin the FD forever.
        handlerTimeout: TimeInterval = 120,
        requestHandler: @escaping RequestHandler = { request in
            await ControlHandler.shared.handle(request)
        },
        acceptConnection: @escaping AcceptConnection = { fd in
            Darwin.accept(fd, nil, nil)
        }
    ) {
        self.socketURL = socketURL
        self.maxActiveClients = max(1, maxActiveClients)
        self.ioTimeoutNanoseconds = UInt64(max(0.05, ioTimeout) * 1_000_000_000)
        self.handlerTimeoutNanoseconds = UInt64(max(0.05, handlerTimeout) * 1_000_000_000)
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
            message: "uTerm 命令行接口并发已满（上限 \(maxActiveClients)），稍后重试"
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
        do {
            let data = try readRequest(from: clientFD)
            request = try ControlProtocol.decodeRequest(data)
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
        let handlerTimer = DispatchSource.makeTimerSource(queue: clientQueue)
        let handlerDeadline = DispatchTime(
            uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds &+ handlerTimeoutNanoseconds
        )
        handlerTimer.schedule(deadline: handlerDeadline)
        handlerTimer.setEventHandler { [weak self, requestID = request.id] in
            self?.writeAndFinish(
                response: .failure(
                    id: requestID,
                    code: "handler_timeout",
                    message: "IPC operation did not complete before the handler deadline"
                ),
                clientFD: clientFD,
                token: token
            )
        }

        guard beginHandling(
            clientFD: clientFD,
            token: token,
            generation: runGeneration,
            handlerTimer: handlerTimer
        ) else {
            finishWithoutResponse(clientFD: clientFD, token: token)
            return
        }

        // Only the async handler runs in Swift concurrency. Socket I/O before
        // and after it stays on clientQueue. A timeout does not cancel work that
        // may already be changing database state; it only releases the IPC
        // response/FD. The connection token discards the late response.
        Task { @MainActor [self] in
            let response = await requestHandler(request)
            clientQueue.async { [self] in
                writeAndFinish(response: response, clientFD: clientFD, token: token)
            }
        }
    }

    private func beginHandling(
        clientFD: Int32,
        token: UInt64,
        generation runGeneration: UInt64,
        handlerTimer: DispatchSourceTimer
    ) -> Bool {
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
            return false
        }
        client.phase = .handling
        client.handlerTimer = handlerTimer
        activeClients[clientFD] = client
        // Resume while holding stateLock so stop() can never observe and cancel
        // a still-suspended source.
        handlerTimer.resume()
        stateLock.unlock()
        return true
    }

    private func readRequest(from fd: Int32) throws -> Data {
        // The read budget grows with what has already arrived, mirroring the
        // write path: `maxRequestBytes` is sized for an 8 MiB base64 `sftp-put`,
        // and a fixed 5 s budget would cut those off on a loaded machine. The
        // total stays bounded because the body itself is capped below.
        var deadline = makeDeadline()
        var data = Data()
        // 8 KiB 的收包缓冲对小请求够用，但一条 11 MB 上限的 `sftp-put` 要 ~1400 次
        // `recv`；64 KiB 把 syscall 数压到 ~1/8，而每条连接只多占 56 KiB 栈外内存
        // （并发连接数由 `maxActiveClients` 封顶）。
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        // 预留一份「够装下绝大多数请求」的容量，省掉小请求的反复 realloc；真正的大
        // 请求仍靠 Data 自己的几何扩容长上去，不在这里按 `maxRequestBytes`（~11 MB）
        // 一把预分配 —— 那会让每条连接都先吃满上限的内存。
        data.reserveCapacity(256 * 1024)
        while true {
            try waitForIO(
                fd: fd,
                events: Int16(POLLIN),
                deadline: deadline,
                timeoutError: .requestTimedOut
            )
            let count = Darwin.recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            data.append(buffer, count: count)
            if data.count > ControlProtocol.maxRequestBytes {
                throw ControlSocketError.requestTooLarge
            }
            deadline = max(deadline, makeDeadline(bytes: data.count))
        }
        guard !data.isEmpty else { throw ControlSocketError.emptyRequest }
        return data
    }

    private func writeAndFinish(
        response: ControlResponse,
        clientFD: Int32,
        token: UInt64
    ) {
        // Handler completion, handler timeout, protocol error, and stop can all
        // race. Exactly one path may claim send/close ownership for this token.
        guard claimCompletion(clientFD: clientFD, token: token) else { return }
        defer { finish(clientFD: clientFD, token: token) }
        writeResponse(response, to: clientFD)
    }

    /// 只负责把一条响应编码后写到 fd 上：不碰 `activeClients`、不关 fd。归属与关闭
    /// 由调用方决定（`writeAndFinish` 靠 token 认领，`rejectAsBusy` 独占未登记的 fd）。
    private func writeResponse(_ response: ControlResponse, to clientFD: Int32) {
        let data: Data
        do {
            data = try ControlProtocol.encode(response)
        } catch {
            data = Data("{\"ok\":false,\"code\":\"encode_failed\",\"message\":\"failed to encode response\"}\n".utf8)
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

    private func claimCompletion(clientFD: Int32, token: UInt64) -> Bool {
        var handlerTimer: DispatchSourceTimer?
        stateLock.lock()
        guard var client = activeClients[clientFD], client.token == token else {
            stateLock.unlock()
            return false
        }
        guard case .completing = client.phase else {
            handlerTimer = client.handlerTimer
            client.handlerTimer = nil
            client.phase = .completing
            activeClients[clientFD] = client
            stateLock.unlock()
            handlerTimer?.cancel()
            return true
        }
        stateLock.unlock()
        return false
    }

    /// Used only by the current socket worker after stop invalidated its
    /// generation. Claiming first preserves the same single-close invariant as
    /// response paths without attempting a write to the shutdown peer.
    private func finishWithoutResponse(clientFD: Int32, token: UInt64) {
        guard claimCompletion(clientFD: clientFD, token: token) else { return }
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

        var code: String {
            switch self {
            case .alreadyServed: return "socket_already_served"
            case .pathTooLong: return "socket_path_too_long"
            case .emptyRequest: return "empty_request"
            case .requestTooLarge: return "request_too_large"
            case .requestTimedOut: return "request_timeout"
            case .responseTimedOut: return "response_timeout"
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
            }
        }
    }
}
