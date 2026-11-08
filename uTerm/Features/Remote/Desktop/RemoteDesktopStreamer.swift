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
    /// 静止精修用的那张：`frame`（之前交出去的某一帧）的高画质版本，没有就是 nil（照用 `frame`）。
    /// 采集要再缩一截时，运动帧用快的缩法，这里换成 Lanczos 从原始采集重缩。在连接队列上调用。
    func refinedImage(of frame: CVPixelBuffer) -> CVPixelBuffer?
}

nonisolated extension RemoteDesktopFrameSource {
    func refinedImage(of frame: CVPixelBuffer) -> CVPixelBuffer? { nil }
}

/// 输入落点：生产是 `CGEvent` 注入，测试是记录器。在连接队列上调用。
nonisolated protocol RemoteDesktopInputSink: AnyObject, Sendable {
    func inject(_ input: RemoteDesktopInput)
    /// 把手机发来的图片 / 文字放进 Mac 的剪贴板，再替用户按一下 ⌘V。
    func paste(_ content: RemoteDesktopPaste)
    /// 松开还按着的鼠标键。停流时调用：手机断开后发不来抬起事件。
    func releaseButtons()
}

/// Mac 的系统剪贴板（只读）：生产是 `NSPasteboard.general`，测试是内存里的假剪贴板。在连接队列上调用。
nonisolated protocol RemoteDesktopClipboardSource: AnyObject, Sendable {
    /// 每次有人写剪贴板就变（`NSPasteboard.changeCount`）。
    var changeCount: Int { get }
    /// 剪贴板里的纯文字；没有文字（图片、文件）时 nil。
    func text() -> String?
}

/// 采集到的一帧，在来源队列、连接队列、编码器之间传递。
nonisolated struct RemoteCapturedFrame: @unchecked Sendable {
    let image: CVPixelBuffer
    let captureNanos: UInt64
    /// 跟上一张采集帧比，抽样点里变了几成（0…1）；nil = 没量（第一张、格式不认）。只用于诊断日志。
    var change: Double? = nil
}

