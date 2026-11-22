import Foundation

// 文件请求的等待表与时限：两个方向（主控端发、被控端反过来发）共用。远控进程也编它，所以和 `RemoteMacFileProvider`（只在主控端用）分开放。

/// 等文件应答的表。任意线程登记，连接队列上交付。
nonisolated final class RemoteFileWaiters: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: (continuation: CheckedContinuation<Data, Error>, watchdog: Task<Void, Never>)] = [:]

    func add(_ id: UUID, _ continuation: CheckedContinuation<Data, Error>, watchdog: Task<Void, Never>) {
        lock.lock()
        waiters[id] = (continuation, watchdog)
        lock.unlock()
    }

    private func take(_ id: UUID) -> (continuation: CheckedContinuation<Data, Error>, watchdog: Task<Void, Never>)? {
        lock.lock()
        defer { lock.unlock() }
        return waiters.removeValue(forKey: id)
    }

    /// 一条应答到了：按请求号交给等它的人。没人等（已经超时或取消）就丢掉。
    func deliver(_ payload: Data) {
        guard let id = RemoteFileCodec.requestID(of: payload), let waiter = take(id) else { return }
        waiter.watchdog.cancel()
        waiter.continuation.resume(returning: payload)
    }

    func fail(_ id: UUID, _ error: Error) {
        guard let waiter = take(id) else { return }
        waiter.watchdog.cancel()
        waiter.continuation.resume(throwing: error)
    }

    func failAll(_ error: Error) {
        lock.lock()
        let all = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in all.values {
            waiter.watchdog.cancel()
            waiter.continuation.resume(throwing: error)
        }
    }
}

extension RemoteFileWaiters {
    /// 登记一条请求、发出去、等它的应答。到时限没回、任务被取消都会把登记撤掉。
    /// - Parameter peer: 对端怎么称呼（超时的提示里用）。
    func exchange(_ payload: Data, id: UUID, timeout: Duration, peer: String,
                  send: @escaping @Sendable (Data) -> Void) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let watchdog = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self.fail(id, RemoteFileError(.timeout, String(localized: "\(peer) 在 \(RemoteConnectTrace.millis(timeout) / 1000) 秒内没有回应")))
                }
                add(id, continuation, watchdog: watchdog)
                // 取消可能早于登记：那时取消回调已经扑空了，这里补上。
                if Task.isCancelled {
                    fail(id, CancellationError())
                    return
                }
                send(payload)
            }
        } onCancel: {
            self.fail(id, CancellationError())
        }
    }
}

/// 一条请求最多等多久。被控端自己有时限的操作，在它的时限上再留一点余量。
nonisolated enum RemoteFileTimeouts {
    static func limit(for request: RemoteFileRequest) -> Duration {
        switch request.op {
        case .exec:
            return .seconds(min(max(1, request.maxDuration ?? 3600), 21600) + 30)
        case .waitChange:
            return .seconds(min(max(0.1, request.seconds ?? 30), 600) + 15)
        case .grep, .find, .du, .tree:
            return .seconds(45)
        case .patch:
            return .seconds(150)
        case .hash, .copy, .remove:
            return .seconds(600)
        default:
            return .seconds(60)
        }
    }
}
