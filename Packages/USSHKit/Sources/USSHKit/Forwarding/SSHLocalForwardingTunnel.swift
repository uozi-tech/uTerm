import Foundation

public actor SSHLocalForwardingTunnel: SSHForwardingTunnel {
    private let request: SSHForwardingRequest
    private let hostKeyStore: any HostKeyStore
    private let hostKeyPolicy: SSHHostKeyPolicy
    private let connectTimeout: Duration
    private let channelOpenTimeout: Duration
    private let approvalTimeout: Duration
    private let approver: @Sendable (SSHHostKeyChallenge) async -> Bool
    private let logger: any SSHLogger
    /// 隧道建立后、某条本地连接开 direct-tcpip 通道失败时回调（已归类）。
    /// 供应用层把「隧道通了但跳板机开不到目标」的真实原因浮出到 UI。
    private let onChannelFailure: @Sendable (SSHForwardingChannelFailure) -> Void

    private var connected: ConnectedClient?
    private var listener: LocalForwardListener?
    private var isClosed = false

    public init(
        request: SSHForwardingRequest,
        hostKeyStore: any HostKeyStore,
        hostKeyPolicy: SSHHostKeyPolicy = .strict,
        connectTimeout: Duration = .seconds(30),
        channelOpenTimeout: Duration = .seconds(10),
        approvalTimeout: Duration = .seconds(180),
        logger: any SSHLogger = NoOpSSHLogger(),
        approver: @escaping @Sendable (SSHHostKeyChallenge) async -> Bool = { _ in false },
        onChannelFailure: @escaping @Sendable (SSHForwardingChannelFailure) -> Void = { _ in }
    ) {
        self.request = request
        self.hostKeyStore = hostKeyStore
        self.hostKeyPolicy = hostKeyPolicy
        self.connectTimeout = connectTimeout
        self.channelOpenTimeout = channelOpenTimeout
        self.approvalTimeout = approvalTimeout
        self.logger = logger
        self.approver = approver
        self.onChannelFailure = onChannelFailure
    }

    public func open() async throws -> SSHForwardingEndpoint {
        guard connected == nil, listener == nil else {
            throw SSHConnectionError.alreadyOpen
        }
        guard !isClosed else {
            throw SSHConnectionError.closed
        }

        let connected = try await SSHClientFactory.connect(
            endpoint: request.endpoint,
            credential: request.credential,
            hostKeyStore: hostKeyStore,
            hostKeyPolicy: hostKeyPolicy,
            connectTimeout: connectTimeout,
            approvalTimeout: approvalTimeout,
            approver: approver
        )

        let onChannelFailure = self.onChannelFailure
        let listener = LocalForwardListener(
            connected: connected,
            listenHost: request.localHost,
            listenPort: request.localPort,
            destHost: request.target.host,
            destPort: request.target.port,
            channelOpenTimeout: channelOpenTimeout,
            logger: logger,
            onChannelFailure: { error in
                onChannelFailure(SSHForwardingChannelFailure(classifying: error))
            }
        )
        do {
            let port = try await listener.start()
            self.connected = connected
            self.listener = listener
            return SSHForwardingEndpoint(host: request.localHost, port: port)
        } catch {
            await connected.close()
            throw SSHConnectionError.bindFailed(error.localizedDescription)
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        let listener = self.listener
        let connected = self.connected
        self.listener = nil
        self.connected = nil
        await listener?.close()
        await connected?.close()
    }
}
