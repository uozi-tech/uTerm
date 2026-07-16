import Foundation
@preconcurrency import Citadel
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH

/// `-L` 本地转发监听器。
///
/// 在 `client.eventLoop`（NIOSSH 单 EventLoop，与所有 channel 操作同环）上用
/// `ServerBootstrap` 绑定 `listenHost:listenPort`。每个 accept 的本地 socket：
///   1. `createDirectTCPIPChannel` 经 SSH 连接到 `destHost:destPort`
///      （Citadel 已在该通道加好 `DataToBufferCodec`）；
///   2. 把本地 socket 与 direct-tcpip 通道都包成 `NIOAsyncChannel<ByteBuffer,ByteBuffer>`；
///   3. `TunnelGlue.pipe` 双向泵。
///
/// 保留绑定后的监听 `Channel` 句柄，`close()` 时显式关闭 —— 否则端口占用泄漏。
/// `bind` 失败（端口被占 / 权限不足）通过 `start()` 抛出，由上层 `ForwardingError.classify` 归类。
///
/// 持有 `ConnectedClient`（`@unchecked Sendable`）以在每次 accept 时开 direct-tcpip
/// 通道 —— 与 `SFTPSession` 持有 `connected` 的做法一致。`SSHClient` 非 `Sendable`，
/// 仅经 `ConnectedClient` 在本类作用域内触碰，不跨隔离域并发使用。
@_spi(uTermIntegration)
public actor LocalForwardListener {
    private let connected: ConnectedClient
    private let listenHost: String
    private let listenPort: Int
    private let destHost: String
    private let destPort: Int
    private let channelOpenTimeout: Duration
    private let logger: any SSHLogger
    /// 本规则的流量计数器（所有 accept 的连接共享，得到规则合计）。
    private let counter: TunnelByteCounter?
    private let onChannelFailure: @Sendable (Error) -> Void
    /// 一条隧道结束时回报概况，供上层识别「开通道成功但后端瞬间 0 字节 EOF」这类失败
    /// （对 `onChannelFailure`——只在开通道失败时触发——不可见）。
    private let onTunnelClosed: @Sendable (TunnelOutcome) -> Void

    /// 绑定后的监听通道，`close()` 时关闭。
    private var serverChannel: Channel?
    /// 关闭中标志（线程安全，供 childChannelInitializer 在 EventLoop 上读取）。置位后新 accept
    /// 的 child 不再包成 NIOAsyncChannel —— 否则「关闭 ↔ accept」竞态下，来不及被 accept 循环
    /// 消费的 child 其出站 writer 未 finish 即析构 → NIO preconditionFailure abort（崩溃栈即此）。
    private let closing = NIOLockedValueBox(false)

    public init(connected: ConnectedClient,
         listenHost: String, listenPort: Int,
         destHost: String, destPort: Int,
         channelOpenTimeout: Duration = .seconds(10),
         logger: any SSHLogger = NoOpSSHLogger(),
         counter: TunnelByteCounter? = nil,
         onChannelFailure: @escaping @Sendable (Error) -> Void = { _ in },
         onTunnelClosed: @escaping @Sendable (TunnelOutcome) -> Void = { _ in }) {
        self.connected = connected
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.destHost = destHost
        self.destPort = destPort
        self.channelOpenTimeout = channelOpenTimeout
        self.logger = logger
        self.counter = counter
        self.onChannelFailure = onChannelFailure
        self.onTunnelClosed = onTunnelClosed
    }

    /// 绑定本地监听并开始接受连接。`bind` 失败时抛出（端口冲突 / 权限）。
    public func start() async throws -> Int {
        let eventLoop = connected.target.eventLoop
        let connected = self.connected
        let destHost = self.destHost
        let destPort = self.destPort
        let counter = self.counter
        let onChannelFailure = self.onChannelFailure
        let onTunnelClosed = self.onTunnelClosed
        let closing = self.closing
        let channelOpenTimeout = self.channelOpenTimeout
        let logger = self.logger

        // 关键（修早期字节丢弃竞态，PG「客户端先说话」一连上就发 SSLRequest）：用 bind 的
        // async 重载，在 childChannelInitializer 里、**child 激活之前、于其 EventLoop 上**就把
        // 本地 socket 包成 NIOAsyncChannel —— 消费 handler 在第一个 read 之前装好，既不会把客户端
        // 抢先发来的首字节读进空 pipeline 丢弃，读也由 NIOAsyncChannel 正常驱动（autoRead 保持默认）。
        // accept 循环拿到的就是「已包好的」NIOAsyncChannel<ByteBuffer,ByteBuffer>。
        //   反例（曾导致 closed unexpectedly / 超时）：accept 后才在 handleAccepted 里包 —— accept 到
        //   wrap 之间有空窗，autoRead 抢读首字节丢弃；而关掉 autoRead 又会掐死 NIOAsyncChannel 读路。
        // 半关(#5)：allowRemoteHalfClosure=true 让对端 FIN 只让本地入站 EOF、出站仍可写；
        // isOutboundHalfClosureEnabled=true 让响应排空后 finish() 真向客户端发 FIN。
        // makeCompletedFuture 在 child 的 EL 上同步跑闭包 → wrappingChannelSynchronously 的
        // preconditionInEventLoop 满足（不会 trap）。
        let listener: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
        do {
            listener = try await ServerBootstrap(group: eventLoop)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                // 禁用 Nagle：转发连接多为请求/响应（DB 等），Nagle + delayed-ACK 会给每个
                // 往返叠加 ~40ms 延迟。对齐 OpenSSH 对 forwarded 连接的默认行为。
                .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                .bind(host: listenHost, port: listenPort) { childChannel in
                    childChannel.eventLoop.makeCompletedFuture {
                        // 关闭竞态守卫：监听器正在关闭时不再包装，抛错让 NIO 直接关掉该 child
                        // （无 NIOAsyncChannel 被创建 → 无未 finish 的出站 writer → 不 abort）。
                        guard !closing.withLockedValue({ $0 }) else {
                            throw ChannelError.ioOnClosedChannel
                        }
                        return try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                            wrappingChannelSynchronously: childChannel,
                            configuration: .init(isOutboundHalfClosureEnabled: true))
                    }
                }
        } catch {
            // bind 失败 —— 端口被占用 / 权限不足。原样抛出，由上层归类。
            throw error
        }
        self.serverChannel = listener.channel

        let boundPort = listener.channel.localAddress?.port ?? listenPort
        logger.log(SSHLogEvent(
            level: .info,
            message: "本地转发已绑定 \(listenHost):\(boundPort) → \(destHost):\(destPort)"
        ))

        // 接受循环：每个新连接（已是包好的 NIOAsyncChannel）派一个子 Task 开 direct-tcpip 并粘合。
        Task {
            do {
                try await listener.executeThenClose { inbound in
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await localAsync in inbound {
                            group.addTask {
                                await Self.handleAccepted(
                                    localAsync,
                                    connected: connected,
                                    destHost: destHost, destPort: destPort,
                                    channelOpenTimeout: channelOpenTimeout,
                                    logger: logger,
                                    counter: counter,
                                    onChannelFailure: onChannelFailure,
                                    onTunnelClosed: onTunnelClosed)
                            }
                        }
                    }
                }
            } catch {
                // server channel 关闭（stop/close）会让 inbound 结束 —— 正常退出。
            }
        }
        return boundPort
    }

    /// 处理一个 accept 的本地连接（已在 childChannelInitializer 包成 NIOAsyncChannel）：
    /// 开 direct-tcpip 到目标 → 双向粘合。
    private static func handleAccepted(
        _ localAsync: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        connected: ConnectedClient,
        destHost: String, destPort: Int,
        channelOpenTimeout: Duration,
        logger: any SSHLogger,
        counter: TunnelByteCounter?,
        onChannelFailure: @escaping @Sendable (Error) -> Void,
        onTunnelClosed: @escaping @Sendable (TunnelOutcome) -> Void
    ) async {
        let remoteAsync: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        do {
            // 开 direct-tcpip 到目标，套超时（半死传输上开通道可能无限挂起，超时则抛错）。
            remoteAsync = try await withForwardingTimeout(
                channelOpenTimeout,
                lateResultCleanup: { channel in try? await channel.channel.close() }
            ) {
                try await connected.openDirectTCPIP(host: destHost, port: destPort)
            }
        } catch {
            // 归类成人话再进日志 —— 原始 NIOSSHError 经 localizedDescription 只会
            // 显示「NIOSSH.NIOSSHError错误1」这类 NSError 桥接文本，没法排查。
            let failure = SSHForwardingChannelFailure(classifying: error)
            logger.log(SSHLogEvent(
                level: .error,
                message: "本地转发开通道失败：\(failure.userMessage(targetHost: destHost, targetPort: destPort))［\(failure.detail)］"
            ))
            onChannelFailure(error)
            // 关键：此时 localAsync 尚未被消费，**必须**经 executeThenClose 收尾——它会 finish 出站
            // writer 再关通道。仅 `channel.close()` 只 finish sink、**不** finish writer，localAsync
            // 析构时 writer 未 finish → NIO `preconditionFailure("Deinited NIOAsyncWriter without
            // calling finish()")` 把整进程 abort（线上目标抖动 / 开通道超时即崩）。空闭包即正常收尾、
            // 丢弃这条客户端连接。
            try? await localAsync.executeThenClose { _, _ in }
            return
        }
        // 成功：双向粘合。TunnelGlue.pipe 经 executeThenClose 消费 localAsync 与 remoteAsync
        // （两端 writer 都会 finish）；非抛出。返回隧道概况供上层识别「开通道成功但后端瞬间
        // 0 字节 EOF」——此形对 onChannelFailure（只在开通道失败时触发）不可见。
        let outcome = await TunnelGlue.pipe(localAsync, remoteAsync, counter: counter)
        onTunnelClosed(outcome)
    }

    /// 关闭监听通道并停止接受新连接。已建立的隧道由各自的粘合 Task 自然收尾。
    public func close() async {
        // 先置「关闭中」：此后新 accept 的 child 在 initializer 里被拒绝包装（见 start），
        // 避免与 server channel 关闭竞态产生「来不及消费即析构」的 NIOAsyncChannel。
        closing.withLockedValue { $0 = true }
        if let serverChannel {
            try? await serverChannel.close()
            self.serverChannel = nil
            logger.log(SSHLogEvent(
                level: .info,
                message: "本地转发已停止 \(listenHost):\(listenPort)"
            ))
        }
    }
}
