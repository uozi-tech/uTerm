import Foundation
@_spi(uTermIntegration) import USSHKit

nonisolated struct ForwardingTimeoutError: LocalizedError, Sendable {
    var errorDescription: String? { "开通道超时（上游无响应）" }
}

nonisolated func withForwardingTimeout<T: Sendable>(
    _ duration: Duration,
    lateResultCleanup: @escaping @Sendable (T) async -> Void = { _ in },
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    do {
        return try await USSHKit.withForwardingTimeout(
            duration,
            lateResultCleanup: lateResultCleanup,
            operation
        )
    } catch is USSHKit.ForwardingTimeoutError {
        throw ForwardingTimeoutError()
    }
}
