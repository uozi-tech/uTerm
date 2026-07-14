import Foundation
@_spi(uTermIntegration) import USSHKit

/// uTerm compatibility adapter for the shared local forwarding listener.
actor LocalForwardListener {
    private let shared: USSHKit.LocalForwardListener

    init(
        connected: ConnectedClient,
        listenHost: String,
        listenPort: Int,
        destHost: String,
        destPort: Int,
        counter: TunnelByteCounter? = nil,
        onChannelFailure: @escaping @Sendable (Error) -> Void = { _ in },
        onTunnelClosed: @escaping @Sendable (TunnelOutcome) -> Void = { _ in }
    ) {
        self.shared = USSHKit.LocalForwardListener(
            connected: connected.shared,
            listenHost: listenHost,
            listenPort: listenPort,
            destHost: destHost,
            destPort: destPort,
            logger: ForwardingSSHLogger(),
            counter: counter?.shared,
            onChannelFailure: onChannelFailure,
            onTunnelClosed: { outcome in
                onTunnelClosed(TunnelOutcome(shared: outcome))
            }
        )
    }

    func start() async throws {
        _ = try await shared.start()
    }

    func close() async {
        await shared.close()
    }
}

private struct ForwardingSSHLogger: USSHKit.SSHLogger {
    func log(_ event: USSHKit.SSHLogEvent) {
        switch event.level {
        case .trace, .debug, .info:
            AppLogger.info(event.message, category: ForwardingLog.category)
        case .warning, .error:
            AppLogger.error(event.message, category: ForwardingLog.category)
        }
    }
}

nonisolated enum ForwardingLog {
    static let category = "forwarding"
}
