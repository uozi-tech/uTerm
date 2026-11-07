import CoreVideo
import Foundation
import Observation

/// 手机这一侧的一条桌面流：开流、解码、确认、关键帧请求、断线重连、发输入。
///
/// 放在共享目录是为了让 Mac 单测能端到端驱动它（与 `RemoteTerminalBackend` 同理）。
///
/// 线程：视频帧在连接队列上到达，转到专用解码队列同步硬解，解完立刻回确认、交给渲染回调；
/// 整条路不经主线程。主线程只管状态（连接中 / 播放中 / 重连中 / 结束）与输入的发出。
@MainActor
@Observable
final class RemoteDesktopSession {
    enum State: Equatable {
        case idle
        case connecting
        case streaming
        /// 连接断了，正在退避重连（附带原因）。
        case reconnecting(String)
        /// 开不起来（Mac 拒绝、没授权、连不上）。可以手动重试。
        case failed(String)
        /// Mac 结束了这条流（在 Mac 上断开、被别的设备接管、关了开关）。
        case ended(String)
        /// Mac 上的 uTerm 太旧，不认桌面消息。
        case unsupported

        /// 停在这里不会自己变了（要用户点重试 / 关闭）。
        var isTerminal: Bool {
            switch self {
            case .failed, .ended, .unsupported: return true
            case .idle, .connecting, .streaming, .reconnecting: return false
            }
        }
    }

    private(set) var state: State = .idle
    /// 最近一次开流成功时 Mac 报的信息（显示器尺寸、能不能控制）。
    private(set) var info: RemoteDesktopInfo?
    /// 每秒刷新一次的读数（帧率、码率、解码耗时），给界面上的小字用。
    private(set) var stats = RemoteDesktopReceiverStats.Snapshot()
    /// Mac 上拷贝的文字回传过来了（手机控制桌面时，Mac 认得 `desktopClipboard` 才会发）。界面在这里写系统
    /// 剪贴板并提示；共享目录里不碰 `UIPasteboard`，Mac 单测才能端到端驱动。
    @ObservationIgnored var onClipboard: (@MainActor (RemoteDesktopClipboard) -> Void)?
    /// Mac 报来的画面往返（≈ 一次操作到看见结果）；老 Mac 不报，一直是 nil。
    private(set) var latency: RemoteDesktopLatency?
    /// Mac 的锁屏 / 帘幕状态（支持远程解锁的 Mac 才发）。
    private(set) var screen = RemoteDesktopScreenState(locked: false, curtained: false, unlockAvailable: false)
    /// 这台 Mac 支持远程解锁（能收到锁屏状态、能发解锁请求）。
    var supportsUnlock: Bool { client.supportsUnlock }
    @ObservationIgnored private var unlockWaiters: [UUID: CheckedContinuation<RemoteDesktopUnlockResult.Outcome, Never>] = [:]

    nonisolated let receiver: RemoteDesktopReceiver
    let client: RemoteMacClient
    private let codec: RemoteVideoCodec
    private let maxWidth: Int
    private let maxHeight: Int
    /// 要看的显示器（nil = 那台 Mac 的主显示器）。`switchDisplay` 改它再重开流。
    private(set) var displayID: UInt32?
    @ObservationIgnored private var attachment: RemoteAttachment?
    @ObservationIgnored private var pasteUploader: RemoteDesktopPasteUploader?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var generation = 0
    /// App 在后台。重连开出的新流在 Mac 那边从不暂停起步，开好后要按它再暂停一次。
    @ObservationIgnored private var backgrounded = false

    /// - Parameters:
    ///   - maxWidth/maxHeight: 想要的视频最大像素（与方向无关，Mac 按显示器的横竖套）。
    ///   - outputPixelFormat: 解出来的像素格式（显示用 4:2:0，测试比对用 BGRA）。
    init(client: RemoteMacClient, maxWidth: Int, maxHeight: Int, codec: RemoteVideoCodec = .hevc,
         outputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, displayID: UInt32? = nil) {
        self.client = client
        self.displayID = displayID
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.codec = codec
        receiver = RemoteDesktopReceiver(outputPixelFormat: outputPixelFormat)
    }

