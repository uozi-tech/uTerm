import Foundation
@testable import uTerm

/// 进程内的一对字节流，用来验证 `RemoteLink` 不依赖 `NWConnection`。
///
/// `holdsSendCompletions = true` 时数据照常送达，但发送完成回调要等 `releaseSendCompletions()` 才发出，
/// 模拟「对端确认慢」的链路。
nonisolated final class RemoteMemoryTransport: RemoteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private weak var peer: RemoteMemoryTransport?
    private var queue: DispatchQueue?
    private var onEvent: (@Sendable (RemoteTransportEvent) -> Void)?
    private var pending = Data()
    private var peerFinished = false
    private var receiver: (@Sendable (Data?, Bool, Error?) -> Void)?
    private var receiverLimit = 0
    private var heldCompletions: [@Sendable (Error?) -> Void] = []
    private var cancelled = false
    private var holds = false

    var holdsSendCompletions: Bool {
        get { lock.lock(); defer { lock.unlock() }; return holds }
        set { lock.lock(); holds = newValue; lock.unlock() }
    }

    static func pair() -> (RemoteMemoryTransport, RemoteMemoryTransport) {
        let first = RemoteMemoryTransport(), second = RemoteMemoryTransport()
        first.peer = second
        second.peer = first
        return (first, second)
    }

    func start(queue: DispatchQueue, onEvent: @escaping @Sendable (RemoteTransportEvent) -> Void) {
        lock.lock()
        self.queue = queue
        self.onEvent = onEvent
        lock.unlock()
        queue.async { onEvent(.ready) }
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        peer?.deliver(data)
        lock.lock()
        let held = holds
        if held { heldCompletions.append(completion) }
        let queue = self.queue
        lock.unlock()
        if !held { queue?.async { completion(nil) } }
    }

    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        lock.lock()
        receiver = completion
        receiverLimit = maximumLength
        lock.unlock()
        flush()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        onEvent = nil
        lock.unlock()
        peer?.finish()
    }

    func releaseSendCompletions() {
        lock.lock()
        let completions = heldCompletions
        heldCompletions = []
        let queue = self.queue
        lock.unlock()
        queue?.async { for completion in completions { completion(nil) } }
    }

    private func deliver(_ data: Data) {
        lock.lock()
        pending.append(data)
        lock.unlock()
        flush()
    }

    private func finish() {
        lock.lock()
        peerFinished = true
        lock.unlock()
        flush()
    }

    private func flush() {
        lock.lock()
        guard !cancelled, let receiver, let queue, !pending.isEmpty || peerFinished else {
            lock.unlock()
            return
        }
        let chunk = pending.isEmpty ? nil : Data(pending.prefix(receiverLimit))
        if let chunk { pending.removeFirst(chunk.count) }
        let isComplete = peerFinished && pending.isEmpty
        self.receiver = nil
        lock.unlock()
        queue.async { receiver(chunk, isComplete, nil) }
    }
}
