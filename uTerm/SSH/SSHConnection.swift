import Foundation
import Citadel
import Crypto
import NIOCore
import NIOSSH

/// `TerminalBackend` 的 SSH 实现 —— 基于 Citadel 0.12.1。
///
/// 直连路径（本任务）：连接 `profile.host:profile.port`，开启交互式 PTY shell，
/// 把 stdout/stderr 泵入 `outputStream`，shell 结束时在 `exitStream` 产出一个元素。
///
/// 跳板机路径（Task 9）：`profile.jumpHost != nil` 时先连跳板机，再用 Citadel 原生
/// `jump(to:)` 在跳板机连接上开 `direct-tcpip` 通道并完成第二次握手得到目标客户端，
/// 在目标上开 PTY shell。teardown 先关目标、再关跳板机。`jumpHost` 已配置但缺少
/// `jumpHostAuth` 时抛 `jumpHostFailed`，绝不静默回退到直连。
///
/// ## withPTY 作用域闭包的接线方式
/// Citadel 的 `withPTY` 不返回句柄 —— 它在闭包返回时就关闭通道。所以会话期间
/// 必须把闭包"挂起"。做法：在一个独立 `Task`（`sessionTask`）里调用 `withPTY`，
/// 闭包内：
///   1. 把 `TTYStdinWriter` 写入 `SessionState`（线程安全盒子），并启动单一 drain 任务，
///      使 `write`/`resize` 生效；
///   2. 用 `TaskGroup` 跑两个子任务：一个泵出站输出，一个 `await` close 信号；
///   3. `group.next()` 在任一子任务结束时返回 —— 远端 shell 退出（输出泵结束）
///      或本地 `close()`（close 信号 resume）都会让闭包退出，从而关闭通道。
/// `SessionState` 用锁保护，因此可以安全地从 `withPTY` 的非隔离闭包里访问。
///
/// ## stdin 字节顺序保证（C1）
/// 所有 stdin 写入与 resize 都进入 `SessionState` 的单一有序 FIFO 队列，由唯一一个
/// drain 任务串行消费 —— 每个操作 `await` 完成后才处理下一个。writer 就绪前积压的
/// 操作与就绪后的新操作进同一队列，因此从"调用 write/resize"到"writer.write"
/// 只有一条有序路径，绝不会乱序。
actor SSHConnection: TerminalBackend {

    enum SSHConnectionError: Error, LocalizedError {
        case notConnected
        case alreadyClosed
        case connectFailed(String)
        case jumpHostFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "SSH 连接尚未建立"
            case .alreadyClosed:
                return "SSH 连接已关闭，无法再次连接"
            case .connectFailed(let message):
                return "SSH 连接失败：\(message)"
            case .jumpHostFailed(let message):
                return "跳板机连接失败：\(message)"
            }
        }
    }

    // MARK: - TerminalBackend

    nonisolated let outputStream: AsyncStream<Data>
    nonisolated let exitStream: AsyncStream<Void>

    private let outputContinuation: AsyncStream<Data>.Continuation
    private let exitContinuation: AsyncStream<Void>.Continuation

    // MARK: - 配置

    private let profile: ServerProfile
    private let auth: ResolvedAuth
    private let jumpHostAuth: ResolvedAuth?

    // MARK: - 运行时状态

    /// 跨 actor / withPTY 闭包共享的会话状态盒子（自带锁，`Sendable`）。
    private let state = SessionState()
    private var client: SSHClient?
    /// 跳板机连接。跳板机路径下 `client`（目标）是这个连接上的子通道。
    /// 必须比 `client` 活得久 —— teardown 时先关 `client`，再关 `bastionClient`。
    private var bastionClient: SSHClient?
    private var sessionTask: Task<Void, Never>?
    private var isClosed = false

    /// `connect` 前 `resize` 被调用时记下，用作 PTY 初始尺寸。
    /// connect 之后的 resize 走有序发送路径（C1/M2），不再读这两个字段。
    private var pendingCols: UInt16 = 80
    private var pendingRows: UInt16 = 24
    private var didConnect = false

    init(profile: ServerProfile, auth: ResolvedAuth, jumpHostAuth: ResolvedAuth?) {
        self.profile = profile
        self.auth = auth
        self.jumpHostAuth = jumpHostAuth
        (outputStream, outputContinuation) = AsyncStream<Data>.makeStream()
        (exitStream, exitContinuation) = AsyncStream<Void>.makeStream()
    }

    /// 安全网（I1）：消费者未调用 `close()` 就丢弃连接时，取消会话任务并发出 close 信号，
    /// 使 `withPTY` 闭包返回、通道关闭，避免 `SSHClient` 与活动通道永久泄漏。
    /// 注意：仅取消 `sessionTask` 无法解开 `withPTY`（它阻塞在忽略取消的
    /// `withCheckedContinuation` 上），必须显式 `signalClose()`。
    deinit {
        sessionTask?.cancel()
        state.signalClose()
        outputContinuation.finish()
        exitContinuation.finish()
    }

    // MARK: - connect

    func connect() async throws {
        guard !isClosed else { throw SSHConnectionError.alreadyClosed }
        didConnect = true

        let connectedClient: SSHClient
        if let jumpHost = profile.jumpHost {
            // 配置了跳板机：必须有跳板机认证材料，否则报错 —— 绝不静默回退直连。
            guard let jumpHostAuth else {
                finishStreams()
                isClosed = true
                throw SSHConnectionError.jumpHostFailed("缺少跳板机认证材料")
            }
            connectedClient = try await connectViaJumpHost(jumpHost: jumpHost, jumpHostAuth: jumpHostAuth)
        } else {
            connectedClient = try await connectDirect()
        }
        self.client = connectedClient
        // 强引用本地副本：sessionTask 用它做客户端 teardown，使清理不依赖 actor 存活（I1）。
        let targetClient = connectedClient
        let bastion = self.bastionClient

        let cols = Int(pendingCols)
        let rows = Int(pendingRows)
        let state = self.state
        // M1：输出泵直接捕获 Sendable 的 outputContinuation，逐块 yield，
        // 不再每块都 hop 回 actor。
        let outputContinuation = self.outputContinuation

        // 在独立 Task 里把 withPTY 闭包挂起整个会话生命周期。
        sessionTask = Task { [weak self] in
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: cols,
                terminalRowHeight: rows,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            do {
                try await connectedClient.withPTY(request) { inbound, outbound in
                    // 1. 发布 stdin writer 并启动单一有序 drain 任务，使 write()/resize() 生效。
                    state.attach(writer: outbound)
                    // 2. 并发：泵出站输出 + 等待 close 信号。
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            do {
                                for try await chunk in inbound {
                                    if Task.isCancelled { break }
                                    switch chunk {
                                    case .stdout(let buffer), .stderr(let buffer):
                                        outputContinuation.yield(Data(buffer.readableBytesView))
                                    }
                                }
                            } catch {
                                // 远端 shell 以非零状态退出会抛错 —— 视作正常 EOF。
                            }
                        }
                        group.addTask {
                            await state.waitForClose()
                        }
                        // 任一子任务结束（shell 退出 或 本地 close）即返回。
                        await group.next()
                        group.cancelAll()
                    }
                }
            } catch {
                // withPTY 建立失败或闭包抛错 —— 进入收尾。
            }
            // drain 任务停止并 await 其完成，确保不再有 writer.write 在飞行中。
            await state.shutdownDrain()
            // 客户端 teardown 用强引用的本地副本完成，不经过 `self` ——
            // 即便 actor 已被消费者丢弃（deinit 后 `self == nil`），底层
            // SSHClient 传输仍会被关闭，杜绝泄漏（I1）。先关目标、再关跳板机。
            try? await targetClient.close()
            try? await bastion?.close()
            // 触碰 actor 状态的收尾（exitStream 产元素、结束流、置 isClosed）
            // 仍走 `self?.` —— 若 `self` 已不在，deinit 已结束流。
            await self?.handleSessionEnded()
        }
    }

    /// 直连路径：连接 `profile.host:profile.port`。
    /// 任一失败步骤都结束流、置 `isClosed`，并抛 `connectFailed`。
    private func connectDirect() async throws -> SSHClient {
        let authMethod: SSHAuthenticationMethod
        do {
            authMethod = try Self.makeAuthMethod(from: auth)
        } catch {
            // I4：认证材料构造失败也要结束流。
            finishStreams()
            isClosed = true
            throw error
        }

        do {
            return try await SSHClient.connect(
                host: profile.host,
                port: profile.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
        } catch {
            // I4：连接/认证失败 —— 结束流，让消费者干净终止。
            finishStreams()
            isClosed = true
            throw SSHConnectionError.connectFailed(error.localizedDescription)
        }
    }

    /// 跳板机路径（Task 9）：先连跳板机，再用 Citadel 原生 `jump(to:)` 在
    /// 跳板机连接上开 `direct-tcpip` 通道并完成第二次 SSH 握手，得到目标客户端。
    ///
    /// 生命周期：成功时把跳板机连接存入 `bastionClient`，目标客户端作为返回值
    /// 交给 `connect()` 存入 `client`。会话结束时由 `sessionTask` 用强引用的本地
    /// 副本先关目标、再关跳板机 —— 不依赖 actor 存活。
    ///
    /// 错误处理：每一步失败都 `finishStreams()` + `isClosed = true`，已打开的资源
    /// （`jump` 失败时的跳板机连接）就地关闭，并抛 `jumpHostFailed("<detail>")`，
    /// 不留任何泄漏 / 挂起。
    private func connectViaJumpHost(
        jumpHost: ServerProfile, jumpHostAuth: ResolvedAuth
    ) async throws -> SSHClient {
        // 1. 构造跳板机与目标的认证材料。
        let bastionAuthMethod: SSHAuthenticationMethod
        let targetAuthMethod: SSHAuthenticationMethod
        do {
            bastionAuthMethod = try Self.makeAuthMethod(from: jumpHostAuth)
            targetAuthMethod = try Self.makeAuthMethod(from: auth)
        } catch {
            finishStreams()
            isClosed = true
            throw SSHConnectionError.jumpHostFailed(error.localizedDescription)
        }

        // 2. 连接跳板机。
        let bastion: SSHClient
        do {
            bastion = try await SSHClient.connect(
                host: jumpHost.host,
                port: jumpHost.port,
                authenticationMethod: bastionAuthMethod,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
        } catch {
            finishStreams()
            isClosed = true
            throw SSHConnectionError.jumpHostFailed(
                "无法连接跳板机 \(jumpHost.host):\(jumpHost.port) —— \(error.localizedDescription)")
        }

        // 3. 从跳板机 jump 到目标。`SSHClientSettings.authenticationMethod`
        //    是 `@Sendable () -> SSHAuthenticationMethod` 转义闭包。
        let targetSettings = SSHClientSettings(
            host: profile.host,
            port: profile.port,
            authenticationMethod: { targetAuthMethod },
            hostKeyValidator: .acceptAnything()
        )
        let target: SSHClient
        do {
            target = try await bastion.jump(to: targetSettings)
        } catch {
            // jump 失败 —— 跳板机连接已建立，必须就地关闭，避免泄漏。
            try? await bastion.close()
            finishStreams()
            isClosed = true
            throw SSHConnectionError.jumpHostFailed(
                "经跳板机连接目标 \(profile.host):\(profile.port) 失败 —— \(error.localizedDescription)")
        }

        // 成功 —— 持有跳板机连接，目标作为子通道由调用方存入 `client`。
        self.bastionClient = bastion
        return target
    }

    // MARK: - write / resize / close

    func write(_ data: Data) async {
        state.enqueue(.write(data))
    }

    func resize(cols: UInt16, rows: UInt16) async {
        if didConnect {
            // M2：connect 之后，resize 必须走有序发送路径才能真正生效。
            state.enqueue(.resize(cols: Int(cols), rows: Int(rows)))
        } else {
            // connect 之前：记下作为 PTY 初始尺寸。
            pendingCols = cols
            pendingRows = rows
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        // 结束 withPTY 闭包 -> 关闭通道。drain 任务的停止与 await 由 sessionTask
        // 内部的 `shutdownDrain()` 完成（C2）。
        state.signalClose()
        // 等 sessionTask 跑完：它内部已 await drain 任务结束 *并* 关闭了
        // 目标/跳板机客户端（唯一的客户端 teardown 点），因此 close() 返回时
        // 所有 stdin 写入要么已 flush、要么已确定性放弃，底层传输也已关闭。
        await sessionTask?.value
        sessionTask = nil
        client = nil
        bastionClient = nil
        finishStreams()
    }

    // MARK: - 私有

    /// 会话 Task 自然结束（远端 shell 退出，或 withPTY 异常）时调用。
    /// 客户端关闭已由 `sessionTask` 用强引用本地副本完成（不依赖 `self`），
    /// 此处只做 actor 状态收尾。`close()` 路径下 `isClosed` 已为真，直接返回。
    private func handleSessionEnded() async {
        guard !isClosed else { return }
        isClosed = true
        // 此处不调用 state.signalClose()：withPTY 已经返回，信号无意义（I3）。
        client = nil
        bastionClient = nil
        finishStreams()
    }

    private func finishStreams() {
        exitContinuation.yield(())
        exitContinuation.finish()
        outputContinuation.finish()
    }

    // MARK: - 认证材料构造

    /// 把 `ResolvedAuth` 转为 Citadel 的 `SSHAuthenticationMethod`。
    /// 私钥仅支持 OpenSSH 格式的 RSA / Ed25519。
    static func makeAuthMethod(from auth: ResolvedAuth) throws -> SSHAuthenticationMethod {
        switch auth {
        case .password(let username, let password):
            return .passwordBased(username: username, password: password)

        case .privateKey(let username, let pem, let passphrase):
            let decryptionKey = passphrase?.data(using: .utf8)

            // 旧式 PEM（PKCS#1 / PKCS#8）不被 Citadel 的 OpenSSH 解析器支持。
            guard pem.contains("BEGIN OPENSSH PRIVATE KEY") else {
                throw SSHConnectionError.connectFailed(
                    "不支持的私钥格式：仅支持 OpenSSH 格式的 RSA / Ed25519 密钥，"
                    + "请用 `ssh-keygen -p -m OPENSSH` 转换")
            }

            // 先用 SSHKeyDetection 判定内部类型，再走对应解析器。
            let keyType: SSHKeyType
            do {
                keyType = try SSHKeyDetection.detectPrivateKeyType(from: pem)
            } catch {
                // 检测失败时退而求其次：依次尝试 Ed25519、RSA。
                if let method = try? makeEd25519(username: username, pem: pem, key: decryptionKey) {
                    return method
                }
                if let method = try? makeRSA(username: username, pem: pem, key: decryptionKey) {
                    return method
                }
                throw SSHConnectionError.connectFailed(
                    "无法解析私钥：仅支持 OpenSSH 格式的 RSA / Ed25519 密钥")
            }

            switch keyType {
            case .rsa:
                return try makeRSA(username: username, pem: pem, key: decryptionKey)
            case .ed25519:
                return try makeEd25519(username: username, pem: pem, key: decryptionKey)
            default:
                throw SSHConnectionError.connectFailed(
                    "不支持的私钥格式：仅支持 OpenSSH 格式的 RSA / Ed25519 密钥，"
                    + "请用 `ssh-keygen -p -m OPENSSH` 转换")
            }
        }
    }

    private static func makeRSA(
        username: String, pem: String, key: Data?
    ) throws -> SSHAuthenticationMethod {
        do {
            let privateKey = try Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: key)
            return .rsa(username: username, privateKey: privateKey)
        } catch {
            throw SSHConnectionError.connectFailed(
                "RSA 私钥解析失败（可能是密码错误或格式不受支持）：\(error.localizedDescription)")
        }
    }

    private static func makeEd25519(
        username: String, pem: String, key: Data?
    ) throws -> SSHAuthenticationMethod {
        do {
            let privateKey = try Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: key)
            return .ed25519(username: username, privateKey: privateKey)
        } catch {
            throw SSHConnectionError.connectFailed(
                "Ed25519 私钥解析失败（可能是密码错误或格式不受支持）：\(error.localizedDescription)")
        }
    }
}