    var canControl: Bool { info?.canControl ?? false }

    // MARK: - 起停

    func start() async {
        isStopped = false
        reconnectTask?.cancel()
        reconnectTask = nil
        state = .connecting
        startStatsTicker()
        do {
            try await open()
        } catch RemoteDesktopError.macTooOld {
            state = .unsupported
        } catch {
            if !isStopped { state = .failed(error.localizedDescription) }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        statsTask?.cancel()
        statsTask = nil
        generation += 1
        if let attachment {
            client.stopDesktop(attachment)
        }
        attachment = nil
        receiver.detach()
        state = .idle
    }

    /// 换一块显示器看：停掉当前这路，按新的 id 重开（Mac 那边换采集源与注入坐标系）。
    func switchDisplay(to id: UInt32) async {
        guard id != info?.displayID else { return }
        displayID = id
        stop()
        await start()
    }

    /// 开一条流。失败（Mac 拒绝）抛 `RemoteAttachError.rejected`。
    private func open() async throws {
        generation += 1
        let current = generation
        let receiver = self.receiver
        receiver.reset(generation: current)
        let sink = RemoteChannelSink(
            onOutput: { _ in },
            onClosed: { [weak self] reason, ended in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.channelClosed(generation: current, reason: reason, ended: ended) }
                }
            },
            onMessage: { [weak self] message, link in
                switch message.kind {
                case .desktopClipboard:
                    guard let content = try? RemoteDesktopClipboard(decoding: message.payload) else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.clipboardArrived(content, generation: current) }
                    }
                case .desktopScreenState:
                    guard let state = try? RemoteJSON.decode(RemoteDesktopScreenState.self, from: message.payload) else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.screen = state } }
                case .desktopUnlockResult:
                    guard let result = try? RemoteJSON.decode(RemoteDesktopUnlockResult.self, from: message.payload) else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.unlockResultArrived(result) } }
                default:
                    receiver.receive(message, from: link, generation: current)
                }
            }
        )
        let request = RemoteDesktopStartRequest(requestID: UUID(), maxWidth: maxWidth, maxHeight: maxHeight, codec: codec,
                                                displayID: displayID, sidecarRefine: true, latencyStats: true)
        let (attached, info) = try await client.startDesktop(request, sink: sink, prepareVideo: { video, link in
            receiver.attachVideo(video, link: link, generation: current)
        })
        guard current == generation, !isStopped else {
            if info.failure == nil { client.stopDesktop(attached) }
            return
        }
        if info.failure != nil {
            throw RemoteAttachError.rejected(info.message ?? "Mac 拒绝了远程桌面请求")
        }
        self.info = info
        attachment = attached
        receiver.attach(link: attached.link, channel: attached.channel, generation: current)
        state = .streaming
        // 后台里重连上的（一般是回前台前最后那几秒）：新流照样请 Mac 停下，别在没人看时推满码率。
        if backgrounded { sendPause(true) }
    }

    private func clipboardArrived(_ content: RemoteDesktopClipboard, generation arrived: Int) {
        guard arrived == generation, !isStopped else { return }
        onClipboard?(content)
    }

    private func channelClosed(generation closed: Int, reason: String, ended: Bool) {
        guard closed == generation, !isStopped else { return }
        attachment = nil
        receiver.detach()
        if ended {
            state = .ended(reason.isEmpty ? "远程桌面已结束" : reason)
            return
        }
        state = .reconnecting(reason)
        guard reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in await self?.reconnectLoop() }
    }

    /// 连接断了：退避重连。重开的流第一帧就是关键帧，画面自然接上。App 在后台时任务被挂起，
    /// 回到前台自然继续。
    private func reconnectLoop() async {
        var delay: Duration = .milliseconds(300)
        while !Task.isCancelled && !isStopped {
            if await client.retryGate.wait(delay) { delay = .milliseconds(300) }
            guard !Task.isCancelled, !isStopped else { break }
            do {
                try await open()
                break
            } catch RemoteAttachError.rejected(let message) {
                state = .failed(message)
                break
            } catch RemoteDesktopError.macTooOld {
                state = .unsupported
                break
            } catch {
                state = .reconnecting(error.localizedDescription)
                delay = min(delay * 2, .seconds(4))
            }
        }
        reconnectTask = nil
    }

    // MARK: - 输入与控制

    /// 发一次输入（任意线程可调的连接发送，这里只取当前通道）。
    func send(_ input: RemoteDesktopInput) {
        guard let attachment, canControl else { return }
        attachment.link.send(RemoteMessage(.desktopInput, channel: attachment.channel, payload: input.encoded()))
    }

    /// 能不能把手机上的图片 / 文字粘贴过去：有控制权，且 Mac 认得粘贴消息。
    var canPaste: Bool { canControl && client.supportsDesktopPaste }

    /// 把一张图片或一段文字粘贴进 Mac 当前的前台 app（Mac 写剪贴板后按 ⌘V）。
    func paste(_ content: RemoteDesktopPaste) {
        guard let attachment, canPaste else { return }
        if pasteUploader?.isFor(link: attachment.link, channel: attachment.channel) != true {
            pasteUploader = RemoteDesktopPasteUploader(link: attachment.link, channel: attachment.channel,
                                                       supportsChunks: client.supportsDesktopPasteChunks)
        }
        pasteUploader?.enqueue(content.encoded())
    }

    /// App 退到后台 / 回到前台。后台时画面没人看（显示层也不出图）。
    ///
    /// - 新 Mac（认得 `desktopPause`）：请它停止推流——iOS 给的约 30 s 后台时间里不再收满码率的帧，省电省射频；
    ///   回前台发「恢复」，Mac 恢复时自带关键帧。
    /// - 老 Mac：发了会被当未知消息断开整条连接，所以不发，Mac 照旧推流；接收端照收照确认、不解码不渲染，
    ///   回前台另要一个关键帧。见 `RemoteDesktopReceiver.setPaused`。
    ///
    /// 新 Mac 也同样让接收端暂停：暂停消息到达之前已在路上的帧照样只回确认、不解码。
    /// 回前台（包括从 inactive 回来）总会拿到一个关键帧，与改动前每次回前台都要关键帧的行为一致。
    func setBackgrounded(_ backgrounded: Bool) {
        self.backgrounded = backgrounded
        receiver.setPaused(backgrounded)
        if backgrounded {
            sendPause(true)
        } else if !sendPause(false) {
            requestKeyframe()
        }
    }

    /// 发暂停 / 恢复。没有流（重连中）或 Mac 不认得时返回 false。
    @discardableResult
    private func sendPause(_ paused: Bool) -> Bool {
        guard let attachment, client.supportsDesktopPause else { return false }
        attachment.link.send(RemoteMessage(.desktopPause, channel: attachment.channel,
                                           payload: RemoteJSON.encode(RemoteDesktopPauseRequest(paused: paused))))
        return true
    }

    /// 回到前台等场合主动要一个关键帧（解码出错时接收端会自己要）。
    func requestKeyframe() {
        receiver.requestKeyframe(force: true)
    }

    /// 用密码解锁 Mac 的锁屏。密码来自手机本机钥匙串（Face ID 取出），只经加密信道发一次。
    func unlock(password: String) async -> RemoteDesktopUnlockResult.Outcome {
        guard let attachment, supportsUnlock else { return .notAllowed }
        let requestID = UUID()
        let request = RemoteDesktopUnlockRequest(requestID: requestID, password: password)
        attachment.link.send(RemoteMessage(.desktopUnlock, channel: attachment.channel, payload: RemoteJSON.encode(request)))
        return await withCheckedContinuation { continuation in
            unlockWaiters[requestID] = continuation
            // Mac 解锁要走输入+轮询，给足够时间；超时当失败处理。
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                self?.unlockWaiters.removeValue(forKey: requestID)?.resume(returning: .timedOut)
            }
        }
    }

    /// 开 / 关帘幕（手机顶栏手动控制）。
    func setCurtain(_ on: Bool) {
        guard let attachment, supportsUnlock else { return }
        let request = RemoteDesktopCurtainRequest(on: on)
        attachment.link.send(RemoteMessage(.desktopCurtain, channel: attachment.channel, payload: RemoteJSON.encode(request)))
    }

    private func unlockResultArrived(_ result: RemoteDesktopUnlockResult) {
        unlockWaiters.removeValue(forKey: result.requestID)?.resume(returning: result.outcome)
    }

    private func startStatsTicker() {
        statsTask?.cancel()
        let receiver = self.receiver
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                // 失败 / 结束 / Mac 太旧：没有流了，不再每秒醒一次。重试走 `start()`，会重新起这个计时。
                if self.state.isTerminal { return }
                let snapshot = receiver.stats.snapshot()
                let latency = receiver.latestLatency
                // 读数没变（画面静止、连接中）就不写：`@Observable` 每次赋值都通知，读着它的界面会白白重算。
                if self.stats != snapshot { self.stats = snapshot }
                if self.latency != latency { self.latency = latency }
            }
        }
    }
}

