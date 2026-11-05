import CoreGraphics
import CoreVideo
import Foundation

/// 被看的那块显示器。
nonisolated struct RemoteDesktopDisplay: Equatable, Sendable {
    var id: UInt32
    /// 全局坐标（左上角原点，点），`CGEvent` 用的那套。
    var bounds: CGRect
    var pixelWidth: Int
    var pixelHeight: Int
}

/// 画面来源：生产是 ScreenCaptureKit，测试是合成画面。
nonisolated protocol RemoteDesktopFrameSource: AnyObject, Sendable {
    /// 开始采集。`onFrame` 在来源自己的队列上调用，带 Mac 单调时钟的采集时刻（纳秒）。
    /// 屏幕没变化时来源不出帧（ScreenCaptureKit 的 idle 帧不交出来）。
    func start(onFrame: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void,
               onStop: @escaping @Sendable (Error?) -> Void) async throws
    func stop()
}

/// 输入落点：生产是 `CGEvent` 注入，测试是记录器。在连接队列上调用。
nonisolated protocol RemoteDesktopInputSink: AnyObject, Sendable {
    func inject(_ input: RemoteDesktopInput)
    /// 把手机发来的图片 / 文字放进 Mac 的剪贴板，再替用户按一下 ⌘V。
    func paste(_ content: RemoteDesktopPaste)
    /// 松开还按着的鼠标键。停流时调用：手机断开后发不来抬起事件。
    func releaseButtons()
}

/// 采集到的一帧，在来源队列、连接队列、编码器之间传递。
nonisolated struct RemoteCapturedFrame: @unchecked Sendable {
    let image: CVPixelBuffer
    let captureNanos: UInt64
}

