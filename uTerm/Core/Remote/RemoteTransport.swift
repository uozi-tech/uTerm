import Foundation
@preconcurrency import Network

/// `RemoteTransport` 的状态变化，含义与 `NWConnection.State` 中用得到的那几个一致。
nonisolated enum RemoteTransportEvent: Sendable {
    case ready
    /// 还没连上就走不通（对端不在、网络不可达）。连上之后的这个事件可以忽略。
    case waiting(Error)
    case failed(Error)
    case cancelled
}

/// `RemoteLink` 脚下的字节流：可靠、有序，局域网、中继、打洞各一个实现。
///
/// 所有方法都在 `start(queue:onEvent:)` 传入的队列上调用，回调也都在这条队列上发出。
///
/// `send` 的完成回调表示这段数据**已经被链路接走**，不能在进缓冲时就回调：`RemoteLink.canSendMore` 与
/// 终端输出的快照兜底都靠它感知链路跟不上。没有对端确认的传输（打洞）要等对端确认才回调。
nonisolated protocol RemoteTransport: AnyObject, Sendable {
    func start(queue: DispatchQueue, onEvent: @escaping @Sendable (RemoteTransportEvent) -> Void)
    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    /// 收下一段数据。`isComplete` = 对端已经发完，之后不会再有数据。
    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, _ isComplete: Bool, Error?) -> Void)
    /// 立刻关闭，丢弃还没发完的数据。之后不再发出事件。
    func cancel()
}

/// 局域网路径：一条 `NWConnection`。
nonisolated final class RemoteNWTransport: RemoteTransport, @unchecked Sendable {
    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(queue: DispatchQueue, onEvent: @escaping @Sendable (RemoteTransportEvent) -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: onEvent(.ready)
            case .waiting(let error): onEvent(.waiting(error))
            case .failed(let error): onEvent(.failed(error))
            case .cancelled: onEvent(.cancelled)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { completion($0) })
    }

    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, _ isComplete: Bool, Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}