/// 接收端的读数（解码队列上累加，主线程每秒取一次）。
nonisolated final class RemoteDesktopReceiverStats: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var framesPerSecond: Double = 0
        var megabitsPerSecond: Double = 0
        var decodeMillis: Double = 0
        var decodeFailures = 0
        var totalFrames = 0
        /// 等到时限也没收齐的帧。
        var lostFrames = 0
        /// 等恢复帧期间跳过的帧。
        var skippedFrames = 0
    }

    private let lock = NSLock()
    private var frames = 0
    private var bytes = 0
    private var decodeNanos: UInt64 = 0
    private var failures = 0
    private var total = 0
    private var lost = 0
    private var skipped = 0
    private var windowStart = DispatchTime.now().uptimeNanoseconds

    func record(bytes count: Int, decodeNanos nanos: UInt64, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        frames += 1
        total += 1
        bytes += count
        decodeNanos += nanos
        if failed { failures += 1 }
    }

    func recordLost(_ count: Int) { lock.lock(); lost += count; lock.unlock() }
    func recordSkipped() { lock.lock(); skipped += 1; lock.unlock() }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        let seconds = max(0.001, Double(now - windowStart) / 1e9)
        let result = Snapshot(framesPerSecond: Double(frames) / seconds,
                              megabitsPerSecond: Double(bytes) * 8 / seconds / 1e6,
                              decodeMillis: frames > 0 ? Double(decodeNanos) / Double(frames) / 1e6 : 0,
                              decodeFailures: failures, totalFrames: total, lostFrames: lost, skippedFrames: skipped)
        frames = 0
        bytes = 0
        decodeNanos = 0
        windowStart = now
        return result
    }
}