/// 一条桌面流的发送端：采集 → 节拍（背压 / 丢帧）→ 编码 → 发送，以及确认、输入、光标。
///
/// 除了构造与 `start`，所有状态只在连接队列（`link.queue`）上读写：确认与输入从连接队列直接进来，
/// 不经主线程；采集帧、编码完成都先跳回这条队列再处理。编码本身在硬件上，不占这条队列。
nonisolated final class RemoteDesktopStreamer: @unchecked Sendable {
    /// 画面静止多久之后精修一次。
    static let refineDelayNanos: UInt64 = 300_000_000
    /// 主流里精修（老手机）时，码率低于这个值不精修。实测（1856×1206 HEVC，见调研 §9）：1 Mbps 下精修帧约
    /// 330 KB，码控为还这笔账会连丢约 0.5 s 的帧——用户此时一动，第一下就卡半秒。
    /// 旁路精修不经主流码控、没有这笔账，只在拥塞控制已压到下限（链路真的很差）时才不发。
    static let refineMinBitrate = 4_000_000
    /// 光标位置的轮询间隔（只在变化时发）。
    static let cursorIntervalNanos: UInt64 = 16_000_000

    let link: RemoteLink
    let channel: UInt32
    let codec: RemoteVideoCodec
    let width: Int
    let height: Int
    let display: RemoteDesktopDisplay
    /// 10-bit 主流 + 旁路精修（手机声明能解旁路帧、且是 HEVC 时）。否则 8-bit 主流、主流里精修。
    let sidecarRefine: Bool
    let stats = RemoteDesktopStreamerStats()

    private let source: any RemoteDesktopFrameSource
    private let injector: (any RemoteDesktopInputSink)?
    private let cursorLocation: (@Sendable () -> CGPoint?)?
    private let onFirstInput: @Sendable () -> Void
    private let onSourceStopped: @Sendable (Error?) -> Void

    // 以下只在 link.queue 上。
    private var encoder: RemoteVideoEncoder?
    /// 旁路精修的编码器（`sidecarRefine` 时才有）。
    private var stillEncoder: RemoteVideoEncoder?
    private var pacer = RemoteDesktopPacer<RemoteCapturedFrame>()
    private var rate: RemoteRateController
    private var isLive = false
    private var isStopped = false
    private var lastFrame: RemoteCapturedFrame?
    private var lastCaptureNanos: UInt64 = 0
    private var refined = true
    private var forceKeyframe = true
    private var flushScheduled = false
    private var sawInput = false
    private var cursorTimer: DispatchSourceTimer?
    private var lastCursor: RemoteDesktopCursor?

    init(link: RemoteLink, channel: UInt32, codec: RemoteVideoCodec, width: Int, height: Int,
         display: RemoteDesktopDisplay, sidecarRefine: Bool = false, source: any RemoteDesktopFrameSource,
         injector: (any RemoteDesktopInputSink)?, cursorLocation: (@Sendable () -> CGPoint?)?,
         onFirstInput: @escaping @Sendable () -> Void, onSourceStopped: @escaping @Sendable (Error?) -> Void) {
        self.link = link
        self.channel = channel
        self.codec = codec
        self.width = width
        self.height = height
        self.display = display
        self.sidecarRefine = sidecarRefine
        self.source = source
        self.injector = injector
        self.cursorLocation = cursorLocation
        self.onFirstInput = onFirstInput
        self.onSourceStopped = onSourceStopped
        rate = RemoteRateController(width: width, height: height, now: DispatchTime.now().uptimeNanoseconds)
    }

    /// 建编码器、开采集。采集出的帧在 `activate` 之前只留最新一张，不编码不发送。
    func start() async throws {
        let encoder = try RemoteVideoEncoder(codec: codec, width: width, height: height, bitrate: rate.bitrate,
                                             frameRate: rate.frameRate, tenBit: sidecarRefine)
        let stillEncoder = sidecarRefine
            ? try RemoteVideoEncoder(codec: codec, width: width, height: height, bitrate: 0, frameRate: rate.frameRate,
                                     tenBit: true, purpose: .still)
            : nil
        // 异步挂上即可：`activate` 排在它后面，之前采到的帧只留着不编。
        link.queue.async {
            self.encoder = encoder
            self.stillEncoder = stillEncoder
        }
        stats.setBitrate(rate.bitrate)
        try await source.start(
            onFrame: { [weak self] image, nanos in
                guard let self else { return }
                let frame = RemoteCapturedFrame(image: image, captureNanos: nanos)
                self.link.queue.async { self.captured(frame) }
            },
            onStop: { [weak self] error in
                guard let self else { return }
                self.link.queue.async {
                    guard !self.isStopped else { return }
                    self.onSourceStopped(error)
                }
            })
    }

    /// 在连接队列上发出「开流成功」并开始推流：保证手机先收到 `desktopStarted` 再收到第一帧。
    func activate(started: RemoteMessage) {
        link.queue.async {
            guard !self.isStopped else { return }
            self.link.sendOnQueue(started)
            self.isLive = true
            self.startCursorTimer()
            if let frame = self.lastFrame {
                self.offer(frame)
                // 开流时屏幕往往是静止的：这张之后可能再没有新帧来触发精修，自己约一次。
                self.scheduleRefineCheck()
            }
        }
    }

    func stop() {
        link.queue.async {
            self.isStopped = true
            self.isLive = false
            self.injector?.releaseButtons()
            self.cursorTimer?.cancel()
            self.cursorTimer = nil
            self.encoder = nil
            self.stillEncoder = nil
            self.lastFrame = nil
            _ = self.pacer.takePending()
        }
        source.stop()
    }

    // MARK: - 连接队列上的入口

    /// 确认 / 输入 / 关键帧请求。
    func handle(_ message: RemoteMessage) {
        dispatchPrecondition(condition: .onQueue(link.queue))
        guard !isStopped else { return }
        switch message.kind {
        case .desktopAck:
            guard let ack = try? RemoteDesktopAck(decoding: message.payload) else { return }
            acknowledged(ack)
        case .desktopInput:
            guard let input = try? RemoteDesktopInput(decoding: message.payload), let injector else { return }
            injector.inject(input)
            if !sawInput {
                sawInput = true
                onFirstInput()
            }
        case .desktopPaste:
            guard let content = try? RemoteDesktopPaste(decoding: message.payload), let injector else { return }
            injector.paste(content)
        case .desktopKeyframe:
            forceKeyframe = true
            // 屏幕静止时不会有新帧来触发编码：把最后一帧重编成关键帧。
            if let lastFrame, pacer.pending == nil { offer(lastFrame) }
        default:
            break
        }
    }

    private func captured(_ frame: RemoteCapturedFrame) {
        guard !isStopped else { return }
        lastFrame = frame
        lastCaptureNanos = DispatchTime.now().uptimeNanoseconds
        refined = false
        refineRetries = 0
        stats.recordCapture()
        guard isLive else { return }
        offer(frame)
        scheduleRefineCheck()
    }

    private func offer(_ frame: RemoteCapturedFrame) {
        let now = DispatchTime.now().uptimeNanoseconds
        let (submit, congested) = pacer.offer(frame, now: now)
        // 在途满了被替掉只记数，不降码率：往返比帧间隔长也会这样，带宽真不够时延迟会涨，由 `rate` 看延迟判。
        if congested { stats.recordDrop() }
        if let (sequence, frame) = submit {
            encode(sequence, frame, refine: false)
        }
        pump()
    }

    /// 能编就把留着的帧编出去；卡在帧间隔上就到点再来。
    private func pump() {
        let now = DispatchTime.now().uptimeNanoseconds
        while let (sequence, frame) = pacer.next(now: now) {
            encode(sequence, frame, refine: false)
        }
        let wait = pacer.waitNanos(now: now)
        if wait > 0, !flushScheduled {
            flushScheduled = true
            link.queue.asyncAfter(deadline: .now() + .nanoseconds(Int(wait))) { [weak self] in
                guard let self else { return }
                self.flushScheduled = false
                guard !self.isStopped else { return }
                self.pump()
            }
        }
        refineIfStill(now: now)
    }

    private func acknowledged(_ ack: RemoteDesktopAck) {
        guard pacer.acknowledge(ack.sequence) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let latency = now &- ack.captureNanos
        stats.recordAck(latencyNanos: latency, decodeMicros: ack.decodeMicros)
        if ack.failed { forceKeyframe = true }
        if rate.observe(latencyNanos: latency, now: now) { applyRate() }
        pacer.maxInflightFrames = rate.inflightFrameLimit
        pump()
    }

    private func applyRate() {
        encoder?.setBitrate(rate.bitrate)
        encoder?.setFrameRate(rate.frameRate)
        pacer.minimumIntervalNanos = rate.frameRate >= rate.config.fullFrameRate
            ? 0 : 1_000_000_000 / UInt64(max(1, rate.frameRate))
        stats.setBitrate(rate.bitrate)
    }

    // MARK: - 静止精修

    /// 精修帧被码控丢掉后重试的次数（每段静止重新计）。
    private var refineRetries = 0

    private func retryRefine() {
        guard refineRetries < 10 else { return }
        refineRetries += 1
        refined = false
        link.queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.refineIfStill(now: DispatchTime.now().uptimeNanoseconds)
        }
    }

    private func scheduleRefineCheck() {
        link.queue.asyncAfter(deadline: .now() + .nanoseconds(Int(Self.refineDelayNanos))) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.refineIfStill(now: DispatchTime.now().uptimeNanoseconds)
        }
    }

    /// 画面静止够久、链路空闲、还没精修过：把最后一帧用更高的画质重编一次。
    private func refineIfStill(now: UInt64) {
        let floor = sidecarRefine ? rate.config.minBitrate + 1 : Self.refineMinBitrate
        guard isLive, !refined, rate.bitrate >= floor, let lastFrame, pacer.pending == nil,
              pacer.inflight.isEmpty,
              now &- lastCaptureNanos >= Self.refineDelayNanos,
              let (sequence, frame) = pacer.submitDirect(lastFrame, now: now) else { return }
        refined = true
        if sidecarRefine {
            encodeStill(sequence, frame)
        } else {
            encode(sequence, frame, refine: true)
        }
    }

    /// 旁路精修：另一个会话把这张静止画面编成高画质关键帧。编好时画面若已经变了（手机上已是更新的
    /// 主流画面），就不发：发了会把旧画面盖回去。
    private func encodeStill(_ sequence: UInt32, _ frame: RemoteCapturedFrame) {
        guard let stillEncoder else {
            pacer.abandon(sequence)
            return
        }
        let submitted = DispatchTime.now().uptimeNanoseconds
        stillEncoder.encode(frame.image, presentationNanos: submitted, forceKeyframe: true, refine: false) { [weak self] result in
            guard let self else { return }
            let encodeNanos = DispatchTime.now().uptimeNanoseconds &- submitted
            self.link.queue.async {
                guard !self.isStopped else { return }
                guard case .success(let encoded) = result, encoded.isKeyframe,
                      self.lastFrame?.captureNanos == frame.captureNanos else {
                    self.pacer.abandon(sequence)
                    self.pump()
                    return
                }
                self.send(encoded, sequence: sequence, captureNanos: frame.captureNanos,
                          flags: [.keyframe, .refine, .sidecar], encodeNanos: encodeNanos)
            }
        }
    }

    // MARK: - 编码与发送

    private func encode(_ sequence: UInt32, _ frame: RemoteCapturedFrame, refine: Bool) {
        guard let encoder else {
            pacer.abandon(sequence)
            return
        }
        let keyframe = forceKeyframe
        forceKeyframe = false
        let submitted = DispatchTime.now().uptimeNanoseconds
        let captureNanos = frame.captureNanos
        encoder.encode(frame.image, presentationNanos: submitted, forceKeyframe: keyframe, refine: refine) { [weak self] result in
            guard let self else { return }
            let encodeNanos = DispatchTime.now().uptimeNanoseconds &- submitted
            self.link.queue.async {
                guard !self.isStopped else { return }
                switch result {
                case .failure(.dropped):
                    // 码控丢帧：参考链没断，不要关键帧（关键帧更大，只会丢得更多）。但这张画面没发出去，
                    // 屏幕若就此静止，手机会停在旧画面上——没有更新的帧在等时，隔一帧时间把它再送一次。
                    self.pacer.abandon(sequence)
                    if keyframe { self.forceKeyframe = true }
                    self.stats.recordEncoderDrop()
                    if refine {
                        // 精修帧被丢：画面已经在手机上了，只是不够清楚。等码控缓过来再精修，别当普通帧重发。
                        self.retryRefine()
                    } else {
                        self.retryLater(frame)
                    }
                    self.pump()
                case .failure:
                    self.pacer.abandon(sequence)
                    // 编码出错，参考链可能断了：下一帧必须是关键帧。
                    self.forceKeyframe = true
                    self.pump()
                case .success(let encoded):
                    var flags: RemoteDesktopFrame.Flags = []
                    if encoded.isKeyframe { flags.insert(.keyframe) }
                    if refine { flags.insert(.refine) }
                    self.send(encoded, sequence: sequence, captureNanos: captureNanos, flags: flags,
                              encodeNanos: encodeNanos)
                }
            }
        }
    }

    /// 编好的一帧发出去，计入在途。在连接队列上调用。
    private func send(_ encoded: RemoteEncodedFrame, sequence: UInt32, captureNanos: UInt64,
                      flags: RemoteDesktopFrame.Flags, encodeNanos: UInt64) {
        let payload = RemoteDesktopFrame(flags: flags, codec: codec, sequence: sequence, captureNanos: captureNanos,
                                         width: UInt16(clamping: width), height: UInt16(clamping: height),
                                         parameterSets: encoded.parameterSets, data: encoded.data).encoded()
        // 单帧超过分帧上限（几乎不可能：码率上限下一帧远小于 4 MB）：不发，降码率、下一帧重来。
        guard payload.count + RemoteMessage.headerSize + 64 <= RemoteConstants.maxFrameBytes else {
            pacer.abandon(sequence)
            if !flags.contains(.sidecar) { forceKeyframe = true }
            if rate.congestion(now: DispatchTime.now().uptimeNanoseconds) { applyRate() }
            pump()
            return
        }
        pacer.encoded(sequence, bytes: payload.count)
        link.sendOnQueue(RemoteMessage(.desktopFrame, channel: channel, payload: payload))
        stats.recordFrame(bytes: payload.count, encodeNanos: encodeNanos,
                          keyframe: flags.contains(.keyframe) && !flags.contains(.sidecar),
                          refine: flags.contains(.refine))
    }

    /// 码控丢掉的画面：一帧时间后若还没有更新的画面，再送一次。
    private func retryLater(_ frame: RemoteCapturedFrame) {
        link.queue.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
            guard let self, !self.isStopped, self.pacer.pending == nil,
                  self.lastFrame?.captureNanos == frame.captureNanos else { return }
            self.offer(frame)
        }
    }

    // MARK: - 光标

    private func startCursorTimer() {
        guard let cursorLocation, cursorTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: link.queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(Self.cursorIntervalNanos)), leeway: .milliseconds(2))
        let bounds = display.bounds
        timer.setEventHandler { [weak self] in
            guard let self, self.isLive, let location = cursorLocation() else { return }
            let point = RemoteDesktopGeometry.normalized(location, displayBounds: bounds)
            let visible = bounds.contains(location)
            let cursor = RemoteDesktopCursor(x: point.x, y: point.y, visible: visible)
            guard cursor != self.lastCursor else { return }
            self.lastCursor = cursor
            self.link.sendOnQueue(RemoteMessage(.desktopCursor, channel: self.channel, payload: cursor.encoded()))
        }
        timer.resume()
        cursorTimer = timer
    }
}