/// 量相邻两张采集帧变了多少：在亮度平面（单平面格式就是整张图）上按 256×256 的格子抽字节，数有几成不一样。
/// 只为诊断「编码器把在变的画面当成没变跳过了」还是「画面本来就几乎没变」。在采集回调的队列上用，不加锁。
nonisolated final class RemoteFrameChangeProbe: @unchecked Sendable {
    static let grid = 256
    private var previous: [UInt8] = []
    private var previousSize = (0, 0)

    func measure(_ image: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let planar = CVPixelBufferIsPlanar(image)
        let width = planar ? CVPixelBufferGetWidthOfPlane(image, 0) : CVPixelBufferGetWidth(image)
        let height = planar ? CVPixelBufferGetHeightOfPlane(image, 0) : CVPixelBufferGetHeight(image)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(image, 0) : CVPixelBufferGetBytesPerRow(image)
        guard width > 0, height > 0,
              let base = planar ? CVPixelBufferGetBaseAddressOfPlane(image, 0) : CVPixelBufferGetBaseAddress(image)
        else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let bytesPerPixel = max(1, stride / width)
        var samples = [UInt8](repeating: 0, count: Self.grid * Self.grid)
        for row in 0..<Self.grid {
            let y = row * height / Self.grid
            for column in 0..<Self.grid {
                samples[row * Self.grid + column] = bytes[y * stride + column * width / Self.grid * bytesPerPixel]
            }
        }
        defer {
            previous = samples
            previousSize = (width, height)
        }
        guard previousSize == (width, height), previous.count == samples.count else { return nil }
        var changed = 0
        for index in samples.indices where samples[index] != previous[index] { changed += 1 }
        return Double(changed) / Double(samples.count)
    }
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
    /// 剪贴板的轮询间隔：macOS 没有剪贴板变化通知，只能看 `changeCount`。读它只是一次进程间查询，很便宜。
    static let clipboardIntervalNanos: UInt64 = 500_000_000

    let link: RemoteLink
    let channel: UInt32
    let codec: RemoteVideoCodec
    let width: Int
    let height: Int
    let display: RemoteDesktopDisplay
    /// 10-bit 主流 + 旁路精修（手机声明能解旁路帧、且是 HEVC 时）。否则 8-bit 主流、主流里精修。
    let sidecarRefine: Bool
    let stats = RemoteDesktopStreamerStats()

    /// 公网直连时视频走的不可靠通道；nil = 视频是 `link` 上的普通消息。
    private let video: (any RemoteVideoDatagramChannel)?
    /// 同上，给声音用：视频走数据报时声音也走。
    var datagramChannel: (any RemoteVideoDatagramChannel)? { video }
    private let source: any RemoteDesktopFrameSource
    private let injector: (any RemoteDesktopInputSink)?
    private let cursorLocation: (@Sendable () -> CGPoint?)?
    /// 有它才把 Mac 上新拷贝的文字回传手机：手机认得 `desktopClipboard`、且这条流能控制时才给。
    private let clipboard: (any RemoteDesktopClipboardSource)?
    private let onFirstInput: @Sendable () -> Void
    private let onSourceStopped: @Sendable (Error?) -> Void

    // 以下只在 link.queue 上。
    private var encoder: RemoteVideoEncoder?
    /// 旁路精修的编码器（`sidecarRefine` 时才有）。
    private var stillEncoder: RemoteVideoEncoder?
    private var pacer = RemoteDesktopPacer<RemoteCapturedFrame>()
    private var rate: RemoteRateController
    private var quality = RemoteQualityCap(now: DispatchTime.now().uptimeNanoseconds)
    private var isLive = false
    private var isStopped = false
    /// 手机在后台（`desktopPause`）：照常采集（留着最新一张），但不编码、不发帧、不发光标。只属于这一条流——
    /// 重连 / 重新开流是新的发送端，从不暂停起步，不会卡在暂停里。
    private var isPaused = false
    private var lastFrame: RemoteCapturedFrame?
    private var lastCaptureNanos: UInt64 = 0
    /// 采集回调里量画面变化（诊断用）。采集回调是串行的。
    private let changeProbe = RemoteFrameChangeProbe()
    private var diagnostics = RemoteEncoderDiagnostics()
    private var lastDiagnosticsLog: UInt64 = 0
    /// 被编码器丢掉、还没补发过的那一张：画面随后静止就补发一次（见 `resendIfStill`）。
    private var droppedCapture: UInt64?
    private var refined = true
    private var forceKeyframe = true
    private var forceLTRRefresh = false
    /// 已发出、还没确认的精修帧。它们的确认不进码控与往返读数：一张 4K 精修几百 KB，「采集 → 解码完」
    /// 量的是它自己发多久，不是链路排队。
    private var refineSequences: Set<UInt32> = []
    /// 这条链路现在的纠错强度（见 `RemoteLossPolicy`）。
    private var fecGroupSize = 0
    private var pasteAssembler = RemoteDesktopPasteAssembler()
    private var linkState: RemoteLinkState?
    /// 码控上一次定的码率（不扣纠错、不看节奏），用来判断这次是不是在往下调。
    private var appliedRate = 0
    private var flushScheduled = false
    private var sawInput = false
    private var cursorTimer: DispatchSourceTimer?
    private var lastCursor: RemoteDesktopCursor?
    private var clipboardTimer: DispatchSourceTimer?
    /// 已经处理过（发过、或不该发）的剪贴板版本。
    private var seenClipboardChange = 0
    /// 码控日志：上一次打印时的读数（真机 Wi-Fi 上看码率为什么上不去，只有这一个来源）。
    private var lastRateLog: (nanos: UInt64, stats: RemoteDesktopStreamerStats.Snapshot)?
    /// 手机开流时要了画面往返读数：随码控日志每 2 s 发一条 `desktopLatency`。
    private let sendsLatency: Bool
    /// 建出来的时刻与第一帧发没发（日志：开流到第一帧要多久）。
    private let createdNanos = DispatchTime.now().uptimeNanoseconds
    private var sentFirstFrame = false

    init(link: RemoteLink, channel: UInt32, codec: RemoteVideoCodec, width: Int, height: Int,
         display: RemoteDesktopDisplay, sidecarRefine: Bool = false, sendsLatency: Bool = false,
         path: RemoteLinkPath = .localNetwork,
         video: (any RemoteVideoDatagramChannel)? = nil, source: any RemoteDesktopFrameSource,
         injector: (any RemoteDesktopInputSink)?, cursorLocation: (@Sendable () -> CGPoint?)?,
         clipboard: (any RemoteDesktopClipboardSource)? = nil,
         onFirstInput: @escaping @Sendable () -> Void, onSourceStopped: @escaping @Sendable (Error?) -> Void) {
        self.link = link
        self.channel = channel
        self.codec = codec
        self.width = width
        self.height = height
        self.display = display
        self.sidecarRefine = sidecarRefine
        self.sendsLatency = sendsLatency
        self.video = video
        self.source = source
        self.injector = injector
        self.cursorLocation = cursorLocation
        self.clipboard = clipboard
        self.onFirstInput = onFirstInput
        self.onSourceStopped = onSourceStopped
        rate = RemoteRateController(width: width, height: height, path: path, paced: video != nil,
                                    now: DispatchTime.now().uptimeNanoseconds)
    }

    /// 建编码器、开采集。采集出的帧在 `activate` 之前只留最新一张，不编码不发送。
    func start() async throws {
        let encoder = try RemoteVideoEncoder(codec: codec, width: width, height: height, bitrate: rate.bitrate,
                                             frameRate: rate.frameRate, tenBit: sidecarRefine, ltr: video != nil)
        let stillEncoder = sidecarRefine
            ? try RemoteVideoEncoder(codec: codec, width: width, height: height, bitrate: 0, frameRate: rate.frameRate,
                                     tenBit: true, purpose: .still)
            : nil
        // 异步挂上即可：`activate` 排在它后面，之前采到的帧只留着不编。
        link.queue.async {
            self.encoder = encoder
            self.stillEncoder = stillEncoder
        }
        appliedRate = rate.bitrate
        stats.setBitrate(rate.bitrate)
        try await source.start(
            onFrame: { [weak self] image, nanos in
                guard let self else { return }
                let frame = RemoteCapturedFrame(image: image, captureNanos: nanos,
                                                change: self.changeProbe.measure(image))
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
        link.queue.async { [self] in
            guard !self.isStopped else { return }
            self.link.sendOnQueue(started)
            self.video?.startVideoSending(channel: self.channel, callbackQueue: self.link.queue,
                                          onLinkState: { [weak self] in self?.linkChanged($0) },
                                          onExpired: { [weak self] in self?.framesLost($0) })
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
            self.video?.stopVideoSending()
            self.injector?.releaseButtons()
            self.cursorTimer?.cancel()
            self.cursorTimer = nil
            self.clipboardTimer?.cancel()
            self.clipboardTimer = nil
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
            if !sawInput {
                sawInput = true
                // 剪贴板的起点取在注入第一下之前：这一下本身可能就是 ⌘C。
                startClipboardWatch()
                onFirstInput()
            }
            injector.inject(input)
        case .desktopPaste:
            guard let content = try? RemoteDesktopPaste(decoding: message.payload), let injector else { return }
            injector.paste(content)
            // 粘贴已经同步写好了剪贴板：这一版是手机自己送来的，不回传。
            if let clipboard { seenClipboardChange = clipboard.changeCount }
        case .desktopPasteChunk:
            // 只能看时不攒：这些内容不会被用到，不能白占内存。
            guard let injector, let chunk = try? RemoteDesktopPasteChunk(decoding: message.payload),
                  let content = pasteAssembler.receive(chunk) else { return }
            injector.paste(content)
            // 同上：拼好的粘贴写好了剪贴板，不回传。
            if let clipboard { seenClipboardChange = clipboard.changeCount }
        case .desktopKeyframe:
            forceKeyframe = true
            // 屏幕静止时不会有新帧来触发编码：把最后一帧重编成关键帧。
            if let lastFrame, pacer.pending == nil { offer(lastFrame) }
        case .desktopVideoLost:
            guard let lost = try? RemoteDesktopVideoLost(decoding: message.payload) else { return }
            // 手机说放弃了，就算编码序号已经被别的途径释放过（空列表），也要恢复：它在等。
            video?.videoLost(lost.videoSequences) { [weak self] in self?.framesLost($0, recoverEvenIfEmpty: true) }
        case .desktopPause:
            guard let request = try? RemoteJSON.decode(RemoteDesktopPauseRequest.self, from: message.payload) else { return }
            setPaused(request.paused)
        default:
            break
        }
    }

    private func captured(_ frame: RemoteCapturedFrame) {
        guard !isStopped else { return }
        diagnostics.recordCapture(change: frame.change)
        logDiagnosticsIfDue(now: DispatchTime.now().uptimeNanoseconds)
        lastFrame = frame
        lastCaptureNanos = DispatchTime.now().uptimeNanoseconds
        refined = false
        refineRetries = 0
        stats.recordCapture()
        guard isLive, !isPaused else { return }
        offer(frame)
        scheduleRefineCheck()
    }

    private func offer(_ frame: RemoteCapturedFrame) {
        // 暂停期间所有「补一帧」的入口（关键帧请求、丢帧恢复、码控重送）都落到这里：一律不编，恢复时统一补关键帧。
        guard !isPaused else { return }
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
        guard !isPaused else { return }
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

    /// 这些帧丢了：释放在途，发恢复帧。
    private func framesLost(_ sequences: [UInt32], recoverEvenIfEmpty: Bool = false) {
        guard !isStopped, !sequences.isEmpty || recoverEvenIfEmpty else { return }
        for sequence in sequences {
            pacer.abandon(sequence)
            refineSequences.remove(sequence)
        }
        stats.recordLostFrames(sequences.count)
        if encoder?.usesLTR == true {
            forceLTRRefresh = true
        } else {
            forceKeyframe = true
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if rate.observeLostFrames(count: sequences.count, now: now) { applyRate() }
        // 屏幕静止时不会有新帧来触发编码：把最后一帧重编成恢复帧。
        if let lastFrame, pacer.pending == nil {
            offer(lastFrame)
        } else {
            pump()
        }
    }

    /// 链路现状变了：调纠错强度；丢得太多就降码率。
    private func linkChanged(_ state: RemoteLinkState) {
        guard !isStopped else { return }
        linkState = state
        let groupSize = RemoteLossPolicy.fecGroupSize(lossRate: state.lossRate, roundTripNanos: state.roundTripNanos)
        let now = DispatchTime.now().uptimeNanoseconds
        let lowered = rate.observeLoss(lossRate: state.lossRate, now: now)
        let fecChanged = groupSize != fecGroupSize
        if fecChanged {
            fecGroupSize = groupSize
            video?.setVideoFEC(groupSize: groupSize)
            stats.recordFEC(groupSize)
        }
        // 节奏每 200 ms 都在小幅波动，变化大了才值得动编码器。
        let drifted = abs(mediaBitrate - stats.snapshot().bitrate) * 10 >= max(1, stats.snapshot().bitrate)
        guard fecChanged || lowered || drifted else { return }
        applyRate()
    }

    /// 给编码器的码率：不超过链路实测能发的，再扣掉纠错分片占的那部分。
    private var mediaBitrate: Int {
        var budget = Double(rate.bitrate)
        if let linkState { budget = min(budget, linkState.pacingRate * 8 * RemoteLossPolicy.linkShare) }
        return Int(budget * RemoteLossPolicy.mediaBudgetFactor(fecGroupSize: fecGroupSize))
    }

    private func acknowledged(_ ack: RemoteDesktopAck) {
        video?.acknowledgeVideo(sequence: ack.sequence)
        if let token = ack.ltrToken { encoder?.acknowledgeLTR(token) }
        let refine = refineSequences.remove(ack.sequence) != nil
        guard pacer.acknowledge(ack.sequence) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let latency = now &- ack.captureNanos
        if ack.failed { forceKeyframe = true }
        if !refine {
            stats.recordAck(latencyNanos: latency, decodeMicros: ack.decodeMicros)
            let linkQueueing = linkState.map { $0.queueDelayNanos > rate.config.queueDelayThreshold }
            if rate.observe(latencyNanos: latency, now: now, linkQueueing: linkQueueing) { applyRate() }
        }
        pacer.maxInflightFrames = rate.inflightFrameLimit
        pacer.maxInflightBytes = rate.inflightByteLimit
        logRateIfDue(now: now)
        pump()
    }

    /// 有画面在走时每 2 s 记一行：目标码率、实发帧率与码率、往返、基线、丢帧。
    private func logRateIfDue(now: UInt64) {
        guard let last = lastRateLog else {
            lastRateLog = (now, stats.snapshot())
            return
        }
        guard now &- last.nanos >= 2_000_000_000 else { return }
        let current = stats.snapshot()
        lastRateLog = (now, current)
        let seconds = Double(now &- last.nanos) / 1e9
        let sent = current.sent - last.stats.sent
        // 精修帧的确认不计往返（见 `refineSequences`）。
        let acked = max(0, sent - (current.refines - last.stats.refines))
        let trips = current.roundTripNanos.suffix(min(acked, current.roundTripNanos.count)).sorted()
        func percentile(_ p: Double) -> Double {
            trips.isEmpty ? 0 : Double(trips[min(trips.count - 1, Int(Double(trips.count) * p))]) / 1e6
        }
        let message = String(format: "桌面码控：目标 %.1f Mbps（编码器 %.1f）%d fps｜采集 %.1f fps，实发 %.1f fps %.1f Mbps"
                             + "（关键帧 %d 精修 %d）｜往返 p50 %.0f p95 %.0f ms，"
                             + "基线 %.0f ms，在途上限 %d｜在途满丢 %d，码控丢 %d｜QP 上限 %d",
                             Double(rate.bitrate) / 1e6, Double(mediaBitrate) / 1e6, rate.frameRate,
                             Double(current.captured - last.stats.captured) / seconds, Double(sent) / seconds,
                             Double(current.bytes - last.stats.bytes) * 8 / seconds / 1e6,
                             current.keyframes - last.stats.keyframes, current.refines - last.stats.refines,
                             percentile(0.5), percentile(0.95), Double(rate.baselineLatency ?? 0) / 1e6,
                             pacer.maxInflightFrames, current.congestionDrops - last.stats.congestionDrops,
                             current.encoderDrops - last.stats.encoderDrops, quality.maxQP)
        let link = linkState.map {
            String(format: "｜链路 丢包 %.1f%% 往返 %.0f ms 节奏 %.1f Mbps 纠错 %d 丢帧 %d",
                   $0.lossRate * 100, Double($0.roundTripNanos ?? 0) / 1e6, $0.pacingRate * 8 / 1e6, fecGroupSize,
                   current.lostFrames)
        } ?? ""
        AppLogger.info(message + link, category: RemoteLog.category)
        if sendsLatency, !trips.isEmpty,
           let payload = try? JSONEncoder().encode(RemoteDesktopLatency(p50Millis: Int(percentile(0.5).rounded()),
                                                                        p95Millis: Int(percentile(0.95).rounded()))) {
            self.link.sendOnQueue(RemoteMessage(.desktopLatency, channel: channel, payload: payload))
        }
    }

    /// 主流的一帧编完（nil = 码控丢了）：按丢帧与预算用量调 QP 上限。
    private func recordQuality(bytes: Int?, keyframe: Bool) {
        guard encoder?.isLowLatency == true,
              quality.record(encodedBytes: bytes, keyframe: keyframe, targetBitrate: mediaBitrate,
                             frameRate: rate.frameRate, now: DispatchTime.now().uptimeNanoseconds) else { return }
        encoder?.setMaxQP(quality.maxQP)
    }

    private func applyRate() {
        if rate.bitrate < appliedRate || rate.frameRate < rate.config.fullFrameRate,
           encoder?.isLowLatency == true, quality.congestion() {
            encoder?.setMaxQP(quality.maxQP)
        }
        encoder?.setBitrate(mediaBitrate)
        encoder?.setFrameRate(rate.frameRate)
        pacer.minimumIntervalNanos = rate.frameRate >= rate.config.fullFrameRate
            ? 0 : 1_000_000_000 / UInt64(max(1, rate.frameRate))
        appliedRate = rate.bitrate
        stats.setBitrate(mediaBitrate)
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
        guard isLive, !isPaused, !refined, rate.bitrate >= floor, let lastFrame, pacer.pending == nil,
              pacer.inflight.isEmpty,
              now &- lastCaptureNanos >= Self.refineDelayNanos,
              let (sequence, frame) = pacer.submitDirect(lastFrame, now: now) else { return }
        refined = true
        // 采集要再缩一截时运动帧用的是快缩法：精修换成来源从原始采集用 Lanczos 重缩的那张（采集时刻不变，
        // `encodeStill` 据此判断画面变没变）。
        let still = source.refinedImage(of: frame.image)
            .map { RemoteCapturedFrame(image: $0, captureNanos: frame.captureNanos, change: frame.change) } ?? frame
        if sidecarRefine {
            encodeStill(sequence, still)
        } else {
            encode(sequence, still, refine: true)
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
        let refresh = forceLTRRefresh && !keyframe
        forceLTRRefresh = false
        let submitted = DispatchTime.now().uptimeNanoseconds
        let captureNanos = frame.captureNanos
        encoder.encode(frame.image, presentationNanos: submitted, forceKeyframe: keyframe, forceLTRRefresh: refresh,
                       refine: refine) { [weak self] result in
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
                    if refresh { self.forceLTRRefresh = true }
                    self.stats.recordEncoderDrop()
                    if !refine {
                        self.recordQuality(bytes: nil, keyframe: keyframe)
                        self.diagnostics.recordDrop(keyframe: keyframe, refresh: refresh, change: frame.change)
                    }
                    if refine {
                        // 精修帧被丢：画面已经在手机上了，只是不够清楚。等码控缓过来再精修，别当普通帧重发。
                        self.retryRefine()
                    } else {
                        self.resendIfStill(frame)
                    }
                    self.pump()
                case .failure:
                    self.pacer.abandon(sequence)
                    // 编码出错，参考链可能断了：下一帧必须是关键帧。
                    self.forceKeyframe = true
                    self.pump()
                case .success(let encoded):
                    if !refine {
                        self.recordQuality(bytes: encoded.data.count, keyframe: encoded.isKeyframe)
                        self.diagnostics.recordSent(change: frame.change)
                        if self.droppedCapture == frame.captureNanos { self.droppedCapture = nil }
                    }
                    var flags: RemoteDesktopFrame.Flags = []
                    if encoded.isKeyframe { flags.insert(.keyframe) }
                    if refine { flags.insert(.refine) }
                    if refresh, !encoded.isKeyframe { flags.insert(.ltrRefresh) }
                    self.send(encoded, sequence: sequence, captureNanos: captureNanos, flags: flags,
                              encodeNanos: encodeNanos)
                }
            }
        }
    }

    /// 编好的一帧发出去，计入在途。在连接队列上调用。
    private func send(_ encoded: RemoteEncodedFrame, sequence: UInt32, captureNanos: UInt64,
                      flags: RemoteDesktopFrame.Flags, encodeNanos: UInt64) {
        // 暂停那一刻还在编码器里的帧：编好也不发。手机不看了，恢复时反正从关键帧接上，参考链断了无所谓。
        guard !isPaused else {
            pacer.abandon(sequence)
            return
        }
        if !sentFirstFrame {
            sentFirstFrame = true
            let millis = (DispatchTime.now().uptimeNanoseconds &- createdNanos) / 1_000_000
            AppLogger.notice("远程桌面：第一帧已发出（\(flags.contains(.keyframe) ? "关键帧" : "非关键帧") "
                             + "\(encoded.data.count / 1024) KB，开流后 \(millis) ms）", category: RemoteLog.category)
        }
        let payload = RemoteDesktopFrame(flags: flags, codec: codec, sequence: sequence, captureNanos: captureNanos,
                                         width: UInt16(clamping: width), height: UInt16(clamping: height),
                                         parameterSets: encoded.parameterSets, data: encoded.data,
                                         ltrToken: encoded.ltrToken).encoded()
        // 单帧超过分帧上限（几乎不可能：码率上限下一帧远小于 4 MB）：不发，降码率、下一帧重来。
        guard payload.count + RemoteMessage.headerSize + 64 <= RemoteConstants.maxFrameBytes else {
            pacer.abandon(sequence)
            if !flags.contains(.sidecar) { forceKeyframe = true }
            if rate.congestion(now: DispatchTime.now().uptimeNanoseconds) { applyRate() }
            pump()
            return
        }
        pacer.encoded(sequence, bytes: payload.count)
        if flags.contains(.refine) { refineSequences.insert(sequence) }
        // 旁路精修帧不在参考链里，丢了也不用恢复，体积又大：走可靠通道，慢一点无所谓。
        if let video, !flags.contains(.sidecar) {
            video.sendVideo(payload, sequence: sequence,
                            recovery: !flags.contains(.refine) && (flags.contains(.keyframe) || flags.contains(.ltrRefresh)))
        } else {
            link.sendOnQueue(RemoteMessage(.desktopFrame, channel: channel, payload: payload),
                             countsTowardBackpressure: false)
        }
        stats.recordFrame(bytes: payload.count, encodeNanos: encodeNanos,
                          keyframe: flags.contains(.keyframe) && !flags.contains(.sidecar),
                          refine: flags.contains(.refine))
    }

    /// 编码器丢掉的画面：不马上重送。以前 16 ms 后重送同一张，编码器（低延迟码控把变化太小的帧整帧跳过）
    /// 再跳、再重送，日志里的丢帧被放大成每 2 秒上百（2026-11-08 mini：采集 11 fps 时丢 92）。画面接着在变时
    /// 下一张新画面自然会来；只有画面随后静止下来（`resendDelay` 内没有新采集帧），手机会停在更旧的画面上，
    /// 这时把它补发一次。补发的那张再被丢就算了：静止够久还有精修。
    private func resendIfStill(_ frame: RemoteCapturedFrame) {
        guard droppedCapture != frame.captureNanos else {
            droppedCapture = nil
            return
        }
        let capture = frame.captureNanos
        droppedCapture = capture
        // 只记时间戳，不攥着这张图：采集的表面池只有 `queueDepth` 张，多扣一张半秒，采集就可能出不了新帧。
        link.queue.asyncAfter(deadline: .now() + .nanoseconds(Int(Self.resendDelayNanos))) { [weak self] in
            guard let self, !self.isStopped, self.pacer.pending == nil, self.droppedCapture == capture,
                  let last = self.lastFrame, last.captureNanos == capture else { return }
            self.offer(last)
        }
    }

    static let resendDelayNanos: UInt64 = 500_000_000

    /// 每 2 秒一行：编码器丢的帧分类、采集帧变了多少（info 级，只在有画面时）。
    private func logDiagnosticsIfDue(now: UInt64) {
        guard now &- lastDiagnosticsLog >= 2_000_000_000 else { return }
        lastDiagnosticsLog = now
        guard let line = diagnostics.drain() else { return }
        AppLogger.info("桌面编码诊断：" + line, category: RemoteLog.category)
    }

    // MARK: - 暂停（手机在后台）

    /// 手机退到后台 / 回到前台（`desktopPause`）。
    ///
    /// 暂停只是不编不发：采集照旧（只留最新一张，恢复时有画面可编），码控、QP 上限、链路估计都不碰——对它们来说
    /// 跟屏幕静止一阵没有区别（静止时同样一帧不发），回前台不用重新爬码率。帘幕、锁屏、连接与心跳也都不受影响。
    /// 恢复一律从关键帧接上：暂停前后手机可能跳过了帧，iOS 也可能在后台收走了硬解会话。恢复本身就当关键帧请求，
    /// 手机不用再另发一条（否则同一张画面会编两遍关键帧）。
    private func setPaused(_ paused: Bool) {
        if paused {
            guard !isPaused else { return }
            isPaused = true
            // 等着编的那张不编了；在途的照常等手机确认（后台的手机照收照确认，见 `RemoteDesktopReceiver.setPaused`）。
            _ = pacer.takePending()
            return
        }
        let wasPaused = isPaused
        isPaused = false
        forceKeyframe = true
        forceLTRRefresh = false
        // 光标在暂停期间没发：清掉记录，下一拍按当前位置补发。
        lastCursor = nil
        guard isLive, let lastFrame else { return }
        if pacer.pending == nil {
            offer(lastFrame)
        } else {
            pump()
        }
        if wasPaused {
            // 恢复后若画面一直静止，关键帧之后照常补一次精修。
            refined = false
            refineRetries = 0
            scheduleRefineCheck()
        }
    }

    // MARK: - 光标

    private func startCursorTimer() {
        guard let cursorLocation, cursorTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: link.queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(Self.cursorIntervalNanos)), leeway: .milliseconds(2))
        let bounds = display.bounds
        timer.setEventHandler { [weak self] in
            guard let self, self.isLive, !self.isPaused, let location = cursorLocation() else { return }
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

nonisolated extension RemoteDesktopStreamer {
    // MARK: - 剪贴板回传

    /// 手机第一次操作时开始看剪贴板：只查看的手机拿不到 Mac 的剪贴板。起点是此刻的版本，开流前就在剪贴板里的
    /// 东西不发。
    private func startClipboardWatch() {
        guard let clipboard, clipboardTimer == nil else { return }
        seenClipboardChange = clipboard.changeCount
        let timer = DispatchSource.makeTimerSource(queue: link.queue)
        let interval = Int(Self.clipboardIntervalNanos)
        timer.schedule(deadline: .now() + .nanoseconds(interval), repeating: .nanoseconds(interval),
                       leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.pollClipboard(clipboard) }
        timer.resume()
        clipboardTimer = timer
    }

    private func pollClipboard(_ clipboard: any RemoteDesktopClipboardSource) {
        guard isLive else { return }
        let change = clipboard.changeCount
        guard change != seenClipboardChange else { return }
        seenClipboardChange = change
        guard let text = clipboard.text(), let content = RemoteDesktopClipboard.message(for: text) else { return }
        link.sendOnQueue(RemoteMessage(.desktopClipboard, channel: channel, payload: content.encoded()))
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
        /// 等到时限也没收齐的帧（公网直连才有）。
        var lostFrames = 0
        var fecGroupSizes: [Int] = []
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
    func recordLostFrames(_ count: Int) { lock.lock(); value.lostFrames += count; lock.unlock() }
    func recordFEC(_ groupSize: Int) { lock.lock(); value.fecGroupSizes.append(groupSize); lock.unlock() }

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
        case .desktopAck, .desktopInput, .desktopKeyframe, .desktopPaste, .desktopPasteChunk, .desktopVideoLost,
             .desktopPause:
            if let streamer, streamer.channel == message.channel { streamer.handle(message) }
            return true
        default:
            return false
        }
    }
}

/// 编码器丢帧的诊断计数（连接队列上用）。区分「编码器把在变的画面当成没变跳过」与「画面本来就几乎没变」。
nonisolated struct RemoteEncoderDiagnostics {
    private var captured = 0
    private var identical = 0
    private var captureChanges: [Double] = []
    private var dropNormal = 0
    private var dropRefresh = 0
    private var dropKeyframe = 0
    private var dropChanges: [Double] = []
    private var sentChanges: [Double] = []

    mutating func recordCapture(change: Double?) {
        captured += 1
        guard let change else { return }
        if change == 0 { identical += 1 }
        captureChanges.append(change)
    }

    mutating func recordDrop(keyframe: Bool, refresh: Bool, change: Double?) {
        if keyframe { dropKeyframe += 1 } else if refresh { dropRefresh += 1 } else { dropNormal += 1 }
        if let change { dropChanges.append(change) }
    }

    mutating func recordSent(change: Double?) {
        if let change { sentChanges.append(change) }
    }

    /// 这一段的一行摘要并清零；什么都没发生时返回 nil。
    mutating func drain() -> String? {
        defer { self = RemoteEncoderDiagnostics() }
        guard captured > 0 || dropNormal + dropRefresh + dropKeyframe > 0 else { return nil }
        func spread(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "—" }
            let sorted = values.sorted()
            func pct(_ q: Double) -> String {
                String(format: "%.1f%%", sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] * 100)
            }
            return "p50 \(pct(0.5)) / p95 \(pct(0.95))"
        }
        return "编码器丢 普通 \(dropNormal) 刷新 \(dropRefresh) 关键帧 \(dropKeyframe)｜采集 \(captured) 帧，"
            + "与上一张完全相同 \(identical)，变化面积 \(spread(captureChanges))｜被丢的帧变化 \(spread(dropChanges))"
            + "｜发出的帧变化 \(spread(sentChanges))"
    }
}