/// 视频帧的接收、解码与确认，全在后台队列上。
///
/// 每收到一帧都回确认（解码失败、等关键帧跳过的也回），Mac 的在途计数靠它释放。
/// 解码失败时向 Mac 要关键帧（限频），在关键帧到来之前的 P 帧直接跳过，不往屏幕上送花屏。
/// 旁路精修帧（`.sidecar`）走另一个解码器：它不在主流的参考链里，解坏了也只是少一次精修，不要关键帧。
nonisolated final class RemoteDesktopReceiver: @unchecked Sendable {
    /// 两次关键帧请求的最短间隔：解码错一次通常连着错到下一个关键帧，不必每帧都要。
    static let keyframeRequestSpacing: UInt64 = 500_000_000

    let stats = RemoteDesktopReceiverStats()
    private let decodeQueue = DispatchQueue(label: "com.uozi.uTerm.remote.desktop.decode", qos: .userInteractive)
    private let decoder: RemoteVideoDecoder
    private let stillDecoder: RemoteVideoDecoder
    private let lock = NSLock()
    private var link: RemoteLink?
    private var channel: UInt32 = 0
    private var generation = 0
    private var lastKeyframeRequest: UInt64 = 0
    private var onImage: (@Sendable (CVPixelBuffer, RemoteDesktopFrame) -> Void)?
    private var onCursor: (@Sendable (RemoteDesktopCursor) -> Void)?
    private var latestLatencyValue: RemoteDesktopLatency?
    /// App 在后台：帧照收照确认，但不解码、不渲染（见 `setPaused`）。
    private var paused = false

    /// Mac 最近报的画面往返。
    var latestLatency: RemoteDesktopLatency? {
        lock.lock(); defer { lock.unlock() }
        return latestLatencyValue
    }
    private var video: (any RemoteVideoDatagramChannel)?
    // 以下只在解码队列上。
    /// 参考链断了，在等恢复帧（关键帧或 LTR 刷新帧）。
    private var recovering = false
    private var recoveringSince: UInt64 = 0
    /// 暂停期间跳过过帧：解码器的参考链已经断了，恢复后要等关键帧。
    private var skippedWhilePaused = false

    /// 等恢复帧这么久还没来，再催一次。恢复帧自己也可能丢。
    static let recoveryRetryNanos: UInt64 = 500_000_000

    init(outputPixelFormat: OSType) {
        decoder = RemoteVideoDecoder(outputPixelFormat: outputPixelFormat)
        stillDecoder = RemoteVideoDecoder(outputPixelFormat: outputPixelFormat)
    }

    /// 渲染回调在解码队列上调用（`AVSampleBufferDisplayLayer` 可以在任意线程 enqueue）。
    func setHandlers(onImage: (@Sendable (CVPixelBuffer, RemoteDesktopFrame) -> Void)?,
                     onCursor: (@Sendable (RemoteDesktopCursor) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.onImage = onImage
        self.onCursor = onCursor
    }

    /// App 退到后台时暂停解码，回前台恢复。
    ///
    /// 后台时屏幕上看不见画面，解码、往显示层送帧都是白耗电；iOS 还会在后台收走硬解会话，每帧解码失败 →
    /// 回「失败」确认 → Mac 每帧都补关键帧，链路上全是大帧。暂停期间每帧照常回确认（不报失败），Mac 的
    /// 在途计数与码控看到的是一条正常的流：不会因为「没确认 / 丢帧」降码率，回前台画质不用重新爬升。
    /// 恢复后第一帧前把解码器标成「参考断了」，P 帧跳过、等关键帧（调用方同时会要一个）。
    func setPaused(_ paused: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.paused = paused
    }

    /// 新开一条流之前：换代，旧流迟到的帧不再处理；解码器回到「等关键帧」。
    func reset(generation: Int) {
        lock.lock()
        self.generation = generation
        link = nil
        lock.unlock()
        decodeQueue.async {
            self.decoder.invalidate()
            self.stillDecoder.invalidate()
            self.recovering = false
        }
    }

    /// 视频从数据报通道来。要在开流之前调用：第一帧可能比开流回复先到。
    func attachVideo(_ channel: any RemoteVideoDatagramChannel, link: RemoteLink, generation: Int) {
        lock.lock()
        video = channel
        lock.unlock()
        channel.startVideoReceiving(onFrame: { [weak self] payload, desktopChannel in
            guard let self else { return }
            self.decodeQueue.async {
                self.decode(payload, channel: desktopChannel, link: link, generation: generation)
            }
        }, onLost: { [weak self] videoSequences, desktopChannel in
            guard let self else { return }
            self.decodeQueue.async {
                self.videoLost(videoSequences, channel: desktopChannel, link: link, generation: generation)
            }
        })
    }

    /// 有帧放弃了：参考链断了。告诉 Mac，之后的帧都跳过，直到恢复帧来。
    private func videoLost(_ videoSequences: [UInt32], channel: UInt32, link: RemoteLink, generation: Int) {
        lock.lock()
        let current = generation == self.generation
        lock.unlock()
        guard current else { return }
        decoder.markReferenceLost()
        if !recovering {
            recovering = true
            recoveringSince = DispatchTime.now().uptimeNanoseconds
        }
        stats.recordLost(videoSequences.count)
        link.send(RemoteMessage(.desktopVideoLost, channel: channel,
                                payload: RemoteDesktopVideoLost(videoSequences: videoSequences).encoded()))
    }

    func attach(link: RemoteLink, channel: UInt32, generation: Int) {
        lock.lock(); defer { lock.unlock() }
        guard generation == self.generation else { return }
        self.link = link
        self.channel = channel
    }

    func detach() {
        lock.lock(); defer { lock.unlock() }
        link = nil
        video?.stopVideoReceiving()
        video = nil
    }

    /// 连接队列上调用。`link` 是消息来的那条连接：开流的第一帧（关键帧）可能先于 `attach` 到达，
    /// 确认照样要回，所以不依赖 `attach`。
    func receive(_ message: RemoteMessage, from link: RemoteLink, generation: Int) {
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            return
        }
        if self.link == nil {
            self.link = link
            channel = message.channel
        }
        lock.unlock()
        switch message.kind {
        case .desktopCursor:
            guard let cursor = try? RemoteDesktopCursor(decoding: message.payload) else { return }
            lock.lock(); let handler = onCursor; lock.unlock()
            handler?(cursor)
        case .desktopFrame:
            let payload = message.payload
            let channel = message.channel
            decodeQueue.async { self.decode(payload, channel: channel, link: link, generation: generation) }
        case .desktopLatency:
            guard let latency = try? JSONDecoder().decode(RemoteDesktopLatency.self, from: message.payload) else { return }
            lock.lock(); latestLatencyValue = latency; lock.unlock()
        default:
            break
        }
    }

    private func decode(_ payload: Data, channel: UInt32, link: RemoteLink, generation: Int) {
        lock.lock()
        let current = generation == self.generation
        let handler = onImage
        let paused = self.paused
        lock.unlock()
        guard current, let frame = try? RemoteDesktopFrame(decoding: payload) else { return }
        // 后台暂停：只回确认（不报失败、不带 LTR 令牌——没解过），不解码不渲染。
        if paused {
            skippedWhilePaused = true
            link.send(RemoteMessage(.desktopAck, channel: channel, payload: RemoteDesktopAck(
                sequence: frame.sequence, captureNanos: frame.captureNanos, decodeMicros: 0).encoded()))
            stats.recordSkipped()
            return
        }
        if skippedWhilePaused {
            skippedWhilePaused = false
            decoder.markReferenceLost()
        }
        let sidecar = frame.flags.contains(.sidecar)
        let start = DispatchTime.now().uptimeNanoseconds
        // 在等恢复帧：这一帧的参考没了，不能喂给解码器。确认照发，Mac 的在途计数靠它释放。
        if recovering, !sidecar, !frame.isKeyframe, !frame.flags.contains(.ltrRefresh) {
            link.send(RemoteMessage(.desktopAck, channel: channel, payload: RemoteDesktopAck(
                sequence: frame.sequence, captureNanos: frame.captureNanos, decodeMicros: 0).encoded()))
            stats.recordSkipped()
            if start &- recoveringSince >= Self.recoveryRetryNanos {
                recoveringSince = start
                link.send(RemoteMessage(.desktopVideoLost, channel: channel,
                                        payload: RemoteDesktopVideoLost(videoSequences: []).encoded()))
            }
            return
        }
        let image = try? (sidecar ? stillDecoder : decoder).decode(frame)
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        // 先确认再渲染：确认决定 Mac 什么时候编下一帧，越早发出去链路越满。
        // 旁路帧解坏了不报失败：Mac 收到失败会给主流补关键帧，而主流没出问题。
        let ack = RemoteDesktopAck(sequence: frame.sequence, captureNanos: frame.captureNanos,
                                   decodeMicros: UInt32(min(UInt64(UInt32.max), elapsed / 1000)),
                                   failed: image == nil && !sidecar, ltrToken: image != nil ? frame.ltrToken : nil)
        if image != nil, !sidecar { recovering = false }
        // 确认发回帧来的那条连接。
        link.send(RemoteMessage(.desktopAck, channel: channel, payload: ack.encoded()))
        stats.record(bytes: payload.count, decodeNanos: elapsed, failed: image == nil)
        if let image {
            handler?(image, frame)
        } else if !sidecar {
            requestKeyframe(force: false)
        }
    }

    /// 向 Mac 要关键帧。`force` = 不受限频约束（回到前台这类明确的时刻）。
    func requestKeyframe(force: Bool) {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        guard let link, force || now &- lastKeyframeRequest >= Self.keyframeRequestSpacing else {
            lock.unlock()
            return
        }
        lastKeyframeRequest = now
        let channel = self.channel
        lock.unlock()
        link.send(RemoteMessage(.desktopKeyframe, channel: channel))
    }
}