/// 发送端读数（探针与设置页用）：编码耗时、采集到手机解码完的往返、码率、丢帧。
nonisolated final class RemoteDesktopStreamerStats: @unchecked Sendable {
    struct Snapshot: Sendable {
        var captured = 0
        var sent = 0
        var keyframes = 0
        var refines = 0
        var congestionDrops = 0
        /// 码控主动丢掉的帧（编码器为守住码率不出这一帧）。
        var encoderDrops = 0
        var bytes = 0
        var bitrate = 0
        var bitrateHistory: [Int] = []
        /// 编码耗时（ns），最近 600 帧。
        var encodeNanos: [UInt64] = []
        /// 采集 → 手机解码完并确认回到 Mac（ns），最近 600 帧。
        var roundTripNanos: [UInt64] = []
        var decodeMicros: [UInt32] = []
    }

    private let lock = NSLock()
    private var value = Snapshot()
    private static let window = 600

    func recordCapture() { lock.lock(); value.captured += 1; lock.unlock() }
    func recordDrop() { lock.lock(); value.congestionDrops += 1; lock.unlock() }
    func recordEncoderDrop() { lock.lock(); value.encoderDrops += 1; lock.unlock() }

    func setBitrate(_ bitrate: Int) {
        lock.lock(); defer { lock.unlock() }
        guard bitrate != value.bitrate else { return }
        value.bitrate = bitrate
        value.bitrateHistory.append(bitrate)
    }

    func recordFrame(bytes: Int, encodeNanos: UInt64, keyframe: Bool, refine: Bool) {
        lock.lock(); defer { lock.unlock() }
        value.sent += 1
        value.bytes += bytes
        if keyframe { value.keyframes += 1 }
        if refine { value.refines += 1 }
        Self.push(&value.encodeNanos, encodeNanos)
    }

    func recordAck(latencyNanos: UInt64, decodeMicros: UInt32) {
        lock.lock(); defer { lock.unlock() }
        Self.push(&value.roundTripNanos, latencyNanos)
        Self.push(&value.decodeMicros, decodeMicros)
    }

    private static func push<T>(_ array: inout [T], _ element: T) {
        array.append(element)
        if array.count > window { array.removeFirst(array.count - window) }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// 连接队列上的桌面消息分发：确认、输入、关键帧请求直接交给当前的发送端，不经主线程。
/// 发送端只在开流成功后挂上来，所以「没通过配对的连接发桌面输入」在这里自然落空。
nonisolated final class RemoteDesktopRoute: @unchecked Sendable {
    private let queue: DispatchQueue
    /// 只在 `queue` 上读写。
    private var streamer: RemoteDesktopStreamer?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func set(_ streamer: RemoteDesktopStreamer?) {
        queue.async { self.streamer = streamer }
    }

    /// 在连接队列上调用。返回 true = 这是桌面流的消息，已处理（或已按通道不符丢弃）。
    func handle(_ message: RemoteMessage) -> Bool {
        switch message.kind {
        case .desktopAck, .desktopInput, .desktopKeyframe, .desktopPaste:
            if let streamer, streamer.channel == message.channel { streamer.handle(message) }
            return true
        default:
            return false
        }
    }
}
