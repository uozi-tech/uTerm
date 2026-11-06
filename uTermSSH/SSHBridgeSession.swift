@preconcurrency import Citadel
import Darwin
import Foundation
import NIOCore
import NIOSSH
@_spi(uTermIntegration) import USSHKit

/// 一次连接的全过程：从控制通道收参数、握手（主机密钥问 App）、开 PTY、桥接到 stdin/stdout，结束就退出进程。
nonisolated final class SSHBridgeSession: @unchecked Sendable {
    /// 与 `SSHClientFactory.channelWindowOptions` 取值和理由相同。这里没有 SFTP，但输出快的程序一样受窗口限制。
    private static let channelWindowBytes = 1 << 20
    private static let probeTimeout = Duration.seconds(10)
    private static let maxOutputBacklogBytes = 16 * 1024 * 1024
    private static let maxExecOutputBytes = 8 * 1024 * 1024
    private static let localNetworkRetryDelays: [Duration] = [.milliseconds(500), .milliseconds(1500), .seconds(3), .seconds(5), .seconds(5)]

    private let control: SSHBridgeControl
    private var signalSources: [DispatchSourceSignal] = []
    private var relay: SSHBridgeControl?

    init(controlFD: Int32) {
        control = SSHBridgeControl(fd: controlFD)
    }

    func run() async {
        // 连接参数到之前就切到原始模式：之后 App 送来的每个字节都要原样进远端，本地的 tty 不能回显、不能处理 ^C。
        Self.setRawMode()
        control.start()
        guard case .connect(let request)? = await control.nextMessage() else {
            // App 没了或者说的不是这回事，没有东西可连。
            exit(1)
        }
        await runSession(request)
        exit(0)
    }

    private func runSession(_ request: SSHBridgeConnectRequest) async {
        let client: ConnectedClient
        do {
            client = try await connectRetryingLocalNetworkDenial(request)
        } catch {
            await fail(request, error)
            exit(1)
        }
        client.target.onDisconnect { Self.exitSoon() }
        client.bastion?.onDisconnect { Self.exitSoon() }

        let size = Self.windowSize()
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: Int(size.ws_col), terminalRowHeight: Int(size.ws_row),
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([:]))
        let environment = request.environment.map {
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: $0.name, value: $0.value)
        }
        do {
            try await client.target.withPTY(pty, environment: environment) { inbound, outbound in
                await control.send(.connected)
                control.close()
                let input = startInputPump(outbound)
                installSignalHandlers(client: client, input: input)
                startRelay(client: client, environment: environment)
                await pumpOutput(inbound)
            }
        } catch {
            // 没走到闭包：开通道失败，App 还在等结果。走到过的话这条发不出去，也不需要。
            await fail(request, error)
        }
    }

    /// 系统先拒绝局域网访问（报 EHOSTUNREACH），再去确认权限：App 更新后第一次访问要等放行规则到位（几百毫秒），
    /// 用户第一次看到权限框要等他点允许（几秒）。苹果要求自己重试（TN3179）。真的没有路由时，要多等 15 秒才报错。
    private func connectRetryingLocalNetworkDenial(_ request: SSHBridgeConnectRequest) async throws -> ConnectedClient {
        for delay in Self.localNetworkRetryDelays {
            do {
                return try await connect(request)
            } catch where Self.isHostUnreachable(error) {
                try await Task.sleep(for: delay)
            }
        }
        return try await connect(request)
    }

    private func connect(_ request: SSHBridgeConnectRequest) async throws -> ConnectedClient {
        let jumpHost = request.jumpHost.map {
            USSHKit.SSHJumpHost(host: $0.host, port: $0.port, username: $0.username, credential: Self.credential($0.credential))
        }
        let endpoint = USSHKit.SSHEndpoint(host: request.host, port: request.port, username: request.username, jumpHost: jumpHost)
        let control = self.control
        return try await USSHKitIntegration.connect(
            endpoint: endpoint,
            credential: Self.credential(request.credential),
            hostKeyStore: SSHBridgeHostKeyStore(control: control),
            hostKeyPolicy: USSHKit.SSHHostKeyPolicy(rawValue: request.hostKeyPolicy) ?? .ask,
            connectTimeout: .seconds(Int64(request.connectTimeoutSeconds)),
            approver: { challenge in
                await control.requestApproval(SSHBridgeChallenge(
                    hostKey: SSHBridgeHostKey(challenge.hostKey),
                    isMismatch: challenge.kind == .mismatch,
                    previousFingerprint: challenge.previousFingerprint))
            },
            protocolOptions: [.maximumPacketSize(Self.channelWindowBytes)])
    }

    private func fail(_ request: SSHBridgeConnectRequest, _ error: Error) async {
        var failure = Self.failure(for: error, hasJumpHost: request.jumpHost != nil)
        if Self.isHostUnreachable(error) { failure.localNetworkUnreachable = true }
        await control.send(.failed(failure))
    }

    private static func isHostUnreachable(_ error: Error) -> Bool {
        String(describing: error).contains("errno: \(EHOSTUNREACH)")
    }

    /// 分类与 `SSHClientFactory.connect` 保持一致，用户看到的文案不因走了这个进程而变。
    private static func failure(for error: Error, hasJumpHost: Bool) -> SSHBridgeFailure {
        if let error = error as? USSHKit.SSHConnectionError {
            switch error {
            case .jumpHostFailed(let message):
                return SSHBridgeFailure(kind: .jumpHost, message: message)
            case .connectFailed(let message):
                return SSHBridgeFailure(kind: .connect, message: message)
            case .authenticationFailed(let message):
                return SSHBridgeFailure(kind: .connect, message: "认证失败：\(message)")
            case .hostKeyRejected(let message):
                return SSHBridgeFailure(kind: .connect, message: "主机密钥被拒绝：\(message)")
            default:
                return SSHBridgeFailure(kind: .connect, message: error.errorDescription ?? FriendlyError.describe(error))
            }
        }
        return SSHBridgeFailure(kind: hasJumpHost ? .jumpHost : .connect, message: FriendlyError.describe(error))
    }

    // MARK: - 桥接

    /// Citadel 的输出流没有上限也没有背压：网络比 PTY 快时（PTY 约 70 MB/s）不能让它一直堆。这里单独一个线程
    /// 写 stdout，来不及写的超过上限就丢最旧的，和 `TerminalOutputBuffer` 对洪水输出的处理一样。
    /// 丢掉的只是用户本来也看不过来的部分，`cat` 大文件时 ^C 还能很快生效。
    private func pumpOutput(_ inbound: TTYOutput) async {
        let backlog = SSHOutputBacklog(capacityBytes: Self.maxOutputBacklogBytes)
        Thread.detachNewThread {
            while let chunk = backlog.next() {
                chunk.withUnsafeReadableBytes { Self.writeAll(STDOUT_FILENO, $0) }
            }
        }
        do {
            for try await chunk in inbound {
                switch chunk {
                case .stdout(let buffer), .stderr(let buffer): backlog.append(buffer)
                }
            }
        } catch {
            // 远端 shell 以非零状态退出会抛错，当正常结束。
        }
        await backlog.drained()
    }

    /// 读 stdin 和发窗口变化走同一个有序队列，同一个写协程消费，不会乱序。
    private func startInputPump(_ writer: TTYStdinWriter) -> AsyncStream<InputOp>.Continuation {
        let (stream, continuation) = AsyncStream.makeStream(of: InputOp.self)
        let drained = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                // EOF / EIO：holder 没了。这个进程也没有留着的理由。
                guard count > 0 else { exit(0) }
                continuation.yield(.bytes(Array(buffer[0..<count]), drained))
                // 等写进 SSH 通道才读下一块：远端不收的时候，背压一路传回 holder。
                drained.wait()
            }
        }
        Task {
            for await op in stream {
                switch op {
                case .bytes(let bytes, let done):
                    var out = ByteBufferAllocator().buffer(capacity: bytes.count)
                    out.writeBytes(bytes)
                    try? await writer.write(out)
                    done.signal()
                case .resize(let cols, let rows):
                    try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                }
            }
        }
        return continuation
    }

    enum InputOp: @unchecked Sendable {
        case bytes([UInt8], DispatchSemaphore)
        case resize(cols: Int, rows: Int)
    }

    private func installSignalHandlers(client: ConnectedClient, input: AsyncStream<InputOp>.Continuation) {
        let resize = Self.signalSource(SIGWINCH) {
            let size = Self.windowSize()
            input.yield(.resize(cols: Int(size.ws_col), rows: Int(size.ws_row)))
        }
        // App 被唤醒、网络变化、重新接回时发这个：主动确认一下连接还在，死了就退出让 App 知道。
        let probe = Self.signalSource(SIGUSR1) {
            Task { await Self.probe(client) }
        }
        signalSources = [resize, probe]
    }

    /// App 经 holder 发来的命令，在这条连接上另开 exec 通道跑（前台进程探测、真彩）。
    /// Citadel 的 exec 不响应取消，超时由 App 那边判，这边跑完就回，没人等了也无妨。
    private func startRelay(client: ConnectedClient, environment: [SSHChannelRequestEvent.EnvironmentRequest]) {
        let relay = SSHBridgeControl(fd: HolderProtocol.childRelayFD)
        relay.onExec = { id, command in
            Task {
                let output = await Self.runCollecting(command, client: client, environment: environment)
                await relay.send(.execResult(id: id, output: output))
            }
        }
        relay.start()
        self.relay = relay
    }

    /// 只收 stdout：登录 shell 的 rc 打到 stderr 的东西会干扰解析。出错、输出超限都返回 nil。
    private static func runCollecting(_ command: String, client: ConnectedClient,
                                      environment: [SSHChannelRequestEvent.EnvironmentRequest]) async -> String? {
        do {
            var output = Data()
            for try await chunk in try await client.target.executeCommandStream(command, environment: environment) {
                guard case .stdout(let buffer) = chunk else { continue }
                output.append(contentsOf: buffer.readableBytesView)
                if output.count > maxExecOutputBytes { return nil }
            }
            return String(decoding: output, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private static func signalSource(_ number: Int32, handler: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }

    /// 只有传输层错误和超时算死：`exec` 被服务器拒绝（比如通道数到顶）不代表连接断了。
    private static func probe(_ client: ConnectedClient) async {
        let alive = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    _ = try await client.exec("true")
                    return true
                } catch {
                    return !SSHTransportFailure.isTransportFailure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: probeTimeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !alive { exit(0) }
    }

    /// 给还在路上的最后一段输出一点时间。
    private static func exitSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { exit(0) }
    }

    // MARK: - tty

    private static func setRawMode() {
        var mode = termios()
        guard tcgetattr(STDIN_FILENO, &mode) == 0 else { return }
        cfmakeraw(&mode)
        tcsetattr(STDIN_FILENO, TCSANOW, &mode)
    }

    private static func windowSize() -> winsize {
        var size = winsize()
        if ioctl(STDIN_FILENO, TIOCGWINSZ, &size) != 0 || size.ws_col == 0 || size.ws_row == 0 {
            size.ws_col = 80
            size.ws_row = 24
        }
        return size
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) {
        var offset = 0
        while offset < bytes.count {
            let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                exit(0)
            }
        }
    }

    private static func credential(_ credential: SSHBridgeCredential) -> USSHKit.SSHCredential {
        switch credential {
        case .password(let password): return .password(password)
        case .privateKey(let pem, let passphrase): return .privateKey(pem: pem, passphrase: passphrase)
        }
    }
}