// MARK: - SessionState

/// 跨 actor 与 `withPTY` 非隔离闭包共享的会话状态。自带 `NSLock`，是 `Sendable`。
///
/// `withPTY` 的 `perform` 闭包不在 actor 隔离域内执行，无法直接触碰 actor 状态；
/// 这个盒子作为安全的交汇点：actor 端入队写入/resize、写入 close 信号；闭包端发布
/// `TTYStdinWriter`、启动 drain 任务、等待 close。
///
/// ## stdin 有序性（C1）
/// 所有 `Op` 进同一个 FIFO `pendingOps`。writer 发布前入队的 Op 留在队列里，writer
/// 发布后 `attach` 启动唯一一个 drain 任务，从队头开始逐个 `await` 应用到 writer。
/// `enqueue` 用 `opSignal` 这个 `AsyncStream` 唤醒 drain 任务。因此从"调用
/// write/resize"到"writer.write/changeSize"只有一条有序路径，不会乱序、不会并发。
private final class SessionState: @unchecked Sendable {

    /// stdin 操作：写入字节或改窗口尺寸。FIFO 顺序应用。
    enum Op {
        case write(Data)
        case resize(cols: Int, rows: Int)
    }

    private let lock = NSLock()

    /// PTY stdin writer，由 withPTY 闭包发布。
    private var writer: TTYStdinWriter?

