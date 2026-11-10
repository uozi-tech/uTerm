import Foundation

/// 与打洞同时进行的那次中继拨号。打洞赢了就放弃它；它之后要是还接通了，收到的连接立刻关掉
///（Mac 那头随中继一起断开，不会挂着等握手）。
nonisolated final class RemoteRelayRace: @unchecked Sendable {
    private let task: Task<any RemoteTransport, Error>
    private let lock = NSLock()
    private var abandoned = false

    init(_ dial: @escaping @Sendable () async throws -> any RemoteTransport) {
        task = Task { try await dial() }
    }

    /// 等中继接通。
    func value() async throws -> any RemoteTransport {
        try await task.value
    }

    /// 不要它了：已经接通的关掉，还没接通的接通后关掉。
    func abandon() {
        let first = lock.withLock { () -> Bool in
            defer { abandoned = true }
            return !abandoned
        }
        guard first else { return }
        let task = self.task
        Task {
            if let transport = try? await task.value { transport.cancel() }
        }
    }
}

/// 直连与中继谁先给出能用的连接。
nonisolated enum RemotePathPick: Sendable {
    case direct(RemoteP2PTransport, detail: String)
    case relay(any RemoteTransport, directDetail: String?)
    case failed(Error, directDetail: String?)

    /// 打洞那一路还在进行（`direct` 没结束）时，中继先到也算数；直连先失败就只等中继。
    static func first(direct: Task<(transport: RemoteP2PTransport?, detail: String), Never>,
                      relay: RemoteRelayRace) async -> RemotePathPick {
        let box = PickBox()
        return await withCheckedContinuation { continuation in
            box.install(continuation)
            Task {
                let outcome = await direct.value
                box.directFinished(outcome)
            }
            Task {
                do {
                    box.relayFinished(.success(try await relay.value()))
                } catch {
                    box.relayFinished(.failure(error))
                }
            }
        }
    }

    private final class PickBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<RemotePathPick, Never>?
        private var direct: (transport: RemoteP2PTransport?, detail: String)?
        private var relay: Result<any RemoteTransport, Error>?

        func install(_ continuation: CheckedContinuation<RemotePathPick, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func directFinished(_ outcome: (transport: RemoteP2PTransport?, detail: String)) {
            lock.withLock { direct = outcome }
            decide()
        }

        func relayFinished(_ result: Result<any RemoteTransport, Error>) {
            lock.withLock { relay = result }
            decide()
        }

        private func decide() {
            let (taken, pick): (CheckedContinuation<RemotePathPick, Never>?, RemotePathPick?) = lock.withLock {
                guard let continuation else { return (nil, nil) }
                var pick: RemotePathPick?
                if let direct, let transport = direct.transport {
                    pick = .direct(transport, detail: direct.detail)
                } else if case .success(let transport)? = relay {
                    pick = .relay(transport, directDetail: direct?.detail)
                } else if let direct, case .failure(let error)? = relay {
                    _ = direct
                    pick = .failed(error, directDetail: direct.detail)
                }
                guard let pick else { return (nil, nil) }
                self.continuation = nil
                return (continuation, pick)
            }
            if let taken, let pick { taken.resume(returning: pick) }
        }
    }
}