/// 等待写 stdout 的输出。
nonisolated final class SSHOutputBacklog: @unchecked Sendable {
    private let capacityBytes: Int
    private let condition = NSCondition()
    private var chunks: [ByteBuffer] = []
    private var head = 0
    private var bytes = 0
    private var isWriting = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(capacityBytes: Int) {
        self.capacityBytes = capacityBytes
    }

    func append(_ chunk: ByteBuffer) {
        condition.lock()
        chunks.append(chunk)
        bytes += chunk.readableBytes
        // 至少留下刚来的这块。
        while bytes > capacityBytes, head < chunks.count - 1 {
            bytes -= chunks[head].readableBytes
            head += 1
        }
        compact()
        condition.signal()
        condition.unlock()
    }

    /// 写线程取下一块，没有就等。
    func next() -> ByteBuffer? {
        condition.lock()
        defer { condition.unlock() }
        isWriting = false
        finishDrainIfIdle()
        while head >= chunks.count { condition.wait() }
        let chunk = chunks[head]
        bytes -= chunk.readableBytes
        head += 1
        compact()
        isWriting = true
        return chunk
    }

    /// 全部写完才返回：进程退出前最后一屏不能丢。
    func drained() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            drainWaiters.append(continuation)
            finishDrainIfIdle()
            condition.unlock()
        }
    }

    private func finishDrainIfIdle() {
        guard !isWriting, head >= chunks.count else { return }
        let waiters = drainWaiters
        drainWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func compact() {
        if head == chunks.count {
            chunks.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 64, head * 2 > chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
    }
}

/// 主机密钥的信任记录在 App 的数据库里，这里每次都问 App。App 不在了就抛错，握手失败，进程退出。
nonisolated private struct SSHBridgeHostKeyStore: USSHKit.HostKeyStore {
    let control: SSHBridgeControl

    func verify(_ hostKey: USSHKit.SSHHostKey) async throws -> USSHKit.SSHHostKeyVerification {
        switch try await control.requestVerification(SSHBridgeHostKey(hostKey)) {
        case .trusted: return .trusted
        case .unknown: return .unknown
        case .mismatch(let previous): return .mismatch(previousFingerprint: previous)
        }
    }

    func remember(_ hostKey: USSHKit.SSHHostKey) async throws {
        try await control.requestRemember(SSHBridgeHostKey(hostKey))
    }
}

nonisolated private extension SSHBridgeHostKey {
    init(_ key: USSHKit.SSHHostKey) {
        self.init(host: key.host, port: key.port, keyType: key.keyType, keyBlob: key.keyBlob, fingerprint: key.fingerprint)
    }
}

/// 控制通道：收发帧、把请求和回复配对。读在自己的线程上阻塞，连接断了所有等待者都失败。
nonisolated final class SSHBridgeControl: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "com.uozi.uTerm.ssh.control")
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<SSHBridgeMessage, Error>] = [:]
    private var waitingForConnect: CheckedContinuation<SSHBridgeMessage?, Never>?
    private var bufferedConnect: SSHBridgeMessage?
    private var isClosed = false
    /// 只有转发通道用。`start()` 之前设好。
    var onExec: (@Sendable (Int, String) -> Void)?

    struct Disconnected: Error {}

    init(fd: Int32) {
        self.fd = fd
    }

    func start() {
        Thread.detachNewThread { [self] in readLoop() }
    }

    private func readLoop() {
        var reader = HolderFrameReader()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.withUnsafeBytes { reader.append(UnsafeRawBufferPointer(rebasing: $0[0..<count])) }
            while let frame = try? reader.next() {
                if let message = frame.bridgeMessage { deliver(message) }
            }
        }
        disconnected()
    }

    private func deliver(_ message: SSHBridgeMessage) {
        lock.lock()
        defer { lock.unlock() }
        switch message {
        case .connect:
            if let waiting = waitingForConnect {
                waitingForConnect = nil
                waiting.resume(returning: message)
            } else {
                bufferedConnect = message
            }
        case .verifyResult(let id, _), .rememberResult(let id), .approval(let id, _):
            pending.removeValue(forKey: id)?.resume(returning: message)
        case .exec(let id, let command):
            onExec?(id, command)
        default:
            break
        }
    }

    private func disconnected() {
        lock.lock()
        isClosed = true
        let waiters = pending
        pending = [:]
        let waiting = waitingForConnect
        waitingForConnect = nil
        lock.unlock()
        waiting?.resume(returning: nil)
        for continuation in waiters.values { continuation.resume(throwing: Disconnected()) }
    }

    /// 第一条消息（连接参数）。连接断了返回 nil。
    func nextMessage() async -> SSHBridgeMessage? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let bufferedConnect {
                lock.unlock()
                continuation.resume(returning: bufferedConnect)
            } else if isClosed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waitingForConnect = continuation
                lock.unlock()
            }
        }
    }

    func send(_ message: SSHBridgeMessage) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeQueue.async { [self] in
                write(message)
                continuation.resume()
            }
        }
    }

    private func write(_ message: SSHBridgeMessage) {
        guard let frame = try? HolderFrame(bridge: message) else { return }
        let bytes = frame.encoded()
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    /// 握手结束。读线程读到 EOF 之前 fd 不能关（别的 fd 可能复用这个编号），所以只关发送方向告诉 App 话说完了；
    /// App 收到 `connected` 后关掉自己那端，读线程随之结束。
    func close() {
        writeQueue.async { [fd] in shutdown(fd, SHUT_WR) }
    }

    private func request(_ build: (Int) -> SSHBridgeMessage) async throws -> SSHBridgeMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !isClosed else {
                lock.unlock()
                continuation.resume(throwing: Disconnected())
                return
            }
            let id = nextID
            nextID += 1
            pending[id] = continuation
            lock.unlock()
            let message = build(id)
            writeQueue.async { [self] in write(message) }
        }
    }

    func requestVerification(_ key: SSHBridgeHostKey) async throws -> SSHBridgeVerification {
        guard case .verifyResult(_, let verification) = try await request({ .verifyHostKey(id: $0, key) }) else {
            throw Disconnected()
        }
        return verification
    }

    func requestRemember(_ key: SSHBridgeHostKey) async throws {
        _ = try await request { .rememberHostKey(id: $0, key) }
    }

    /// App 不在了就是不同意。
    func requestApproval(_ challenge: SSHBridgeChallenge) async -> Bool {
        guard case .approval(_, let approved)? = try? await request({ .approveHostKey(id: $0, challenge) }) else {
            return false
        }
        return approved
    }
}
