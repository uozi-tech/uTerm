import Foundation
@preconcurrency import Citadel
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
actor LocalForwardListener {
    private let connected: ConnectedClient
    private let listenHost: String
    private let listenPort: Int
    private let destHost: String
    private let destPort: Int

    /// 绑定后的监听通道，`close()` 时关闭。
    private var serverChannel: Channel?

    init(connected: ConnectedClient,
         listenHost: String, listenPort: Int,
         destHost: String, destPort: Int) {
        self.connected = connected
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.destHost = destHost
        self.destPort = destPort
    }

    /// 绑定本地监听并开始接受连接。`bind` 失败时抛出（端口冲突 / 权限）。
    func start() async throws {
        let eventLoop = connected.target.eventLoop
        let connected = self.connected
        let destHost = self.destHost
        let destPort = self.destPort

        let bootstrap = ServerBootstrap(group: eventLoop)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            // 半关键设(#5)：客户端发完请求后半关写端(FIN)时**不要**把整通道判为关闭。
            // 默认 allowRemoteHalfClosure=false 下对端 FIN 会触发 channelInactive(整通道关)，
            // 于是目标仍在流式回包就被 TunnelGlue 取消截断。设 true 后对端 FIN 只让本地入站读到
            // EOF、出站仍可写 → 目标的响应能完整写回客户端；配合 isOutboundHalfClosureEnabled
            // 让响应排空后 outbound.finish() 真的向客户端发 FIN。
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { childChannel in
                // 把本地 socket 立即设为 NIOAsyncChannel 之前不加任何 handler；
                // 实际的 direct-tcpip 开通道 + 粘合在 accept 后的 Task 里做。
                childChannel.eventLoop.makeSucceededVoidFuture()
            }

        let serverChannel: Channel
        do {
            serverChannel = try await bootstrap.bind(host: listenHost, port: listenPort).get()
        } catch {
            // bind 失败 —— 端口被占用 / 权限不足。原样抛出，由上层归类。
            throw error
        }
        self.serverChannel = serverChannel

        AppLogger.info(
            "本地转发已绑定 \(self.listenHost):\(self.listenPort) → \(self.destHost):\(self.destPort)",
            category: ForwardingLog.category)

        // 接受循环：把 server channel 包成 NIOAsyncChannel<本地 socket Channel>，
        // 每个新连接派一个子 Task 开 direct-tcpip 并粘合。
        let asyncServer = try NIOAsyncChannel<Channel, Never>(
            wrappingChannelSynchronously: serverChannel)

        Task {
            do {
                try await asyncServer.executeThenClose { inbound in
                    try await withThrowingDiscardingTaskGroup { group in
                        for try await localChannel in inbound {
                            group.addTask {
                                await Self.handleAccepted(
                                    localChannel,
                                    connected: connected,
                                    destHost: destHost, destPort: destPort)
                            }
                        }
                    }
                }
            } catch {
                // server channel 关闭（stop/close）会让 inbound 结束 —— 正常退出。
            }
        }
    }

    /// 处理一个 accept 的本地连接：开 direct-tcpip 到目标 → 双向粘合。
    private static func handleAccepted(
        _ localChannel: Channel,
        connected: ConnectedClient,
        destHost: String, destPort: Int
    ) async {
        do {
            // 目标地址快照（SOCKS5 / direct-tcpip 的 originator 用占位地址即可）。
            let originator = try SocketAddress(ipAddress: "fe80::1", port: 22)
            let directChannel = try await connected.target.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(
                    targetHost: destHost,
                    targetPort: destPort,
                    originatorAddress: originator),
                initialize: { $0.eventLoop.makeSucceededVoidFuture() })

            // 本地端开出站半关：响应排空后 TunnelGlue 的 outbound.finish() 向客户端发 FIN，
            // 让客户端读到 EOF（默认 false 时 finish() 只本地结束、不发 FIN）。
            let localAsync = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: localChannel,
                configuration: .init(isOutboundHalfClosureEnabled: true))
            // 远端 direct-tcpip 是 SSH 通道，半关语义交由 NIOSSH/Citadel 默认处理，不在此开启。
            let remoteAsync = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: directChannel)

            await TunnelGlue.pipe(localAsync, remoteAsync)
        } catch {
            AppLogger.error(
                "本地转发开通道失败 → \(destHost):\(destPort)：\(error.localizedDescription)",
                category: ForwardingLog.category)
            try? await localChannel.close()
        }
    }

    /// 关闭监听通道并停止接受新连接。已建立的隧道由各自的粘合 Task 自然收尾。
    func close() async {
        if let serverChannel {
            try? await serverChannel.close()
            self.serverChannel = nil
            AppLogger.info("本地转发已停止 \(self.listenHost):\(self.listenPort)",
                           category: ForwardingLog.category)
        }
    }
}

/// 转发日志的 category 常量 —— 防手滑拼错。
nonisolated enum ForwardingLog {
    static let category = "forwarding"
}
