import Foundation
import Synchronization
@preconcurrency import Citadel
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
/// `SessionState` 用 `Mutex` 保护，因此可以安全地从 `withPTY` 的非隔离闭包里访问。
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

    /// `ServerProfile` 的不可变值快照。`ServerProfile` 是 SwiftData `@Model`，
    /// 非 `Sendable`；`TerminalPaneView`（`@MainActor` 的 `View`）持有的
    /// `profile` 因此是主 actor 隔离的，不能直接"sending"进 actor。
    /// 调用方在自身隔离域内用此快照摘取本类需要的标量字段 —— 快照是
    /// `Sendable` 值类型，可安全跨入 `SSHConnection` actor。
    struct ProfileSnapshot: Sendable {
        let host: String
        let port: Int
        let jumpHost: JumpHostSnapshot?

        struct JumpHostSnapshot: Sendable {
            let host: String
            let port: Int
        }

        /// 从 `ServerProfile` 模型摘取快照。在调用方所属隔离域内同步执行。
        init(_ profile: ServerProfile) {
            self.host = profile.host
            self.port = profile.port
            self.jumpHost = profile.jumpHost.map {
                JumpHostSnapshot(host: $0.host, port: $0.port)
            }
        }

        /// 直接用标量字段构造快照。给「编辑表单测试连接」用 —— 此时用户尚未保存，
        /// 没有可摘取的 `ServerProfile`，需用表单当前输入的 host/port/跳板机直接建快照。
        init(host: String, port: Int, jumpHost: JumpHostSnapshot?) {
            self.host = host
            self.port = port
            self.jumpHost = jumpHost
        }
    }

    private let profile: ProfileSnapshot
    private let auth: ResolvedAuth
    private let jumpHostAuth: ResolvedAuth?

    /// 主机密钥 TOFU 校验：known-hosts 存储 / 决策 actor，以及征询用户的注入闭包。
    /// 两者均 `Sendable`，可安全跨入本 actor，并被 `HostKeyValidationDelegate` 捕获。
    private let hostKeyVerifier: HostKeyVerifier
    private let hostKeyApprover: @Sendable (HostKeyChallenge) async -> Bool

    // MARK: - 运行时状态

    /// 跨 actor / withPTY 闭包共享的会话状态盒子（自带 `Mutex`，`Sendable`）。
    private let state = SessionState()
    /// 会话任务。它在内部以强引用本地副本持有目标 / 跳板机 `SSHClient`，
    /// 并独占负责其 teardown（先关目标、再关跳板机）—— 因此 actor 本身
    /// 不再单独存储 `SSHClient`：那会让非 `Sendable` 的 `SSHClient` 既被
    /// actor 隔离持有、又被并发的 `sessionTask` 捕获，触发 Swift 6 数据竞争
    /// 诊断。会话任务的强本地副本已保证客户端在整个会话期间存活（I1）。
    private var sessionTask: Task<Void, Never>?
    private var isClosed = false
    /// 连接成功后保留的客户端束引用，供存活探测（`verifyConnectionAlive`）在
    /// 既有连接上开一次性 exec channel。teardown 仍由 `sessionTask` 的强本地
    /// 副本独占负责 —— 此引用只用于探测与探测判死后的强制关闭（幂等）。
    private var connectedClient: ConnectedClient?

    /// `connect` 前 `resize` 被调用时记下，用作 PTY 初始尺寸。
    /// connect 之后的 resize 走有序发送路径（C1/M2），不再读这两个字段。
    private var pendingCols: UInt16 = 80
    private var pendingRows: UInt16 = 24
    private var didConnect = false

    // MARK: - PTY 环境变量

    /// 开 PTY 时随通道发出的 `env` 请求（在 pty-req / shell 之前发）。
    ///
    /// 不发 `LANG` 时远端登录 shell 落在 C/POSIX locale，`less`/`man` 这类按
    /// locale 判断可打印性的程序会把 UTF-8 字节逐个反显成 `<E5><BC><80>`，
    /// 中文全部不可读（终端这侧的解码是好的，字节也完整）。系统 `ssh` 不犯这个
    /// 错，是因为 `/etc/ssh/ssh_config` 默认带 `SendEnv LANG LC_*` —— 这里等价补上。
    ///
    /// 固定 `en_US.UTF-8` 而不跟随本机 locale：远端未生成 `zh_CN.UTF-8` 时
    /// setlocale 失败会回落 C —— 既没修好又多刷一行警告；`en_US.UTF-8` 在
    /// macOS 与主流发行版上都存在。只发 `LANG`（不发 `LC_ALL`），远端 rc 里
    /// 自己设的 `LC_*` 仍然优先。
    ///
    /// `wantReply: false` 是必须的：Citadel 对每个 env 请求 `try await`
    /// `triggerUserOutboundEvent`，服务端没配 `AcceptEnv` 而拒绝时，带 reply
    /// 的请求会把错误抛出去、整条连接建不起来。不要 reply 就退化成"收不到就忽略"。
    nonisolated private static let ptyEnvironment: [SSHChannelRequestEvent.EnvironmentRequest] = [
        .init(wantReply: false, name: "LANG", value: "en_US.UTF-8")
    ]

    /// 构造器只接受 `Sendable` 的 `ProfileSnapshot` —— 调用方须在自身隔离域内
    /// 先把非 `Sendable` 的 `@Model` `ServerProfile` 摘成快照（`ProfileSnapshot(_:)`），
    /// 再传入。这样无论从主 actor 还是别处构造 `SSHConnection` 都不会跨隔离域
    /// 传递非 `Sendable` 模型，从而满足 Swift 6 的数据竞争检查。
    init(profile: ProfileSnapshot,
         auth: ResolvedAuth,
         jumpHostAuth: ResolvedAuth?,
         hostKeyVerifier: HostKeyVerifier,
         hostKeyApprover: @escaping @Sendable (HostKeyChallenge) async -> Bool) {
        self.profile = profile
        self.auth = auth
        self.jumpHostAuth = jumpHostAuth
        self.hostKeyVerifier = hostKeyVerifier
        self.hostKeyApprover = hostKeyApprover
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

        // 目标客户端 + 跳板机连接（若有）由 `SSHClientFactory` 建立，打包成
        // `Sendable` 的 `ConnectedClient`。它作为区域隔离的局部值持有，不写回
        // `self` —— 非 `Sendable` 的 `SSHClient` 若同时被 actor 持有又被下面
        // 并发的 `sessionTask` 捕获，会触发 Swift 6 数据竞争诊断。这个强本地
        // 副本由 `sessionTask` 捕获，独占负责客户端 teardown（`connected.close()`
        // 先关目标、再关跳板机），使清理不依赖 actor 存活（I1）。
        let connected: ConnectedClient
        do {
            connected = try await SSHClientFactory.connect(
                profile: profile,
                auth: auth,
                jumpHostAuth: jumpHostAuth,
                hostKeyVerifier: hostKeyVerifier,
                hostKeyApprover: hostKeyApprover)
        } catch {
            // I4：连接/认证/跳板机失败 —— 结束流、置 isClosed，让消费者干净终止。
            // 工厂在 `jump` 失败时已就地关闭跳板机连接；此处只做 actor 状态收尾。
            finishStreams()
            isClosed = true
            throw error
        }
        let targetClient = connected.target
        let cols = Int(pendingCols)
        let rows = Int(pendingRows)
        let state = self.state
        self.connectedClient = connected
        // 传输层关闭（FIN/RST 到达、或内核在断网后终于放弃重传）→ 立刻发 close
        // 信号：withPTY 闭包退出 → sessionTask 收尾 → exitStream 产元素 →
        // TerminalSession 翻到 .disconnected。不等 inbound 流自己察觉。
        // 正常 close() 路径会再触发一次 —— signalClose 幂等，无害。
        connected.target.onDisconnect { state.signalClose() }
        connected.bastion?.onDisconnect { state.signalClose() }
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
                try await targetClient.withPTY(request, environment: Self.ptyEnvironment) { inbound, outbound in
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
            // 客户端 teardown 用强引用的本地副本（`connected`）完成，不经过 `self` ——
            // 即便 actor 已被消费者丢弃（deinit 后 `self == nil`），底层
            // SSHClient 传输仍会被关闭，杜绝泄漏（I1）。`connected.close()`
            // 先关目标、再关跳板机。
            await connected.close()
            // 触碰 actor 状态的收尾（exitStream 产元素、结束流、置 isClosed）
            // 仍走 `self?.` —— 若 `self` 已不在，deinit 已结束流。
            await self?.handleSessionEnded()
        }
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
        connectedClient = nil
        finishStreams()
    }

    // MARK: - 存活探测

    /// 主动探测连接是否仍然存活（系统唤醒 / 网络恢复后由 `ConnectionWatchdog`
    /// 经 `TerminalSession` 调用）。
    ///
    /// 长时间待机断网形成的半死 TCP：对端没发过 FIN/RST，NIO 通道看起来仍
    /// active，inbound 永不结束、写入只进内核缓冲 —— 唯一可靠的判定是发一笔
    /// 需要对端应答的流量。Citadel 0.12.1 没有 SSH 层 keepalive，这里在既有
    /// 连接上开一次性 exec channel 跑 `true`：
    /// - 任何应答都证明传输活着 —— 包括服务器拒绝开 channel（MaxSessions=1
    ///   之类的应用层失败），只有传输层错误才判死；
    /// - 超时 / 传输层错误 → 强制关闭底层通道（本地操作、立即完成），由此
    ///   级联：inbound 结束 → withPTY 返回 → exitStream → UI 置「连接已断开」。
    func verifyConnectionAlive() async -> Bool {
        await verifyConnectionAlive(timeout: .seconds(10))
    }

    func verifyConnectionAlive(timeout: Duration) async -> Bool {
        guard !isClosed, let connected = connectedClient else { return false }
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                do {
                    _ = try await connected.exec("true")
                    return true
                } catch {
                    return !SSHTransportFailure.isTransportFailure(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil   // nil = 超时
            }
            let first = await group.next() ?? nil
            if first != true {
                // 判死：先把底层通道关掉。这同时解除可能挂死的探测子任务
                // （exec 拿到「通道已关」错误后返回），TaskGroup 才能收尾。
                await connected.close()
            }
            group.cancelAll()
            return first == true
        }
    }

    // MARK: - 私有

    /// 会话 Task 自然结束（远端 shell 退出，或 withPTY 异常）时调用。
    /// 客户端关闭已由 `sessionTask` 用强引用本地副本完成（不依赖 `self`），
    /// 此处只做 actor 状态收尾。`close()` 路径下 `isClosed` 已为真，直接返回。
    private func handleSessionEnded() async {
        guard !isClosed else { return }
        isClosed = true
        // 此处不调用 state.signalClose()：withPTY 已经返回，信号无意义（I3）。
        // 客户端已由 sessionTask 的强本地副本关闭，actor 不再持有引用。
        connectedClient = nil
        finishStreams()
    }

    private func finishStreams() {
        exitContinuation.yield(())
        exitContinuation.finish()
        outputContinuation.finish()
    }
}

