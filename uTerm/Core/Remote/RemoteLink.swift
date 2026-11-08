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
    private let transport: any RemoteTransport

    private var frames = RemoteFrameBuffer()
    private var sendCipher: RemoteCipher?
    private var receiveCipher: RemoteCipher?
    /// 公网路径上包住握手帧的密钥（见 `RemoteHandshakeKeys`）。局域网为 nil，握手帧是明文。
    private var handshakeSendCipher: RemoteCipher?
    private var handshakeReceiveCipher: RemoteCipher?
    private var pingSentAt: DispatchTime?
    /// 最近一次 ping 的往返时间（秒，只在 `queue` 上读）。
    private(set) var latestRoundTrip: TimeInterval?
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var helloWaiter: CheckedContinuation<Data, Error>?
    private var isReady = false
    private var isEstablished = false
    private var isClosed = false
    private var closeError: Error?
    private var onMessage: (@Sendable (RemoteMessage) -> Void)?
    private var onClose: (@Sendable (Error?) -> Void)?
    private var onWritable: (@Sendable () -> Void)?

    /// 已交给网络栈、还没发完的字节数（只在 `queue` 上读）。启用了链路排队时也算上排着的。
    private(set) var inflightBytes = 0

    /// 链路层排队与端到端计量（两端都声明 `link-flow` 才有，见 `RemoteLinkFlow`）。nil = 消息直接交给网络栈。
    private var flow: RemoteLinkFlow?
    /// 排着的消息交出去之后要回调的完成，以及它计入 `inflightBytes` 的字节数。
    private var flowCompletions: [Int: (count: Int, completion: (@Sendable (Error?) -> Void)?)] = [:]
    private var nextFlowToken = 0
    /// 收方的 `linkAck` 已经约好了。
    private var ackScheduled = false

    /// 启用了链路排队（诊断和测试用，只在 `queue` 上读）。
    var usesLinkFlow: Bool { flow != nil }
    /// 链路排队的读数（诊断和测试用，只在 `queue` 上读）。
    var linkFlowState: (inPipe: Int, budget: Int, queued: Int, rate: Double?, roundTripNanos: UInt64?)? {
        guard let flow else { return nil }
        return (flow.inPipe, flow.budget, flow.queuedBytes, flow.deliveryRate, flow.minimumRoundTripNanos)
    }

    // 存活判定（只在 `queue` 上读写）。
    private var lastReceived = DispatchTime.now()
    private var lastSent = DispatchTime.now()
    /// 上次发 ping 的时刻（只在 `queue` 上读写）；还没发过是 0，心跳第一拍就会问一声，连上就有往返读数。
    private var lastPingSent = DispatchTime(uptimeNanoseconds: 0)
    private var livenessTimer: DispatchSourceTimer?

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

    init(transport: any RemoteTransport, label: String = "com.uozi.uTerm.remote.link") {
        self.transport = transport
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    convenience init(connection: NWConnection, label: String = "com.uozi.uTerm.remote.link") {
        self.init(transport: RemoteNWTransport(connection: connection), label: label)
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
        ephemeralKey: Curve25519.KeyAgreement.PrivateKey,
        handshakeKeys: RemoteHandshakeKeys? = nil
    ) async throws -> Established {
        if let handshakeKeys {
            queue.sync {
                handshakeSendCipher = RemoteCipher(key: handshakeKeys.send)
                handshakeReceiveCipher = RemoteCipher(key: handshakeKeys.receive)
            }
        }
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
                // 两端从第一条密文起各自计数，口径一致（见 `RemoteLinkFlow`）。
                if hello.supports(RemoteFeature.linkFlow) && remote.supports(RemoteFeature.linkFlow) {
                    self.flow = RemoteLinkFlow()
                }
                (self.transport as? RemoteP2PTransport)?.installMediaKeys(
                    .media(sessionSend: keys.send, sessionReceive: keys.receive))
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
                self.transport.start(queue: self.queue) { [weak self] event in
                    self?.handleEvent(event)
                }
            }
        }
    }

    private func handleEvent(_ event: RemoteTransportEvent) {
        switch event {
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

    private func openHandshakeFrame(_ frame: Data) throws -> Data {
        guard handshakeReceiveCipher != nil else { return frame }
        return try handshakeReceiveCipher!.open(frame)
    }

    private func sendPlain(_ data: Data) throws {
        queue.async { [self] in
            do {
                let content = self.handshakeSendCipher != nil ? try self.handshakeSendCipher!.seal(data) : data
                let framed = try RemoteFrameBuffer.frame(content)
                self.transport.send(framed) { [weak self] error in
                    if let error { self?.fail(error) }
                }
            } catch {
                self.fail(error)
            }
        }
    }

    // MARK: - 收发

    /// 发一条消息（任意线程可调，按调用顺序发出）。
    func send(_ message: RemoteMessage) {
        queue.async { self.sendOnQueue(message) }
    }

    /// 在 `queue` 上直接发，不再跳一次队列。
    /// - Parameters:
    ///   - countsTowardBackpressure: 计入 `canSendMore` 的在途量吗。视频有自己的流控，不计：一个关键帧就有几百 KB，
    ///     算进来的话终端会以为链路堵了，改发快照。
    ///   - completion: 链路接走这段数据后在 `queue` 上调用。
    func sendOnQueue(_ message: RemoteMessage, countsTowardBackpressure: Bool = true,
                     completion: (@Sendable (Error?) -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed, sendCipher != nil else {
            completion?(RemoteProtocolError.closed)
            return
        }
        if message.kind == .ping {
            let now = DispatchTime.now()
            pingSentAt = now
            lastPingSent = now
        }
        if flow != nil {
            enqueueOnFlow(message, countsTowardBackpressure: countsTowardBackpressure, completion: completion)
            return
        }
        let framed: Data
        do {
            framed = try RemoteFrameBuffer.frame(try sendCipher!.seal(message.encoded()))
        } catch {
            fail(error)
            return
        }
        let count = countsTowardBackpressure ? framed.count : 0
        lastSent = .now()
        inflightBytes += count
        transport.send(framed) { [weak self] error in
            defer { completion?(error) }
            guard let self else { return }
            let wasBlocked = self.inflightBytes > RemoteConstants.maxInflightBytes
            self.inflightBytes -= count
            if let error {
                self.fail(error)
            } else if wasBlocked && self.inflightBytes <= RemoteConstants.maxInflightBytes {
                self.onWritable?()
            }
        }
    }

    // MARK: - 链路排队（`link-flow`）

    private func enqueueOnFlow(_ message: RemoteMessage, countsTowardBackpressure: Bool,
                               completion: (@Sendable (Error?) -> Void)?) {
        // 整条消息封装后放不进一帧的，和不分片时一样在发方就失败：分了片对端拼回来照样超限，只是改由对端断开。
        let sealed = RemoteMessage.headerSize + message.payload.count + 16
        guard sealed <= RemoteConstants.maxFrameBytes else {
            completion?(RemoteProtocolError.frameTooLarge(sealed))
            fail(RemoteProtocolError.frameTooLarge(sealed))
            return
        }
        // 计入背压的口径与直接发时一致：封装后的帧长（长度前缀 4 + 密文，密文比明文多 16 字节的校验）。
        let count = countsTowardBackpressure ? sealed + 4 : 0
        let token = nextFlowToken
        nextFlowToken &+= 1
        flowCompletions[token] = (count, completion)
        inflightBytes += count
        flow!.enqueue(message, token: token)
        drainFlow()
    }

    /// 把闸门放行的记录交给网络栈。对端每次报来收到多少、或有新消息排进来时调用。
    private func drainFlow() {
        while !isClosed, let record = flow?.next() {
            let framed: Data
            do {
                framed = try RemoteFrameBuffer.frame(try sendCipher!.seal(record.message.encoded()))
            } catch {
                fail(error)
                return
            }
            flow?.recordSent(bytes: framed.count, now: DispatchTime.now().uptimeNanoseconds)
            lastSent = .now()
            let token = record.token
            transport.send(framed) { [weak self] error in
                guard let self else { return }
                if let token { self.finishFlowMessage(token, error) }
                if let error { self.fail(error) }
            }
        }
    }

    private func finishFlowMessage(_ token: Int, _ error: Error?) {
        guard let entry = flowCompletions.removeValue(forKey: token) else { return }
        let wasBlocked = inflightBytes > RemoteConstants.maxInflightBytes
        inflightBytes -= entry.count
        entry.completion?(error)
        if error == nil, wasBlocked, inflightBytes <= RemoteConstants.maxInflightBytes { onWritable?() }
    }

    /// 收方：回一个 `linkAck`。不排队、不计数（双方都不计它，免得为确认而确认）。
    private func sendLinkAck() {
        guard !isClosed, let total = flow?.takeAck() else { return }
        guard let sealed = try? sendCipher?.seal(RemoteMessage(.linkAck, payload: RemoteLinkAck.encode(total)).encoded()),
              let framed = try? RemoteFrameBuffer.frame(sealed) else { return }
        transport.send(framed) { [weak self] error in
            if let error { self?.fail(error) }
        }
    }

    /// 收方：一条记录到了，按需回 `linkAck`。
    private func noteReceived(frameBytes: Int) {
        guard let decision = flow?.recordReceived(bytes: frameBytes + 4, now: DispatchTime.now().uptimeNanoseconds) else {
            return
        }
        switch decision {
        case .none:
            break
        case .now:
            sendLinkAck()
        case .at(let due):
            guard !ackScheduled else { return }
            ackScheduled = true
            queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: due)) { [weak self] in
                guard let self else { return }
                self.ackScheduled = false
                self.sendLinkAck()
            }
        }
    }

    /// 公网直连时视频走的不可靠通道。其余路径为 nil，视频还是普通消息。
    var videoChannel: (any RemoteVideoDatagramChannel)? {
        transport as? any RemoteVideoDatagramChannel
    }

    /// 链路现状（公网直连才有）。诊断和测试用。
    var datagramLinkState: RemoteLinkState? {
        (transport as? RemoteP2PTransport)?.linkState
    }

    var canSendMore: Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return inflightBytes <= RemoteConstants.maxInflightBytes
    }

    private func receiveNext() {
        transport.receive(maximumLength: 512 * 1024) { [weak self] data, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data {
                self.lastReceived = .now()
                self.frames.append(data)
            }
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
                do {
                    waiter.resume(returning: try openHandshakeFrame(frame))
                } catch {
                    waiter.resume(throwing: error)
                }
                continue
            }
            do {
                var message = try RemoteMessage(decoding: try receiveCipher!.open(frame))
                if flow != nil {
                    if message.kind == .linkAck {
                        flow?.receiveAck(try RemoteLinkAck.decode(message.payload), now: DispatchTime.now().uptimeNanoseconds)
                        drainFlow()
                        continue
                    }
                    noteReceived(frameBytes: frame.count)
                    if message.kind == .linkFragment {
                        guard let whole = try flow?.reassemble(message.payload) else { continue }
                        message = whole
                    }
                }
                if message.kind == .pong, let pingSentAt {
                    let now = DispatchTime.now().uptimeNanoseconds
                    latestRoundTrip = TimeInterval(now &- pingSentAt.uptimeNanoseconds) / 1_000_000_000
                    self.pingSentAt = nil
                }
                onMessage?(message)
            } catch {
                fail(error)
                return
            }
        }
    }

    // MARK: - 存活判定

    /// 手机这一端：链路安静时发 ping，太久没收到任何字节就判死。握手和配对都结束后才开始（等 Mac 上的人点
    /// 「允许」期间 Mac 不回 ping）。
    func startHeartbeat(_ heartbeat: RemoteHeartbeat) {
        startLivenessTimer(every: heartbeat.pingInterval / 3) { link, quiet, silent, wasSuspended in
            if wasSuspended {
                // App 刚从挂起回来：这段时间收不到东西不算链路死了。重新计时，并马上问一声。
                link.lastReceived = .now()
                link.sendOnQueue(RemoteMessage(.ping))
                return
            }
            if quiet > heartbeat.replyLimit {
                link.fail(RemoteProtocolError.timeout)
            } else if quiet > heartbeat.pingInterval || silent > heartbeat.pingInterval
                        || link.secondsSinceLastPing > heartbeat.roundTripRefresh {
                link.sendOnQueue(RemoteMessage(.ping))
            }
        }
    }

    private var secondsSinceLastPing: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds &- lastPingSent.uptimeNanoseconds) / 1_000_000_000
    }

    /// Mac 这一端：只判死，不主动发。
    func startSilenceWatch(limit: TimeInterval) {
        startLivenessTimer(every: limit / 3) { link, quiet, _, _ in
            if quiet > limit { link.fail(RemoteProtocolError.timeout) }
        }
    }

    /// 网络刚变化或刚回到前台：发一个 ping，`replyLimit` 秒内收到任何字节都算活着，否则判死。
    func probe(replyLimit: TimeInterval) {
        queue.async { [self] in
            guard !self.isClosed else { return }
            let asked = DispatchTime.now()
            self.sendOnQueue(RemoteMessage(.ping))
            self.queue.asyncAfter(deadline: asked + replyLimit) { [weak self] in
                guard let self, !self.isClosed, self.lastReceived < asked else { return }
                self.fail(RemoteProtocolError.timeout)
            }
        }
    }

    private func startLivenessTimer(
        every interval: TimeInterval,
        _ tick: @escaping @Sendable (_ link: RemoteLink, _ quiet: TimeInterval, _ silent: TimeInterval,
                                     _ wasSuspended: Bool) -> Void
    ) {
        queue.async { [self] in
            guard !self.isClosed, self.livenessTimer == nil else { return }
            self.lastReceived = .now()
            self.lastSent = .now()
            var lastTick = DispatchTime.now()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            // 给定时器 10% 的余量：不带余量时系统只能按精确时刻单独唤醒 CPU，带了才能和别的定时器（网络栈、
            // 其他连接的心跳）并成一次唤醒。手机这端约 1.7 秒一拍，余量约 0.17 秒，相对 5 秒发 ping、20 秒判死的
            // 门限可以忽略；「挂起过」的判定是隔了 3 拍以上，也远大于这点余量。
            timer.schedule(deadline: .now() + interval, repeating: interval,
                           leeway: .milliseconds(max(1, Int(interval * 100))))
            timer.setEventHandler { [weak self] in
                guard let self, !self.isClosed else { return }
                let now = DispatchTime.now()
                let seconds: (DispatchTime) -> TimeInterval = {
                    TimeInterval(now.uptimeNanoseconds &- $0.uptimeNanoseconds) / 1_000_000_000
                }
                // 定时器隔了好几拍才来：进程被挂起过，不是对端没声音。
                let wasSuspended = seconds(lastTick) > interval * 3
                lastTick = now
                tick(self, seconds(self.lastReceived), seconds(self.lastSent), wasSuspended)
            }
            self.livenessTimer = timer
            timer.resume()
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
            if self.flow != nil, !self.isClosed, self.sendCipher != nil {
                // 排在已经排着的消息后面（同一通道保序），交出去再关；对端一直不收也最多等 2 s。
                self.sendOnQueue(message) { _ in self.fail(error) }
                self.queue.asyncAfter(deadline: .now() + 2) { self.fail(error) }
                return
            }
            guard !self.isClosed, self.sendCipher != nil,
                  let sealed = try? self.sendCipher!.seal(message.encoded()),
                  let framed = try? RemoteFrameBuffer.frame(sealed) else {
                self.fail(error)
                return
            }
            self.transport.send(framed) { _ in
                self.fail(error)
            }
        }
    }

    private func fail(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        closeError = error
        livenessTimer?.cancel()
        livenessTimer = nil
        readyWaiter?.resume(throwing: error ?? RemoteProtocolError.closed)
        readyWaiter = nil
        helloWaiter?.resume(throwing: error ?? RemoteProtocolError.closed)
        helloWaiter = nil
        transport.cancel()
        let pending = flowCompletions.values.compactMap(\.completion)
        flowCompletions.removeAll()
        flow = nil
        for completion in pending { completion(error ?? RemoteProtocolError.closed) }
        let handler = onClose
        onMessage = nil
        onClose = nil
        onWritable = nil
        handler?(error)
    }
}
