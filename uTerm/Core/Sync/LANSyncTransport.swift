import Foundation
import UDesignKit
@preconcurrency import Network

enum LANSyncTransportError: LocalizedError {
    case connectionFailed(String)
    case frameTooLarge(Int)
    case transferTooLarge
    case invalidMessage
    case protocolMismatch
    case handshakeRequired
    case authenticationFailed
    case rejected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return "局域网连接失败：\(message)"
        case .frameTooLarge(let bytes):
            return "局域网同步收到超大数据帧（\(UFormat.bytes(bytes))），已中止"
        case .transferTooLarge:
            return "局域网同步数据量超出上限，已中止"
        case .invalidMessage:
            return "局域网同步消息格式无效"
        case .protocolMismatch:
            return "局域网同步协议版本不兼容"
        case .handshakeRequired:
            return "局域网同步安全握手未完成"
        case .authenticationFailed:
            return "局域网同步配对码不正确或认证失败"
        case .rejected:
            return "iPhone 或 iPad 拒绝了本次同步"
        }
    }
}

/// 长度前缀分帧的读取器。
///
/// 早先用换行分帧，靠的是「JSON 编码里不会出现裸 0x0A」这个隐含前提 —— 能用，但它把
/// 分帧的正确性绑在了负载编码的细节上，换个编码器或加个字段就可能踩空。改成显式的
/// 4 字节大端长度前缀：帧边界自己说了算，与负载内容无关。
///
/// 一个连接上可以按顺序读多帧（响应 = header + N 个数据分片），所以读取器是有状态的：
/// 跨帧的剩余字节留在 `buffer` 里，下一次 `readFrame` 直接接着用。
///
/// Network.framework 的回调在私有串行队列上跑，该对象只在该队列上改缓冲区。
/// 长度前缀分帧的**纯字节**缓冲区。
///
/// 和 `NWConnection` 分开，是因为分帧的正确性（半包、粘包、非法长度、总量上限）
/// 值得单独测，而不是只能靠真开一条 TCP 连接去撞。
nonisolated struct LANSyncFrameBuffer {
    private var buffer = Data()
    private var totalBytes = 0

    init() {}

    /// 追加一段刚收到的字节。超过一次传输的总量上限即抛错。
    mutating func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        totalBytes += data.count
        guard totalBytes <= LANSyncConstants.maxTotalBytes else {
            throw LANSyncTransportError.transferTooLarge
        }
        buffer.append(data)
    }

    /// 切出下一个完整帧；不足一帧返回 nil（继续收），长度前缀非法则抛错（别再往下读）。
    mutating func nextFrame() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= LANSyncConstants.maxFrameBytes else {
            throw LANSyncTransportError.frameTooLarge(length)
        }
        guard buffer.count >= 4 + length else { return nil }
        let start = buffer.startIndex + 4
        let payload = Data(buffer[start..<(start + length)])
        buffer.removeFirst(4 + length)
        return payload
    }
}

/// 把 `LANSyncFrameBuffer` 接到 `NWConnection` 上。
///
/// 一个连接上要按顺序读多帧（响应 = header + N 个数据分片），所以读取器是有状态的：
/// 跨帧的剩余字节留在缓冲区里，下一次 `readFrame` 直接接着用。
///
/// Network.framework 的回调在私有串行队列上跑，该对象只在该队列上改缓冲区。
nonisolated final class LANSyncFrameReader: @unchecked Sendable {
    private var buffer = LANSyncFrameBuffer()

    /// 读下一帧。缓冲区里已经有完整帧时直接回调，不再等新数据。
    nonisolated func readFrame(
        from connection: NWConnection,
        completion: @escaping @Sendable (Result<Data, Error>) -> Void
    ) {
        do {
            if let frame = try buffer.nextFrame() {
                completion(.success(frame))
                return
            }
        } catch {
            completion(.failure(error))
            return
        }
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: LANSyncConstants.maxFrameBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                completion(.failure(LANSyncTransportError.connectionFailed("连接已释放")))
                return
            }
            if let error {
                completion(.failure(error))
                return
            }
            do {
                if let data { try self.buffer.append(data) }
                if let frame = try self.buffer.nextFrame() {
                    completion(.success(frame))
                } else if isComplete {
                    completion(.failure(LANSyncTransportError.invalidMessage))
                } else {
                    self.readFrame(from: connection, completion: completion)
                }
            } catch {
                completion(.failure(error))
            }
        }
    }
}

/// `nonisolated`：分帧是纯字节操作，且 `sendAll` 要在 Network 的回调线程里自递归。
nonisolated enum LANSyncTransport {
    /// 给一段负载加上 4 字节大端长度前缀。纯函数，便于单测。
    static func frame(_ data: Data) throws -> Data {
        guard data.count <= LANSyncConstants.maxFrameBytes else {
            throw LANSyncTransportError.frameTooLarge(data.count)
        }
        var framed = Data(capacity: 4 + data.count)
        let length = UInt32(data.count)
        framed.append(UInt8((length >> 24) & 0xFF))
        framed.append(UInt8((length >> 16) & 0xFF))
        framed.append(UInt8((length >> 8) & 0xFF))
        framed.append(UInt8(length & 0xFF))
        framed.append(data)
        return framed
    }

    /// 发一帧。
    static func send(
        _ data: Data,
        on connection: NWConnection,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        let framed: Data
        do {
            framed = try frame(data)
        } catch {
            completion(error)
            return
        }
        connection.send(content: framed, completion: .contentProcessed { error in
            completion(error)
        })
    }

    /// 按顺序发多帧：任一帧失败即中止，错误交给 completion。
    static func sendAll(
        _ frames: [Data],
        on connection: NWConnection,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard let first = frames.first else {
            completion(nil)
            return
        }
        send(first, on: connection) { error in
            if let error {
                completion(error)
                return
            }
            sendAll(Array(frames.dropFirst()), on: connection, completion: completion)
        }
    }
}
