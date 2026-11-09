import Foundation

/// 公网直连时桌面视频走的通道。只有 `RemoteP2PTransport` 实现：TCP 路径上视频还是普通消息。
nonisolated protocol RemoteVideoDatagramChannel: AnyObject, Sendable {
    /// Mac：开始发。回调都在 `callbackQueue` 上。`onExpired` = 这些编码序号过了时限还没人回话，按丢失处理。
    func startVideoSending(channel: UInt32, callbackQueue: DispatchQueue,
                           onLinkState: @escaping @Sendable (RemoteLinkState) -> Void,
                           onExpired: @escaping @Sendable ([UInt32]) -> Void)
    /// `kind` 决定接收端最多等这一帧多久，见 `RemoteLossPolicy.frameDeadlineMillis`。
    func sendVideo(_ payload: Data, sequence: UInt32, kind: RemoteLossPolicy.FrameKind)
    func acknowledgeVideo(sequence: UInt32)
    /// 手机说这些帧放弃了，把对应的编码序号回给 `completion`（在回调队列上）。
    func videoLost(_ videoSequences: [UInt32], completion: @escaping @Sendable ([UInt32]) -> Void)
    func setVideoFEC(groupSize: Int)
    func stopVideoSending()
    /// 手机：开始收。回调在同一条内部队列上，接收方自己切队列；保证按帧顺序。第二个参数是桌面流的通道号。
    func startVideoReceiving(onFrame: @escaping @Sendable (Data, UInt32) -> Void,
                             onLost: @escaping @Sendable ([UInt32], UInt32) -> Void)
    func stopVideoReceiving()
    /// Mac：发一包声音（`RemoteDesktopAudioFrame` 编码后的字节）。不重传。
    func sendAudio(_ payload: Data, channel: UInt32)
    /// 手机：开始收声音。回调在内部队列上；第二个参数是桌面通道号。
    func startAudioReceiving(onFrame: @escaping @Sendable (Data, UInt32) -> Void)
    func stopAudioReceiving()
}

