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
    }

    private(set) var state: State = .idle
    /// 最近一次开流成功时 Mac 报的信息（显示器尺寸、能不能控制）。
    private(set) var info: RemoteDesktopInfo?
    /// 每秒刷新一次的读数（帧率、码率、解码耗时），给界面上的小字用。
    private(set) var stats = RemoteDesktopReceiverStats.Snapshot()

    nonisolated let receiver: RemoteDesktopReceiver
    let client: RemoteMacClient
    private let codec: RemoteVideoCodec
    private let maxWidth: Int
    private let maxHeight: Int
    @ObservationIgnored private var attachment: RemoteAttachment?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - maxWidth/maxHeight: 想要的视频最大像素（与方向无关，Mac 按显示器的横竖套）。
    ///   - outputPixelFormat: 解出来的像素格式（显示用 4:2:0，测试比对用 BGRA）。
    init(client: RemoteMacClient, maxWidth: Int, maxHeight: Int, codec: RemoteVideoCodec = .hevc,
         outputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        self.client = client
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
            onMessage: { message, link in receiver.receive(message, from: link, generation: current) }
        )
        let request = RemoteDesktopStartRequest(requestID: UUID(), maxWidth: maxWidth, maxHeight: maxHeight, codec: codec)
        let (attached, info) = try await client.startDesktop(request, sink: sink)
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
        attachment.link.send(RemoteMessage(.desktopPaste, channel: attachment.channel, payload: content.encoded()))
    }

    /// 回到前台等场合主动要一个关键帧（解码出错时接收端会自己要）。
    func requestKeyframe() {
        receiver.requestKeyframe(force: true)
    }

    private func startStatsTicker() {
        statsTask?.cancel()
        let receiver = self.receiver
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let snapshot = receiver.stats.snapshot()
                guard let self else { return }
                self.stats = snapshot
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
    }

    private let lock = NSLock()
    private var frames = 0
    private var bytes = 0
    private var decodeNanos: UInt64 = 0
    private var failures = 0
    private var total = 0
    private var windowStart = DispatchTime.now().uptimeNanoseconds

    func record(bytes count: Int, decodeNanos nanos: UInt64, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        frames += 1
        total += 1
        bytes += count
        decodeNanos += nanos
        if failed { failures += 1 }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        let seconds = max(0.001, Double(now - windowStart) / 1e9)
        let result = Snapshot(framesPerSecond: Double(frames) / seconds,
                              megabitsPerSecond: Double(bytes) * 8 / seconds / 1e6,
                              decodeMillis: frames > 0 ? Double(decodeNanos) / Double(frames) / 1e6 : 0,
                              decodeFailures: failures, totalFrames: total)
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
nonisolated final class RemoteDesktopReceiver: @unchecked Sendable {
    /// 两次关键帧请求的最短间隔：解码错一次通常连着错到下一个关键帧，不必每帧都要。
    static let keyframeRequestSpacing: UInt64 = 500_000_000

    let stats = RemoteDesktopReceiverStats()
    private let decodeQueue = DispatchQueue(label: "com.uozi.uTerm.remote.desktop.decode", qos: .userInteractive)
    private let decoder: RemoteVideoDecoder
    private let lock = NSLock()
    private var link: RemoteLink?
    private var channel: UInt32 = 0
    private var generation = 0
    private var lastKeyframeRequest: UInt64 = 0
    private var onImage: (@Sendable (CVPixelBuffer, RemoteDesktopFrame) -> Void)?
    private var onCursor: (@Sendable (RemoteDesktopCursor) -> Void)?

    init(outputPixelFormat: OSType) {
        decoder = RemoteVideoDecoder(outputPixelFormat: outputPixelFormat)
    }

    /// 渲染回调在解码队列上调用（`AVSampleBufferDisplayLayer` 可以在任意线程 enqueue）。
    func setHandlers(onImage: (@Sendable (CVPixelBuffer, RemoteDesktopFrame) -> Void)?,
                     onCursor: (@Sendable (RemoteDesktopCursor) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        self.onImage = onImage
        self.onCursor = onCursor
    }

    /// 新开一条流之前：换代，旧流迟到的帧不再处理；解码器回到「等关键帧」。
    func reset(generation: Int) {
        lock.lock()
        self.generation = generation
        link = nil
        lock.unlock()
        decodeQueue.async { self.decoder.invalidate() }
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
        default:
            break
        }
    }

    private func decode(_ payload: Data, channel: UInt32, link: RemoteLink, generation: Int) {
        lock.lock()
        let current = generation == self.generation
        let handler = onImage
        lock.unlock()
        guard current, let frame = try? RemoteDesktopFrame(decoding: payload) else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        var image: CVPixelBuffer?
        do {
            image = try decoder.decode(frame)
        } catch {
            image = nil
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        // 先确认再渲染：确认决定 Mac 什么时候编下一帧，越早发出去链路越满。
        let ack = RemoteDesktopAck(sequence: frame.sequence, captureNanos: frame.captureNanos,
                                   decodeMicros: UInt32(min(UInt64(UInt32.max), elapsed / 1000)), failed: image == nil)
        // 确认发回帧来的那条连接。
        link.send(RemoteMessage(.desktopAck, channel: channel, payload: ack.encoded()))
        stats.record(bytes: payload.count, decodeNanos: elapsed, failed: image == nil)
        if let image {
            handler?(image, frame)
        } else {
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
