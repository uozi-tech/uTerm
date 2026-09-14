import Foundation
@preconcurrency import Network

enum LANSyncTransportError: LocalizedError {
    case connectionFailed(String)
    case messageTooLarge
    case invalidMessage

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message): return "局域网连接失败：\(message)"
        case .messageTooLarge: return "局域网同步消息超过大小限制"
        case .invalidMessage: return "局域网同步消息格式无效"
        }
    }
}

/// Network.framework 的连接回调在私有串行队列上运行；该对象只在该队列上修改缓冲区。
nonisolated final class LANSyncLineReader: @unchecked Sendable {
    private var buffer = Data()

    nonisolated func receive(
        from connection: NWConnection,
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: LANSyncConstants.maxMessageBytes) {
            [weak self] data, _, isComplete, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let data {
                self?.buffer.append(data)
                if self?.buffer.count ?? 0 > LANSyncConstants.maxMessageBytes {
                    completion(.failure(LANSyncTransportError.messageTooLarge))
                    return
                }
            }

            guard let self else {
                completion(.failure(LANSyncTransportError.connectionFailed("连接已释放")))
                return
            }
            if let newline = self.buffer.firstIndex(of: 0x0A) {
                let message = self.buffer[..<newline]
                completion(.success(Data(message)))
            } else if isComplete {
                completion(.failure(LANSyncTransportError.invalidMessage))
            } else {
                self.receive(from: connection, completion: completion)
            }
        }
    }
}

enum LANSyncTransport {
    static func send(
        _ data: Data,
        on connection: NWConnection,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        var framed = data
        framed.append(0x0A)
        connection.send(content: framed, completion: .contentProcessed { error in
            completion(error)
        })
    }
}