/// 把一条数据报路径变成 `RemoteLink` 要的可靠字节流，并在旁边开一条不可靠的视频通道。
///
/// ```
/// 控制消息、终端字节 → KCP ─┐
/// 视频分片（可丢）──────────┼→ 发送节奏 → 逐包加密 → UDP
/// 接收报告 ────────────────┘
/// ```
///
/// 状态全在内部的 `queue` 上。外面的回调切到 `start` 传入的队列。没有东西要发也没有东西在等的时候，
/// 定时器停着：手机上常驻 10 ms 一拍的定时器很费电。
nonisolated final class RemoteP2PTransport: RemoteTransport, RemoteVideoDatagramChannel, @unchecked Sendable {
    /// 这个大小在几乎所有路径上都不会被 IP 分片。
    static let datagramBytes = 1200
    static let reportInterval: UInt64 = 50_000_000
    static let linkStateInterval: UInt64 = 200_000_000

    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.p2p", qos: .userInteractive)
    private let path: any RemoteDatagramPath
    private var cipher: RemoteDatagramCipher
    private var kcp: RemoteKCP?
    private var pacer: RemoteDatagramPacer
    private var estimator: RemoteLinkEstimator
    private var activityHandler: (@Sendable (TimeInterval?) -> Void)?
    private var lastActivityNotice: UInt64 = 0
    private static let activityNoticeInterval: UInt64 = 100_000_000
    private let timer: DispatchSourceTimer
    private var armedFor: UInt64 = .max

    private var callbackQueue: DispatchQueue?
    private var onEvent: (@Sendable (RemoteTransportEvent) -> Void)?
    private var isStopped = false
    private var failure: Error?
    private var peerFinished = false

    private var completions: [(last: UInt32, completion: @Sendable (Error?) -> Void)] = []
    private var readBuffer = Data()
    private var reader: (limit: Int, completion: @Sendable (Data?, Bool, Error?) -> Void)?

    // 接收报告（只在 queue 上）。
    private var receivedHighest: UInt64 = 0
    private var receivedPackets: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var latestSequence: UInt64 = 0
    private var latestArrival: UInt64 = 0
    private var reportDue: UInt64?

    // 视频发送。
    private var videoChannel: UInt32?
    private var videoBuffer = RemoteVideoSendBuffer()
    private var fecGroupSize = 0
    private var videoCallbackQueue: DispatchQueue?
    private var onLinkState: (@Sendable (RemoteLinkState) -> Void)?
    private var onExpired: (@Sendable ([UInt32]) -> Void)?
    private var lastLinkState: UInt64 = 0
    private var nextProbe: UInt64?

    // 视频接收。
    private var reassembler = RemoteVideoReassembler()
    private var onVideoFrame: (@Sendable (Data, UInt32) -> Void)?
    private var onVideoLost: (@Sendable ([UInt32], UInt32) -> Void)?
    // 声音接收。
    private var onAudioFrame: (@Sendable (Data, UInt32) -> Void)?

    init(path: any RemoteDatagramPath, keys: RemoteDatagramKeys) {
        self.path = path
        let now = DispatchTime.now().uptimeNanoseconds
        cipher = RemoteDatagramCipher(control: keys)
        pacer = RemoteDatagramPacer(rate: 1_000_000, now: now)
        estimator = RemoteLinkEstimator(now: now)
        timer = DispatchSource.makeTimerSource(queue: queue)
        pacer.rate = estimator.pacingRate
        timer.setEventHandler { [weak self] in self?.wake() }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
        queue.async { [self] in
            kcp = RemoteKCP(mtu: Self.datagramBytes - RemoteDatagramCipher.overhead) { [weak self] segment in
                self?.pacer.enqueue(.reliable, segment, priority: .control)
            }
            kcp?.update(nowMillis: Self.millis(now))
        }
        path.start(onDatagram: { [weak self] datagram in
            guard let self else { return }
            queue.async { [weak self] in self?.receive(datagram) }
        }, onFailure: { [weak self] error in
            guard let self else { return }
            queue.async { [weak self] in self?.fail(error ?? RemoteProtocolError.closed) }
        })
    }

    deinit {
        timer.setEventHandler {}
        timer.cancel()
        path.close()
    }

    /// 这条链路现在的样子（诊断和测试用）。
    var linkState: RemoteLinkState {
        queue.sync { estimator.state }
    }

    var videoCounters: RemoteVideoReassembler.Counters {
        queue.sync { reassembler.counters }
    }

    // MARK: - RemoteTransport

    func start(queue callbackQueue: DispatchQueue, onEvent: @escaping @Sendable (RemoteTransportEvent) -> Void) {
        self.queue.async { [self] in
            self.callbackQueue = callbackQueue
            self.onEvent = onEvent
            if let failure {
                callbackQueue.async { onEvent(.failed(failure)) }
            } else {
                // 走到这里路径已经打通了。
                callbackQueue.async { onEvent(.ready) }
            }
        }
    }

    func send(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            guard !isStopped, let kcp else {
                callbackQueue?.async { completion(RemoteProtocolError.closed) }
                return
            }
            if let failure {
                callbackQueue?.async { completion(failure) }
                return
            }
            guard !data.isEmpty else {
                callbackQueue?.async { completion(nil) }
                return
            }
            let segment = kcp.maximumSegment
            var offset = data.startIndex
            var last: UInt32 = 0
            while offset < data.endIndex {
                let end = min(data.endIndex, offset + segment)
                last = kcp.send(Data(data[offset..<end]))
                offset = end
            }
            completions.append((last, completion))
            // 先更新时钟：KCP 用它打时间戳算往返，空闲一阵之后不更新就全是错的。
            kcp.update(nowMillis: Self.millis(DispatchTime.now().uptimeNanoseconds))
            kcp.flush()
            pump()
            rearm()
        }
    }

    func receive(maximumLength: Int, completion: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        queue.async { [self] in
            reader = (maximumLength, completion)
            serveRead()
        }
    }

    func onAuthenticatedActivity(_ handler: @escaping @Sendable (TimeInterval?) -> Void) {
        queue.async { self.activityHandler = handler }
    }

    func cancel() {
        queue.async { [self] in
            activityHandler = nil
            guard !isStopped else { return }
            isStopped = true
            // 尽力告诉对端，省得它等超时。丢了也没事，对端有心跳。
            for _ in 0..<3 {
                if let datagram = cipher.seal(.close, Data()) { path.send(datagram) }
            }
            onEvent = nil
            reader = nil
            completions = []
            timer.schedule(deadline: .distantFuture)
            path.close()
        }
    }

    /// 视频密钥：`RemoteLink` 握手完成后装上。
    func installMediaKeys(_ keys: RemoteDatagramKeys) {
        queue.async { self.cipher.installMedia(keys) }
    }

    // MARK: - RemoteVideoDatagramChannel

    func startVideoSending(channel: UInt32, callbackQueue: DispatchQueue,
                           onLinkState: @escaping @Sendable (RemoteLinkState) -> Void,
                           onExpired: @escaping @Sendable ([UInt32]) -> Void) {
        queue.async { [self] in
            videoChannel = channel
            videoBuffer = RemoteVideoSendBuffer()
            videoCallbackQueue = callbackQueue
            self.onLinkState = onLinkState
            self.onExpired = onExpired
            let state = estimator.state
            callbackQueue.async { onLinkState(state) }
        }
    }

    func sendVideo(_ payload: Data, sequence: UInt32, kind: RemoteLossPolicy.FrameKind) {
        queue.async { [self] in
            guard !isStopped, let videoChannel else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let state = estimator.state
            let deadline = RemoteLossPolicy.frameDeadlineMillis(frameBytes: payload.count, roundTripNanos: state.roundTripNanos,
                                                                pacingRate: state.pacingRate, kind: kind)
            let packets = videoBuffer.add(payload: payload, sequence: sequence, channel: videoChannel,
                                          fecGroupSize: fecGroupSize, deadlineMillis: deadline,
                                          roundTripMillis: Int((state.roundTripNanos ?? 0) / 1_000_000), now: now)
            for packet in packets { pacer.enqueue(.media, packet, priority: .media) }
            frameEnds.append((pacer.mediaEnqueued, videoBuffer.newestVideoSequence))
            nextProbe = nextProbe ?? now &+ probeWait(state)
            pump()
            rearm()
        }
    }

    func acknowledgeVideo(sequence: UInt32) {
        queue.async { self.videoBuffer.acknowledge(sequence: sequence) }
    }

    func videoLost(_ videoSequences: [UInt32], completion: @escaping @Sendable ([UInt32]) -> Void) {
        queue.async { [self] in
            let sequences = videoBuffer.markLost(videoSequences: videoSequences)
            videoCallbackQueue?.async { completion(sequences) }
        }
    }

    func setVideoFEC(groupSize: Int) {
        queue.async { self.fecGroupSize = groupSize }
    }

    func stopVideoSending() {
        queue.async { [self] in
            videoChannel = nil
            videoBuffer = RemoteVideoSendBuffer()
            onLinkState = nil
            onExpired = nil
            nextProbe = nil
        }
    }

    func sendAudio(_ payload: Data, channel: UInt32) {
        queue.async { [self] in
            guard !isStopped else { return }
            var writer = RemoteByteWriter(capacity: 4 + payload.count)
            writer.u32(channel)
            writer.bytes(payload)
            pacer.enqueue(.audio, writer.data, priority: .audio)
            pump()
            rearm()
        }
    }

    func startAudioReceiving(onFrame: @escaping @Sendable (Data, UInt32) -> Void) {
        queue.async { self.onAudioFrame = onFrame }
    }

    func stopAudioReceiving() {
        queue.async { self.onAudioFrame = nil }
    }

    func startVideoReceiving(onFrame: @escaping @Sendable (Data, UInt32) -> Void,
                             onLost: @escaping @Sendable ([UInt32], UInt32) -> Void) {
        queue.async { [self] in
            onVideoFrame = onFrame
            onVideoLost = onLost
        }
    }

    func stopVideoReceiving() {
        queue.async { [self] in
            onVideoFrame = nil
            onVideoLost = nil
        }
    }

    // MARK: - 收

    private func receive(_ datagram: Data) {
        guard !isStopped, let opened = cipher.open(datagram) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        // 验过的才算对端还在；一秒最多报十次，存活判定的精度远粗于它。
        if let activityHandler, now &- lastActivityNotice >= Self.activityNoticeInterval {
            lastActivityNotice = now
            activityHandler(estimator.minimumRoundTripNanos.map { TimeInterval($0) / 1_000_000_000 })
        }
        receivedHighest = max(receivedHighest, opened.sequence)
        receivedPackets += 1
        receivedBytes += UInt64(datagram.count)
        latestSequence = opened.sequence
        latestArrival = now
        if opened.kind != .report, reportDue == nil { reportDue = now &+ Self.reportInterval }
        switch opened.kind {
        case .reliable:
            guard let kcp else { return }
            kcp.update(nowMillis: Self.millis(now))
            kcp.input(opened.payload)
            kcp.flush()
            drainKCP()
        case .report:
            guard let report = try? RemoteLinkReport(decoding: opened.payload) else { return }
            handle(report, now: now)
        case .close:
            peerFinished = true
            serveRead()
        case .media:
            guard onVideoFrame != nil else { return }
            handleVideoOutput(reassembler.receive(opened.payload, now: now))
        case .mediaNack:
            guard let nack = try? RemoteVideoNack(decoding: opened.payload), nack.channel == videoChannel else { return }
            // 重传排在新帧前面（这一帧不到，解码器就卡着）、声音后面（见 `RemoteDatagramPacer.Priority.retransmit`）。
            let resent = videoBuffer.packets(for: nack, now: now, firstTicket: pacer.retransmitEnqueued &+ 1,
                                             resendGapNanos: estimator.state.roundTripNanos ?? 0,
                                             departure: retransmitDeparture)
            for packet in resent { pacer.enqueue(.media, packet, priority: .retransmit) }
        case .audio:
            guard let onAudioFrame, opened.payload.count > 4 else { return }
            let channel = opened.payload.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
            onAudioFrame(Data(opened.payload.dropFirst(4)), channel)
        case .pathCheck:
            break
        }
        pump()
        rearm()
    }

    private func drainKCP() {
        guard let kcp else { return }
        while let message = kcp.receive() { readBuffer.append(message) }
        serveRead()
        let acknowledged = kcp.acknowledgedThrough
        var finished: [@Sendable (Error?) -> Void] = []
        while let first = completions.first, Int32(bitPattern: first.last &- acknowledged) < 0 {
            finished.append(first.completion)
            completions.removeFirst()
        }
        if !finished.isEmpty {
            let completed = finished
            callbackQueue?.async { for completion in completed { completion(nil) } }
        }
        if kcp.isDead { fail(RemoteProtocolError.timeout) }
    }

    private func serveRead() {
        guard let (limit, completion) = reader, let callbackQueue else { return }
        if !readBuffer.isEmpty {
            reader = nil
            let chunk = Data(readBuffer.prefix(limit))
            readBuffer.removeFirst(chunk.count)
            callbackQueue.async { completion(chunk, false, nil) }
        } else if let failure {
            reader = nil
            callbackQueue.async { completion(nil, false, failure) }
        } else if peerFinished {
            reader = nil
            callbackQueue.async { completion(nil, true, nil) }
        }
    }

    private func handle(_ report: RemoteLinkReport, now: UInt64) {
        if estimator.record(report, now: now) {
            pacer.rate = estimator.pacingRate
        }
        let state = estimator.state
        if let trip = state.roundTripNanos, let kcp {
            let window = state.pacingRate * Double(trip) / 1e9 * 2 / Double(kcp.maximumSegment)
            kcp.setWindow(segments: min(2048, max(32, Int(window))))
        }
        if let onLinkState, let videoCallbackQueue, now &- lastLinkState >= Self.linkStateInterval {
            lastLinkState = now
            videoCallbackQueue.async { onLinkState(state) }
        }
    }

    private func handleVideoOutput(_ output: RemoteVideoReassembler.Output) {
        for nack in output.nacks { pacer.enqueue(.mediaNack, nack.encoded(), priority: .control) }
        let channel = reassembler.currentChannel
        if !output.lost.isEmpty { onVideoLost?(output.lost, channel) }
        for frame in output.frames { onVideoFrame?(frame, channel) }
    }

    // MARK: - 发与定时

    /// 每帧最后一片在视频队列里的序号（`RemoteDatagramPacer.mediaEnqueued`），发出去后告诉发送缓冲开始探测计时。
    private var frameEnds: [(end: UInt64, videoSequence: UInt32)] = []
    /// 重传队列的发出记录：每次 `pump` 发出去的号截至 `upTo`、时刻 `at`。只留 5 秒，更早的当作早就发了。
    private var retransmitDepartures: [(upTo: UInt64, at: UInt64)] = []

    /// 重传队列里第 `ticket` 个离开的时刻；还排着为 nil。
    private func retransmitDeparture(_ ticket: UInt64) -> UInt64? {
        guard ticket <= pacer.retransmitSent else { return nil }
        return retransmitDepartures.first(where: { $0.upTo >= ticket })?.at ?? 0
    }

    private func pump() {
        let now = DispatchTime.now().uptimeNanoseconds
        while let (kind, payload) = pacer.next(now: now) {
            guard let datagram = cipher.seal(kind, payload) else { continue }
            estimator.recordSent(sequence: cipher.lastSequence, now: now)
            path.send(datagram)
        }
        if !pacer.isEmpty { estimator.noteBacklog() }
        if pacer.retransmitSent > (retransmitDepartures.last?.upTo ?? 0) {
            retransmitDepartures.append((pacer.retransmitSent, now))
            if let stale = retransmitDepartures.firstIndex(where: { now &- $0.at < 5_000_000_000 }), stale > 0 {
                retransmitDepartures.removeFirst(stale)
            }
        }
        while let first = frameEnds.first, first.end <= pacer.mediaSent {
            frameEnds.removeFirst()
            videoBuffer.markSent(videoSequence: first.videoSequence, now: now)
        }
    }

    private func probeWait(_ state: RemoteLinkState) -> UInt64 {
        let trip = state.roundTripNanos ?? 100_000_000
        return max(30_000_000, trip + trip / 4)
    }

    private func wake() {
        armedFor = .max
        guard !isStopped else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if let kcp, kcp.waitingSegments > 0 {
            kcp.update(nowMillis: Self.millis(now))
            drainKCP()
        }
        if let due = reportDue, now >= due {
            reportDue = nil
            let held = now &- latestArrival
            let report = RemoteLinkReport(highestSequence: receivedHighest, packets: receivedPackets, bytes: receivedBytes,
                                          echoSequence: latestSequence,
                                          echoHeldMicros: UInt32(clamping: held / 1000))
            pacer.enqueue(.report, report.encoded(), priority: .control)
        }
        if onVideoFrame != nil, reassembler.hasWork {
            handleVideoOutput(reassembler.tick(now: now))
        }
        if videoChannel != nil, let due = nextProbe, now >= due {
            let state = estimator.state
            for packet in videoBuffer.probes(now: now, roundTripNanos: state.roundTripNanos ?? 100_000_000) {
                pacer.enqueue(.media, packet, priority: .retransmit)
            }
            let grace = (state.roundTripNanos ?? 100_000_000) * 2 + 200_000_000
            let expired = videoBuffer.expire(now: now, graceNanos: grace)
            if !expired.isEmpty, let onExpired, let videoCallbackQueue {
                videoCallbackQueue.async { onExpired(expired) }
            }
            nextProbe = videoBuffer.isEmpty ? nil : now &+ probeWait(state)
        }
        pump()
        rearm()
    }

    /// 把定时器设到最早要干活的时刻。什么都不用干就停着。
    private func rearm() {
        guard !isStopped else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        var target = UInt64.max
        if let wait = pacer.waitNanos(now: now) { target = min(target, now &+ max(wait, 500_000)) }
        if let kcp, kcp.waitingSegments > 0 {
            let current = Self.millis(now)
            let next = kcp.nextUpdate(nowMillis: current)
            target = min(target, now &+ UInt64(next &- current) * 1_000_000)
        }
        if let reportDue { target = min(target, reportDue) }
        if onVideoFrame != nil, reassembler.hasWork { target = min(target, now &+ 5_000_000) }
        if let nextProbe { target = min(target, nextProbe) }
        guard target != .max else {
            if armedFor != .max {
                armedFor = .max
                timer.schedule(deadline: .distantFuture)
            }
            return
        }
        guard target < armedFor else { return }
        armedFor = target
        timer.schedule(deadline: .now() + .nanoseconds(Int(target > now ? target - now : 0)), leeway: .microseconds(500))
    }

    private func fail(_ error: Error) {
        guard failure == nil, !isStopped else { return }
        failure = error
        let finished = completions
        completions = []
        callbackQueue?.async {
            for item in finished { item.completion(error) }
        }
        if let onEvent, let callbackQueue { callbackQueue.async { onEvent(.failed(error)) } }
        serveRead()
    }

    private static func millis(_ nanos: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: nanos / 1_000_000)
    }
}