    /// 单一有序 stdin 操作 FIFO（C1）。writer 就绪前后入队的 Op 都在这里排队。
    private var pendingOps: [Op] = []
    /// drain 任务被请求停止（close 或会话结束）。
    private var drainStopped = false

    /// 唤醒 drain 任务的信号流；每入队一个 Op（或请求停止）就 yield 一次。
    private let opSignal: AsyncStream<Void>
    private let opSignalContinuation: AsyncStream<Void>.Continuation

    /// 单一 drain 任务句柄，由 `attach` 启动、`shutdownDrain` await。
    private var drainTask: Task<Void, Never>?

    /// close 信号的等待方。
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private var closeSignalled = false

    init() {
        (opSignal, opSignalContinuation) = AsyncStream<Void>.makeStream()
    }

    // MARK: 入队（actor 端调用）

    /// 把一个 stdin 操作放进有序 FIFO，并唤醒 drain 任务。
    /// drain 任务尚未启动（writer 未就绪）也无妨 —— Op 会留在队列里，
    /// `attach` 启动 drain 后立即被消费。
    func enqueue(_ op: Op) {
        lock.lock()
        guard !drainStopped else { lock.unlock(); return }
        pendingOps.append(op)
        lock.unlock()
        opSignalContinuation.yield(())
    }

