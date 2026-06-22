import Foundation

/// 转发开通道（direct-tcpip）超时保护用错误。
nonisolated struct ForwardingTimeoutError: Error, Sendable {
    var localizedDescription: String { "开通道超时（上游无响应）" }
}

/// 给一个 async 操作套超时：操作先完成则返回其结果并取消计时；超时先到则抛
/// `ForwardingTimeoutError` 并取消操作子任务。
///
/// 动机：`createDirectTCPIPChannel` 在**半死的 SSH 传输**上可能既发不出也收不到
/// 响应而无限挂起 —— 此时本地已 accept 的 socket 既不被粘合也不被关闭，客户端
/// （如 psql）自行超时关闭后，本地 socket 堆成 `CLOSE_WAIT`。套上超时后上游卡住
/// 会快速失败，调用方据此关闭本地 socket（客户端立刻拿到 reset 而非干等数十秒），
/// 不再堆 `CLOSE_WAIT`。僵尸连接本身由 `ConnectionWatchdog` 的周期心跳判死拆除。
///
/// 注意：Citadel 的开通道调用不保证响应取消；超时路径下 `cancelAll()` 未必能立刻
/// 中断底层调用，遗留子任务会在 SSH 连接最终被看门狗判死关闭时解除。语义上无害 ——
/// 我们已抛超时、调用方已关本地 socket。
nonisolated func withForwardingTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw ForwardingTimeoutError()
        }
        guard let result = try await group.next() else { throw ForwardingTimeoutError() }
        group.cancelAll()
        return result
    }
}