/// 打洞打通的路径。
nonisolated final class RemoteICEDatagramPath: RemoteDatagramPath, @unchecked Sendable {
    private let agent: RemoteICEAgent
    private let handlers: Handlers

    final class Handlers: @unchecked Sendable {
        private let lock = NSLock()
        private var onDatagram: (@Sendable (Data) -> Void)?
        private var onFailure: (@Sendable (Error?) -> Void)?
        private var pending: [Data] = []
        private var failed = false

        func set(onDatagram: @escaping @Sendable (Data) -> Void, onFailure: @escaping @Sendable (Error?) -> Void) {
            lock.lock()
            self.onDatagram = onDatagram
            self.onFailure = onFailure
            let queued = pending
            pending = []
            let alreadyFailed = failed
            lock.unlock()
            for datagram in queued { onDatagram(datagram) }
            if alreadyFailed { onFailure(RemoteProtocolError.timeout) }
        }

        func deliver(_ datagram: Data) {
            lock.lock()
            guard let handler = onDatagram else {
                // 打通到接上业务之间，对端的第一批包不能丢。
                if pending.count < 256 { pending.append(datagram) }
                lock.unlock()
                return
            }
            lock.unlock()
            handler(datagram)
        }

        func fail() {
            lock.lock()
            failed = true
            let handler = onFailure
            lock.unlock()
            handler?(RemoteProtocolError.timeout)
        }
    }

    /// agent 必须用同一个 `handlers` 创建。
    init(agent: RemoteICEAgent, handlers: Handlers) {
        self.agent = agent
        self.handlers = handlers
    }

    func start(onDatagram: @escaping @Sendable (Data) -> Void, onFailure: @escaping @Sendable (Error?) -> Void) {
        handlers.set(onDatagram: onDatagram, onFailure: onFailure)
    }

    func send(_ datagram: Data) {
        agent.send(datagram)
    }

    func close() {
        agent.close()
    }
}
