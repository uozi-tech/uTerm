import Foundation
@_spi(uTermIntegration) import USSHKit

nonisolated struct ForwardingTimeoutError: LocalizedError, Sendable {
    var errorDescription: String? { String(localized: "打开转发通道超时（目标没有响应）") }
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