    // MARK: writer 发布 + drain 启动（withPTY 闭包端调用）

    /// 发布 writer 并启动唯一一个有序 drain 任务。
    func attach(writer: TTYStdinWriter) {
        lock.lock()
        self.writer = writer
        let alreadyStopped = drainStopped
        lock.unlock()

        // 若在 writer 就绪前就已请求停止（极端竞态），不启动 drain。
        guard !alreadyStopped else { return }

        drainTask = Task {
            await self.drainLoop(writer: writer)
        }
    }

    /// 单一 drain 循环：从 FIFO 队头逐个取 Op，`await` 应用到 writer，再取下一个。
    /// 严格串行 —— 保证 stdin 字节 FIFO 顺序（C1）。
    private func drainLoop(writer: TTYStdinWriter) async {
        for await _ in opSignal {
            // 每次信号尽量排空当前队列。
            while true {
                lock.lock()
                if pendingOps.isEmpty {
                    let stopped = drainStopped
                    lock.unlock()
                    if stopped { return }
                    break
                }
                let op = pendingOps.removeFirst()
                lock.unlock()

                switch op {
                case .write(let data):
                    try? await writer.write(ByteBuffer(bytes: data))
                case .resize(let cols, let rows):
                    try? await writer.changeSize(
                        cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                }
            }
        }
    }

    /// 请求 drain 任务停止并 await 其完成（C2）。
    /// 在 `sessionTask` 内、`withPTY` 返回后调用 —— 返回后保证不再有 writer.write 在飞行。
    func shutdownDrain() async {
        lock.lock()
        drainStopped = true
        let task = drainTask
        drainTask = nil
        lock.unlock()
        // 结束信号流，让 drainLoop 的 `for await` 退出。
        opSignalContinuation.finish()
        await task?.value
    }

    // MARK: close 信号

    /// withPTY 闭包内调用 —— 挂起直到 `signalClose()`。
    func waitForClose() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if closeSignalled {
                lock.unlock()
                continuation.resume()
            } else {
                closeContinuation = continuation
                lock.unlock()
            }
        }
    }

    /// actor 端调用 —— 唤醒 `waitForClose()`，使 withPTY 闭包退出。幂等。
    func signalClose() {
        lock.lock()
        let continuation = closeContinuation
        closeContinuation = nil
        closeSignalled = true
        lock.unlock()
        continuation?.resume()
    }
}
