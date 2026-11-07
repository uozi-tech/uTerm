import Foundation

/// 重连退避的等待：到时间自然醒，也能被「网络恢复 / 回到前台」提前叫醒。否则 Wi-Fi 刚回来，
/// 标签可能还要白等好几秒才试下一次。
///
/// 等待挂在 continuation 上，被 `kick()` 直接唤醒，而不是每 100 ms 醒来看一眼代号：
/// Mac 睡着、断网这类长时间连不上的时候，每个远控标签和桌面流都停在这里退避，轮询版每个等待者每秒把 CPU
/// 叫醒 10 次（手机上电量的大头之一是这种零碎唤醒）。现在一次等待只有一个系统定时器，期间 CPU 可以一直睡。
/// 对外语义不变：到时返回 false，被叫醒返回 true，任务取消时立即返回 false。
nonisolated final class RemoteRetryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func kick() {
        let woken: [CheckedContinuation<Void, Never>] = lock.withLock {
            generation += 1
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for waiter in woken { waiter.resume() }
    }

    /// 等 `delay`。返回 true 表示被提前叫醒（调用方应当把退避重置）。
    func wait(_ delay: Duration) async -> Bool {
        let start = lock.withLock { generation }
        // 两路赛跑：定时器到点 / 被叫醒，谁先到用谁，另一路随即取消。
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await Task.sleep(for: delay)
                return false
            }
            group.addTask {
                await self.waitForKick(after: start)
                // 任务被取消（外层取消或定时器先到）也会从这里出来，那不算被叫醒。
                return !Task.isCancelled
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// 等到代号离开 `start`（被 `kick` 过）或任务被取消。
    private func waitForKick(after start: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // 取消标记先于 onCancel 设置：onCancel 若抢在登记前跑了，这里一定看得到 isCancelled，不会挂死。
                let resumeNow = lock.withLock { () -> Bool in
                    if generation != start || Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            // 和 kick 抢同一个 continuation：谁在锁里拿到谁负责 resume，保证只恢复一次。
            let continuation = lock.withLock { waiters.removeValue(forKey: id) }
            continuation?.resume()
        }
    }
}
