import Foundation

/// 给一段不一定响应取消的异步操作套时限：时限从调用这一刻开始算，到点就抛 `timeoutError`，不等操作自己结束。
///
/// 建连链路上有好几处等待本身不响应取消（`NWConnection` 的回调、continuation）。用 `withTaskGroup` 赛跑的话，
/// 时限到了组也要等那个子任务结束才返回，等于没有时限。这里让操作跑在独立任务里：到点先返回，操作的任务被取消，
/// 它之后要是还交出了结果（比如一条已经接通的连接），交给 `discard` 收尾，别漏掉。
nonisolated enum RemoteDeadline {
    static func run<Value: Sendable>(
        _ limit: Duration,
        timeoutError: @autoclosure @Sendable () -> Error,
        discard: @escaping @Sendable (Value) -> Void = { _ in },
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let gate = Gate<Value>()
        let error = timeoutError()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                gate.install(continuation)
                let work = Task {
                    do {
                        let value = try await operation()
                        if !gate.finish(.success(value)) { discard(value) }
                    } catch {
                        gate.finish(.failure(error))
                    }
                }
                gate.setWork(work)
                Task {
                    try? await Task.sleep(for: limit)
                    if gate.finish(.failure(error)) { work.cancel() }
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    /// 结果只交一次：操作、时限、外层取消三路谁先到用谁。
    private final class Gate<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var work: Task<Void, Never>?
        private var cancelled = false

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            let cancelNow = lock.withLock { () -> Bool in
                if cancelled { return true }
                self.continuation = continuation
                return false
            }
            if cancelNow { continuation.resume(throwing: CancellationError()) }
        }

        func setWork(_ work: Task<Void, Never>) {
            let cancelNow = lock.withLock { () -> Bool in
                self.work = work
                return cancelled
            }
            if cancelNow { work.cancel() }
        }

        /// 返回 true 表示这次交出了结果。
        @discardableResult
        func finish(_ result: Result<Value, Error>) -> Bool {
            let taken = lock.withLock { () -> CheckedContinuation<Value, Error>? in
                defer { continuation = nil }
                return continuation
            }
            guard let taken else { return false }
            taken.resume(with: result)
            return true
        }

        func cancel() {
            let (taken, work) = lock.withLock { () -> (CheckedContinuation<Value, Error>?, Task<Void, Never>?) in
                cancelled = true
                defer { continuation = nil }
                return (continuation, self.work)
            }
            work?.cancel()
            taken?.resume(throwing: CancellationError())
        }
    }
}
