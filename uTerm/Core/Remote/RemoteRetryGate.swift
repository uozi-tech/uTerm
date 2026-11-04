import Foundation

/// 重连退避的等待：到时间自然醒，也能被「网络恢复 / 回到前台」提前叫醒。否则 Wi-Fi 刚回来，
/// 标签可能还要白等好几秒才试下一次。
///
/// 用短间隔轮询代号，而不是挂 continuation：只有断线期间才在等，代价可以忽略，取消也不用另外处理。
nonisolated final class RemoteRetryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0

    func kick() {
        lock.withLock { generation += 1 }
    }

    /// 等 `delay`。返回 true 表示被提前叫醒（调用方应当把退避重置）。
    func wait(_ delay: Duration) async -> Bool {
        let start = lock.withLock { generation }
        let clock = ContinuousClock()
        let deadline = clock.now + delay
        while clock.now < deadline, !Task.isCancelled {
            if lock.withLock({ generation }) != start { return true }
            try? await Task.sleep(for: min(.milliseconds(100), deadline - clock.now))
        }
        return false
    }
}
