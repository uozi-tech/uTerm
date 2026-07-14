import Foundation

/// 转发开通道（direct-tcpip）超时保护用错误。
@_spi(uTermIntegration)
public nonisolated struct ForwardingTimeoutError: LocalizedError, Sendable {
    public var errorDescription: String? { "开通道超时（上游无响应）" }
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
/// 注意：这里不能用 `withThrowingTaskGroup` race。结构化并发作用域退出前会等待
/// 所有 child task 收尾；而 Citadel 的开通道调用不保证响应取消，半死传输上可能
/// 永远挂住，导致“超时分支先完成，但函数仍等操作子任务结束”，本地 listener 看着
/// 还在、accept 处理却卡死。这里改用非结构化任务 + 一次性 continuation：超时后
/// 立即恢复调用方，后台操作若很晚才成功，交给 `lateResultCleanup` 关闭迟到资源。
@_spi(uTermIntegration)
public nonisolated func withForwardingTimeout<T: Sendable>(
    _ duration: Duration,
    lateResultCleanup: @escaping @Sendable (T) async -> Void = { _ in },
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = ForwardingTimeoutRace<T>()
    return try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)

            let operationTask = Task {
                do {
                    let value = try await operation()
                    let accepted = race.succeed(value)
                    if !accepted {
                        await lateResultCleanup(value)
                    }
                } catch {
                    race.failFromOperation(error)
                }
            }
            race.setOperationTask(operationTask)

            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return
                }
                race.timeout()
            }
            race.setTimeoutTask(timeoutTask)
        }
    }, onCancel: {
        race.cancel()
    })
}

private nonisolated final class ForwardingTimeoutRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pendingResult: Result<T, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<T, Error>) {
        let result: Result<T, Error>?
        lock.lock()
        if finished {
            result = pendingResult
        } else {
            self.continuation = continuation
            result = nil
        }
        lock.unlock()

        if let result {
            continuation.resume(with: result)
        }
    }

    func setOperationTask(_ task: Task<Void, Never>) {
        setTask(task, keyPath: \.operationTask)
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        setTask(task, keyPath: \.timeoutTask)
    }

    @discardableResult
    func succeed(_ value: T) -> Bool {
        complete(.success(value), cancelOperation: false, cancelTimeout: true)
    }

    func failFromOperation(_ error: Error) {
        complete(.failure(error), cancelOperation: false, cancelTimeout: true)
    }

    func timeout() {
        complete(.failure(ForwardingTimeoutError()), cancelOperation: true, cancelTimeout: false)
    }

    func cancel() {
        complete(.failure(CancellationError()), cancelOperation: true, cancelTimeout: true)
    }

    private func setTask(_ task: Task<Void, Never>,
                         keyPath: ReferenceWritableKeyPath<ForwardingTimeoutRace<T>, Task<Void, Never>?>) {
        let shouldCancel: Bool
        lock.lock()
        if finished {
            shouldCancel = true
        } else {
            self[keyPath: keyPath] = task
            shouldCancel = false
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    @discardableResult
    private func complete(_ result: Result<T, Error>,
                          cancelOperation: Bool,
                          cancelTimeout: Bool) -> Bool {
        let continuation: CheckedContinuation<T, Error>?
        let operationTask: Task<Void, Never>?
        let timeoutTask: Task<Void, Never>?

        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        pendingResult = result
        continuation = self.continuation
        self.continuation = nil
        operationTask = cancelOperation ? self.operationTask : nil
        timeoutTask = cancelTimeout ? self.timeoutTask : nil
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
        return true
    }
}
