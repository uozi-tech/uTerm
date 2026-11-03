import CryptoKit
import Foundation
@preconcurrency import Network

/// 一条远控连接：分帧、握手、逐帧加解密。两端共用：手机发起（initiator），Mac 接受（responder）。
///
/// 所有状态只在 `queue` 上读写，回调也都在 `queue` 上发出，要不要跳回主线程由接收方决定。
/// Mac 端的输出合并直接跑在这条队列上（见 `RemoteHostConnection`），省掉一次线程切换。
nonisolated final class RemoteLink: @unchecked Sendable {
    struct Established: Sendable {
        let peer: RemoteHello
        let verificationCode: String
    }

    let queue: DispatchQueue
    private let connection: NWConnection

    private var frames = RemoteFrameBuffer()
    private var sendCipher: RemoteCipher?
    private var receiveCipher: RemoteCipher?
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var helloWaiter: CheckedContinuation<Data, Error>?
    private var isReady = false
    private var isEstablished = false
    private var isClosed = false
    private var closeError: Error?
    private var onMessage: (@Sendable (RemoteMessage) -> Void)?
    private var onClose: (@Sendable (Error?) -> Void)?
    private var onWritable: (@Sendable () -> Void)?

    /// 已交给网络栈、还没发完的字节数（只在 `queue` 上读）。
    private(set) var inflightBytes = 0

    /// 终端流量很小又讲究回显延迟：关 Nagle（`noDelay`），开 keepalive 及早发现对端消失。
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8
        return NWParameters(tls: nil, tcp: tcp)
    }

    init(connection: NWConnection, label: String = "com.uozi.uTerm.remote.link") {
        self.connection = connection
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    /// 回调都在 `queue` 上执行。必须在 `establish` 之前设好。
    func setHandlers(
        onMessage: @escaping @Sendable (RemoteMessage) -> Void,
        onClose: @escaping @Sendable (Error?) -> Void,
        onWritable: (@Sendable () -> Void)? = nil
    ) {
        queue.sync {
            self.onMessage = onMessage
            self.onClose = onClose
            self.onWritable = onWritable
        }
    }

    // MARK: - 握手

    /// 建立连接并完成握手。超时、版本不符、对端公钥无效都抛错，连接随之关闭。
    func establish(
        role: RemoteKeySchedule.Role,
        hello: RemoteHello,
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        ephemeralKey: Curve25519.KeyAgreement.PrivateKey
    ) async throws -> Established {
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(RemoteConstants.handshakeTimeout.components.seconds * 1000))) {
            [weak self] in
            guard let self, !self.isEstablished else { return }
            self.fail(RemoteProtocolError.timeout)
        }
        do {
            try await start()
            let helloBytes = try JSONEncoder().encode(hello)
            let remoteBytes: Data
            switch role {
            case .initiator:
                try sendPlain(helloBytes)
                remoteBytes = try await nextPlainFrame()
            case .responder:
                remoteBytes = try await nextPlainFrame()
                try sendPlain(helloBytes)
            }
            guard let remote = try? JSONDecoder().decode(RemoteHello.self, from: remoteBytes) else {
                throw RemoteProtocolError.handshakeFailed("对端握手消息无效")
            }
            guard remote.version == RemoteConstants.protocolVersion else {
                throw RemoteProtocolError.versionMismatch(remote.version)
            }
            let transcript = role == .initiator ? helloBytes + remoteBytes : remoteBytes + helloBytes
            let keys = try RemoteKeySchedule.derive(role: role, localStatic: staticKey, localEphemeral: ephemeralKey,
                                                    remoteHello: remote, transcript: transcript)
            try queue.sync {
                if let closeError = self.closeError ?? (self.isClosed ? RemoteProtocolError.closed : nil) {
                    throw closeError
                }
                self.sendCipher = RemoteCipher(key: keys.send)
                self.receiveCipher = RemoteCipher(key: keys.receive)
                self.isEstablished = true
                // 对端可能在我们装好密钥之前就发来了第一帧密文，它们还躺在缓冲里。
                self.processFrames()
            }
            return Established(peer: remote, verificationCode: keys.verificationCode)
        } catch {
            close(error)
            throw error
        }
    }

    private func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if self.isClosed {
                    continuation.resume(throwing: self.closeError ?? RemoteProtocolError.closed)
                    return
                }
                self.readyWaiter = continuation
                self.connection.stateUpdateHandler = { [weak self] state in
                    self?.handleState(state)
                }
                self.connection.start(queue: self.queue)
            }
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !isReady else { return }
            isReady = true
            readyWaiter?.resume()
            readyWaiter = nil
            receiveNext()
        case .failed(let error):
            fail(error)
        case .waiting(let error):
            // 没有建立过的连接卡在 waiting（对端不在、网络不可达）就别傻等到超时。
            if !isReady { fail(error) }
        case .cancelled:
            fail(closeError)
        default:
            break
        }
    }

    private func nextPlainFrame() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async {
                if self.isClosed {
                    continuation.resume(throwing: self.closeError ?? RemoteProtocolError.closed)
                    return
                }
                self.helloWaiter = continuation
                self.processFrames()
            }
        }
    }

    private func sendPlain(_ data: Data) throws {
        let framed = try RemoteFrameBuffer.frame(data)
        queue.async { [self] in
            self.connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                if let error { self?.fail(error) }
            })
        }
    }

    // MARK: - 收发

    /// 发一条消息（任意线程可调，按调用顺序发出）。
    func send(_ message: RemoteMessage) {
        queue.async { self.sendOnQueue(message) }
    }

    /// 在 `queue` 上直接发，不再跳一次队列。
    func sendOnQueue(_ message: RemoteMessage) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed, sendCipher != nil else { return }
        let framed: Data
        do {
            framed = try RemoteFrameBuffer.frame(try sendCipher!.seal(message.encoded()))
        } catch {
            fail(error)
            return
        }
        let count = framed.count
        inflightBytes += count
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            let wasBlocked = self.inflightBytes > RemoteConstants.maxInflightBytes
            self.inflightBytes -= count
            if let error {
                self.fail(error)
            } else if wasBlocked && self.inflightBytes <= RemoteConstants.maxInflightBytes {
                self.onWritable?()
            }
        })
    }

    var canSendMore: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return inflightBytes <= RemoteConstants.maxInflightBytes
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data { self.frames.append(data) }
            self.processFrames()
            if let error {
                self.fail(error)
            } else if isComplete {
                self.fail(RemoteProtocolError.closed)
            } else if !self.isClosed {
                self.receiveNext()
            }
        }
    }

    /// 从缓冲里取帧：握手阶段交给等待握手的一方，之后解密成消息交给 `onMessage`。
    private func processFrames() {
        while !isClosed {
            let frame: Data
            do {
                // 握手还没完成、也没人在等明文帧：先留在缓冲里，等密钥装好再处理。
                if receiveCipher == nil && helloWaiter == nil { return }
                guard let next = try frames.nextFrame() else { return }
                frame = next
            } catch {
                fail(error)
                return
            }
            if let waiter = helloWaiter {
                helloWaiter = nil
                waiter.resume(returning: frame)
                continue
            }
            do {
                let message = try RemoteMessage(decoding: try receiveCipher!.open(frame))
                onMessage?(message)
            } catch {
                fail(error)
                return
            }
        }
    }

    // MARK: - 关闭

    /// 主动关闭。`error` 为 nil 表示正常断开。还没发出去的数据会被丢弃。
    func close(_ error: Error? = nil) {
        queue.async { self.fail(error) }
    }

    /// 发完最后一条消息再关（告诉对端为什么断开）。`cancel()` 会丢掉网络栈里没发完的数据，
    /// 所以等这一帧真正交出去之后再关。
    func send(_ message: RemoteMessage, thenClose error: Error?) {
        queue.async {
            guard !self.isClosed, self.sendCipher != nil,
                  let sealed = try? self.sendCipher!.seal(message.encoded()),
                  let framed = try? RemoteFrameBuffer.frame(sealed) else {
                self.fail(error)
                return
            }
            self.connection.send(content: framed, completion: .contentProcessed { _ in
                self.fail(error)
            })
        }
    }

    private func fail(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        closeError = error
        readyWaiter?.resume(throwing: error ?? RemoteProtocolError.closed)
        readyWaiter = nil
        helloWaiter?.resume(throwing: error ?? RemoteProtocolError.closed)
        helloWaiter = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let handler = onClose
        onMessage = nil
        onClose = nil
        onWritable = nil
        handler?(error)
    }
}