// MARK: - SessionState

/// 跨 actor 与 `withPTY` 非隔离闭包共享的会话状态。自带 `Mutex`，是 `Sendable`。
///
/// 这是一个 **`nonisolated`** 的跨 actor 锁盒 —— 绝不能被推断为 `@MainActor`：
/// 它要同时被 `SSHConnection`（actor 隔离域）与 `withPTY` 的非隔离闭包、NIO 上下文
/// 触碰。`withPTY` 的 `perform` 闭包不在 actor 隔离域内执行，无法直接触碰 actor 状态；
/// 这个盒子作为安全的交汇点：actor 端入队写入/resize、写入 close 信号；闭包端发布
/// `TTYStdinWriter`、启动 drain 任务、等待 close。
///
/// 全部可变字段收进 `Storage`，由 `Mutex<Storage>` 守护。每个临界区是一个同步、
/// 非逃逸的 `withLock` 闭包 —— 语义与原 `NSLock.lock()/unlock()` 区段完全一致，
/// 且临界区内不跨 `await`。`Mutex` 使 `SessionState` 天然 `Sendable`，无需 `@unchecked`。
///
/// ## stdin 有序性（C1）
/// 所有 `Op` 进同一个 FIFO `pendingOps`。writer 发布前入队的 Op 留在队列里，writer
/// 发布后 `attach` 启动唯一一个 drain 任务，从队头开始逐个 `await` 应用到 writer。
/// `enqueue` 用 `opSignal` 这个 `AsyncStream` 唤醒 drain 任务。因此从"调用
/// write/resize"到"writer.write/changeSize"只有一条有序路径，不会乱序、不会并发。
private nonisolated final class SessionState: Sendable {

    /// stdin 操作：写入字节或改窗口尺寸。FIFO 顺序应用。
    enum Op {
        case write(Data)
        case resize(cols: Int, rows: Int)
    }

    /// `Mutex` 守护的全部可变状态 —— 原先由 `NSLock` 保护的字段集合。
    private struct Storage {
        /// PTY stdin writer，由 withPTY 闭包发布。
        var writer: TTYStdinWriter?
        /// 单一有序 stdin 操作 FIFO（C1）。writer 就绪前后入队的 Op 都在这里排队。
        var pendingOps: [Op] = []
        /// drain 任务被请求停止（close 或会话结束）。
        var drainStopped = false
        /// 单一 drain 任务句柄，由 `attach` 启动、`shutdownDrain` 取出 await。
        var drainTask: Task<Void, Never>?
        /// close 信号的等待方。
        var closeContinuation: CheckedContinuation<Void, Never>?
        var closeSignalled = false
    }

    private let mutex = Mutex(Storage())

    /// 唤醒 drain 任务的信号流；每入队一个 Op（或请求停止）就 yield 一次。
    private let opSignal: AsyncStream<Void>
    private let opSignalContinuation: AsyncStream<Void>.Continuation

    init() {
        (opSignal, opSignalContinuation) = AsyncStream<Void>.makeStream()
    }

    // MARK: 入队（actor 端调用）

    /// 把一个 stdin 操作放进有序 FIFO，并唤醒 drain 任务。
    /// drain 任务尚未启动（writer 未就绪）也无妨 —— Op 会留在队列里，
    /// `attach` 启动 drain 后立即被消费。
    func enqueue(_ op: Op) {
        let appended = mutex.withLock { storage -> Bool in
            guard !storage.drainStopped else { return false }
            storage.pendingOps.append(op)
            return true
        }
        guard appended else { return }
        opSignalContinuation.yield(())
    }

    // MARK: writer 发布 + drain 启动（withPTY 闭包端调用）

    /// 发布 writer 并启动唯一一个有序 drain 任务。
    func attach(writer: TTYStdinWriter) {
        let alreadyStopped = mutex.withLock { storage -> Bool in
            storage.writer = writer
            return storage.drainStopped
        }

        // 若在 writer 就绪前就已请求停止（极端竞态），不启动 drain。
        guard !alreadyStopped else { return }

        let task = Task {
            await self.drainLoop(writer: writer)
        }
        mutex.withLock { storage in
            storage.drainTask = task
        }
    }

    /// 单一 drain 循环：从 FIFO 队头逐个取 Op，`await` 应用到 writer，再取下一个。
    /// 严格串行 —— 保证 stdin 字节 FIFO 顺序（C1）。
    private func drainLoop(writer: TTYStdinWriter) async {
        for await _ in opSignal {
            // 每次信号尽量排空当前队列。
            while true {
                // 临界区内取出队头 Op（或判定应停止）；`await writer.write`
                // 在锁外执行 —— 与原 NSLock 版本一致，临界区不跨 await。
                let next: Op? = mutex.withLock { storage -> Op? in
                    if storage.pendingOps.isEmpty {
                        return nil
                    }
                    return storage.pendingOps.removeFirst()
                }
                guard let op = next else {
                    let stopped = mutex.withLock { $0.drainStopped }
                    if stopped { return }
                    break
                }

                do {
                    switch op {
                    case .write(let data):
                        try await writer.write(ByteBuffer(bytes: data))
                    case .resize(let cols, let rows):
                        try await writer.changeSize(
                            cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
                    }
                } catch {
                    // 写入 / 改尺寸失败 = stdin 通道已坏（典型：断网后第一笔写
                    // 触发 EPIPE / 通道已关）。继续吞错会让用户对着假活终端打字
                    // —— 发 close 信号让 withPTY 闭包退出、会话立刻收尾，UI 翻
                    // 到「连接已断开 / 重新连接」。正常 close() 期间在飞的写入
                    // 撞上通道关闭也会走到这里 —— signalClose 幂等，无害。
                    signalClose()
                    return
                }
            }
        }
    }

    /// 请求 drain 任务停止并 await 其完成（C2）。
    /// 在 `sessionTask` 内、`withPTY` 返回后调用 —— 返回后保证不再有 writer.write 在飞行。
    func shutdownDrain() async {
        let task = mutex.withLock { storage -> Task<Void, Never>? in
            storage.drainStopped = true
            let task = storage.drainTask
            storage.drainTask = nil
            return task
        }
        // 结束信号流，让 drainLoop 的 `for await` 退出。
        opSignalContinuation.finish()
        await task?.value
    }

    // MARK: close 信号

    /// withPTY 闭包内调用 —— 挂起直到 `signalClose()`。
    func waitForClose() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // 临界区内判定是否已收到 close 信号；resume 在锁外执行 ——
            // 不在持锁时 resume continuation。
            let alreadySignalled = mutex.withLock { storage -> Bool in
                if storage.closeSignalled {
                    return true
                }
                storage.closeContinuation = continuation
                return false
            }
            if alreadySignalled {
                continuation.resume()
            }
        }
    }

    /// actor 端调用 —— 唤醒 `waitForClose()`，使 withPTY 闭包退出。幂等。
    func signalClose() {
        // 临界区内取出等待方；resume 在锁外执行。
        let continuation = mutex.withLock { storage -> CheckedContinuation<Void, Never>? in
            let continuation = storage.closeContinuation
            storage.closeContinuation = nil
            storage.closeSignalled = true
            return continuation
        }
        continuation?.resume()
    }
}
