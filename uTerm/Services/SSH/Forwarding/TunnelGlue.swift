import NIOCore
@_spi(uTermIntegration) import USSHKit

nonisolated final class TunnelByteCounter: Sendable {
    let shared = USSHKit.TunnelByteCounter()

    func addUp(_ count: Int) { shared.addUp(count) }
    func addDown(_ count: Int) { shared.addDown(count) }
    var snapshot: (up: UInt64, down: UInt64) { shared.snapshot }
}

nonisolated struct TunnelOutcome: Sendable {
    let bytesUp: UInt64
    let bytesDown: UInt64
    let remoteClosedFirst: Bool
    let lifetime: Duration

    init(
        bytesUp: UInt64,
        bytesDown: UInt64,
        remoteClosedFirst: Bool,
        lifetime: Duration
    ) {
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.remoteClosedFirst = remoteClosedFirst
        self.lifetime = lifetime
    }

    init(shared: USSHKit.TunnelOutcome) {
        self.init(
            bytesUp: shared.bytesUp,
            bytesDown: shared.bytesDown,
            remoteClosedFirst: shared.remoteClosedFirst,
            lifetime: shared.lifetime
        )
    }

    var suspectsInstantClose: Bool {
        remoteClosedFirst && bytesDown == 0 && lifetime < .seconds(2)
    }
}

/// Compatibility namespace for uTerm's existing forwarding and regression tests.
nonisolated enum TunnelGlue {
    @discardableResult
    static func pipe(
        _ a: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        _ b: NIOAsyncChannel<ByteBuffer, ByteBuffer>,
        counter: TunnelByteCounter? = nil
    ) async -> TunnelOutcome {
        TunnelOutcome(shared: await USSHKit.TunnelGlue.pipe(a, b, counter: counter?.shared))
    }
}
