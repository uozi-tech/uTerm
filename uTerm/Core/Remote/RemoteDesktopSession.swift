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
    /// 开流成功了、第一帧还没解出来（界面上显示「正在等待画面」，不是一片黑）。
    private(set) var awaitingFirstFrame = false
    /// 第一次打开失败后正在自动重试：界面显示「正在重试」与上次的原因，而不是失败页。
    private(set) var retryReason: String?
    /// 连接中界面上的一行进度：还在建连时用连接的进度，连上之后是开流的进度。
    var progress: String? {
        if let stage = client.connectStage { return stage.progress }
        if state == .connecting { return RemoteConnectStage.desktopStart.progress }
        if awaitingFirstFrame { return RemoteConnectStage.firstFrame.progress }
        return nil
    }
    /// 正在开的这一路流的时间线（请求、回复、第一帧）。
    @ObservationIgnored private var openTrace: RemoteConnectTrace?
    @ObservationIgnored private var openAttempt = 0
    /// 最近一次开流成功时 Mac 报的信息（显示器尺寸、能不能控制）。
    private(set) var info: RemoteDesktopInfo?
    /// 每秒刷新一次的读数（帧率、码率、解码耗时），给界面上的小字用。
    private(set) var stats = RemoteDesktopReceiverStats.Snapshot()
    /// Mac 上拷贝的文字回传过来了（手机控制桌面时，Mac 认得 `desktopClipboard` 才会发）。界面在这里写系统
    /// 剪贴板并提示；共享目录里不碰 `UIPasteboard`，Mac 单测才能端到端驱动。
    @ObservationIgnored var onClipboard: (@MainActor (RemoteDesktopClipboard) -> Void)?
    /// 用户点开屏幕的时刻。第一次开流时记进时间线：「点按钮 → 开流」这段界面上的等待不在开屏时间线里。
    @ObservationIgnored var openRequestedAt: ContinuousClock.Instant?
    /// Mac 报来的画面往返（≈ 一次操作到看见结果）；老 Mac 不报，一直是 nil。
    private(set) var latency: RemoteDesktopLatency?
    /// Mac 的锁屏 / 帘幕状态（支持远程解锁的 Mac 才发）。
    private(set) var screen = RemoteDesktopScreenState(locked: false, curtained: false, unlockAvailable: false)
    /// 这台 Mac 支持远程解锁（能收到锁屏状态、能发解锁请求）。
    var supportsUnlock: Bool { client.supportsUnlock }

    /// 声音（调研 §17）。
    enum AudioState: Equatable {
        case off
        /// 已经请求，等 Mac 回格式。
        case starting
        case playing
        /// Mac 没开开关、采集停了、耳机拔了……附带原因。按钮复位为关。
        case unavailable(String)
    }
    private(set) var audioState: AudioState = .off
    /// 这台 Mac 能传声音。
    var supportsAudio: Bool { client.supportsDesktopAudio }
    /// 每秒刷新一次的声音读数（调试信息用）。
    private(set) var audioStats = RemoteAudioReceiver.Snapshot()
    @ObservationIgnored private var wantsAudio = false
    @ObservationIgnored private let audioOutput: (any RemoteAudioOutput)?
    @ObservationIgnored private var audioPlaying = false
    nonisolated let audioReceiver: RemoteAudioReceiver
    @ObservationIgnored private var unlockWaiters: [UUID: CheckedContinuation<RemoteDesktopUnlockResult.Outcome, Never>] = [:]

    nonisolated let receiver: RemoteDesktopReceiver
    let client: RemoteMacClient
    private let codec: RemoteVideoCodec
    private var maxWidth: Int
    private var maxHeight: Int
    /// 本机每个点几个像素（见 `RemoteDesktopStartRequest.pointScale`）。
    private let pointScale: Double?
    /// 要看的显示器（nil = 那台 Mac 的主显示器）。`switchDisplay` 改它再重开流。
    private(set) var displayID: UInt32?
    /// 只看这一个窗口（nil = 整块显示器）。`switchWindow` 改它再重开流。
    private(set) var windowID: UInt32?
    /// 只看一个窗口时，请 Mac 先把窗口调成这么大（点）。nil = 不动窗口。
    private(set) var windowFit: CGSize?
    /// 只看一个窗口时，内容占视频帧的比例（从左上角算）：窗口改了大小、菜单伸出窗口后，视频帧的右边或下边会空出来，
    /// 画布把空的那截裁掉。整块显示器时恒为 1。
    private(set) var contentFraction = CGSize(width: 1, height: 1)
    /// 要不要光标形状（Mac 主控端要，拿它当本机光标；手机自己画箭头，不要）。
    private let wantsCursorImages: Bool
    /// Mac 报来的光标此刻的样子（开流时要了才有）。
    private(set) var cursorImage: RemoteDesktopCursorImage?
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
    ///   - pointScale: 本机每个点几个像素；无显示器的 Mac 据此定虚拟屏的点数。nil = 不报（被控端按老规则）。
    ///   - outputPixelFormat: 解出来的像素格式。nil = 按码流位深出 4:2:0（Main10 出 10-bit）；测试比对用 BGRA。
    ///   - audioOutput: 声音放到哪里。nil = 系统扬声器（`RemoteAudioEnginePlayer`）；Mac 单测传一个不出声的。
    init(client: RemoteMacClient, maxWidth: Int, maxHeight: Int, pointScale: Double? = nil,
         codec: RemoteVideoCodec = .hevc, outputPixelFormat: OSType? = nil, displayID: UInt32? = nil,
         cursorImages: Bool = false, audioOutput: (any RemoteAudioOutput)? = nil) {
        self.client = client
        self.pointScale = pointScale
        self.displayID = displayID
        self.wantsCursorImages = cursorImages
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.codec = codec
        receiver = RemoteDesktopReceiver(outputPixelFormat: outputPixelFormat)
        // 直连的抖动小；TCP 中继上关键帧前后包会成串晚到，起步缓深一些。
        audioReceiver = RemoteAudioReceiver(config: client.path == .relay ? .relay : .direct)
        self.audioOutput = audioOutput ?? RemoteAudioEnginePlayer()
    }

    /// 改要的尺寸：下一次开流（第一次、手动重试、重连）按它要，已经在放的流不动。手机要等顶栏和屏幕圆角
    /// 量出来才知道画布多大（`RemoteDesktopRequestSize`），会话可能已经在建连了。
    func setRequestedSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        maxWidth = width
        maxHeight = height
    }

    var canControl: Bool { info?.canControl ?? false }

    // MARK: - 起停

    /// 打开屏幕。网络原因失败时自动再试两次（间隔同 `RemoteMacClient.connectInteractively`），
    /// 期间停在「正在连接」并显示上次的原因；Mac 明确拒绝、版本太旧、配对被拒时不重试。
    func start() async {
        isStopped = false
        reconnectTask?.cancel()
        reconnectTask = nil
        state = .connecting
        retryReason = nil
        openAttempt = 0
        startStatsTicker()
        var delays = RemoteMacClient.interactiveRetryDelays[...]
        while !isStopped {
            do {
                try await open()
                retryReason = nil
                return
            } catch RemoteDesktopError.macTooOld {
                state = .unsupported
            } catch RemoteAttachError.rejected(let message) {
                if !isStopped { state = .failed(message) }
            } catch {
                guard !isStopped else { break }
                if client.canAutoReconnect, let delay = delays.popFirst() {
                    retryReason = error.localizedDescription
                    AppLogger.notice("打开 \(self.client.macName) 的屏幕失败（\(error.localizedDescription)），自动重试",
                                     category: RemoteLog.category)
                    _ = await client.retryGate.wait(delay)
                    continue
                }
                state = .failed(error.localizedDescription)
            }
            break
        }
        retryReason = nil
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        finishOpenTrace(ok: false, outcome: String(localized: "已关闭"))
        attachment?.link.expectSteadyTraffic(false)
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
        stopAudioPlayback()
        audioReceiver.reset()
        state = .idle
    }

    /// 换一块显示器看：停掉当前这路，按新的 id 重开（Mac 那边换采集源与注入坐标系）。
    func switchDisplay(to id: UInt32) async {
        guard id != info?.displayID || windowID != nil else { return }
        displayID = id
        windowID = nil
        windowFit = nil
        stop()
        await start()
    }

    /// 只看一个窗口（`id` 取自 `client.desktopWindows()`），或回到整块显示器（nil）。和换显示器一样重开流。
    ///
    /// `fit`：请 Mac 先把窗口调成这么大（点，一般是本机画布的点尺寸），窗口里的内容按它重排；流结束后 Mac 把窗口
    /// 还原。nil = 不动窗口。
    func switchWindow(to id: UInt32?, fit: CGSize? = nil) async {
        let fit = id == nil ? nil : fit
        guard id != windowID || fit != windowFit else { return }
        windowID = id
        windowFit = fit
        stop()
        await start()
    }

    /// 画布大小变了（转屏、折叠屏开合）：正在看一个调过大小的窗口时，按新的画布再调一次。差不到 8 点不动。
    func refitWindow(to size: CGSize) async {
        guard windowID != nil, let current = windowFit, size.width > 0, size.height > 0,
              abs(current.width - size.width) >= 8 || abs(current.height - size.height) >= 8 else { return }
        await switchWindow(to: windowID, fit: size)
    }

    /// 那台 Mac 的 uTerm 支不支持只看一个窗口。
    var supportsWindows: Bool { client.supportsDesktopWindows }

    /// 画面放大了，此刻只看得见这一块（归一化，相对被看的那块显示器或窗口）；nil = 没放大。Mac 改成只取这一块、
    /// 按原生像素给，放大后的字才是锐的。和上次发的一样就不重发；流重开后自动补发。老 Mac 不支持，什么都不做。
    func requestRegion(_ visible: RemoteDesktopRegion?) {
        wantedRegion = visible
        sendWantedRegion()
    }

    /// 那台 Mac 的 uTerm 支不支持放大后按区域取画面。
    var supportsRegions: Bool { client.supportsDesktopRegion }

    private func sendWantedRegion() {
        guard client.supportsDesktopRegion, state == .streaming, let attachment, wantedRegion != sentRegion else { return }
        sentRegion = wantedRegion
        attachment.link.send(RemoteMessage(.desktopRegion, channel: attachment.channel,
                                           payload: RemoteJSON.encode(RemoteDesktopRegionRequest(visible: wantedRegion))))
    }

    /// 开一条流。失败（Mac 拒绝）抛 `RemoteAttachError.rejected`。
    private func open() async throws {
        generation += 1
        let current = generation
        openAttempt += 1
        finishOpenTrace(ok: false, outcome: String(localized: "被新的请求取代"))
        let trace = RemoteConnectTrace(kind: .desktop, macName: client.macName, attempt: openAttempt)
        openTrace = trace
        trace.setNetwork(client.path?.label ?? String(localized: "未连接"))
        if let tapped = openRequestedAt {
            openRequestedAt = nil
            trace.event("点开屏幕之后 \(RemoteConnectTrace.millis(ContinuousClock.now - tapped)) ms 才开流")
        }
        awaitingFirstFrame = false
        contentFraction = CGSize(width: 1, height: 1)
        pendingGeometry = nil
        sentRegion = nil
        receiver.expectFirstImage(trace: trace) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.firstImageArrived(generation: current) }
            }
        }
        let receiver = self.receiver
        receiver.reset(generation: current)
        let audioReceiver = self.audioReceiver
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
                case .desktopCursorImage:
                    guard let image = try? RemoteJSON.decode(RemoteDesktopCursorImage.self, from: message.payload) else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, current == self.generation else { return }
                            self.cursorImage = image
                        }
                    }
                case .desktopUnlockResult:
                    guard let result = try? RemoteJSON.decode(RemoteDesktopUnlockResult.self, from: message.payload) else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.unlockResultArrived(result) } }
                case .desktopGeometry:
                    guard let update = try? RemoteJSON.decode(RemoteDesktopGeometryUpdate.self, from: message.payload) else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.geometryArrived(update, generation: current) }
                    }
                case .desktopAudioFrame:
                    audioReceiver.receive(frame: message.payload)
                case .desktopAudioFormat:
                    guard let format = try? RemoteJSON.decode(RemoteDesktopAudioFormat.self, from: message.payload) else { return }
                    audioReceiver.receive(format: format)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.audioFormatArrived(format, generation: current) }
                    }
                default:
                    receiver.receive(message, from: link, generation: current)
                }
            }
        )
        let request = RemoteDesktopStartRequest(requestID: UUID(), maxWidth: maxWidth, maxHeight: maxHeight, codec: codec,
                                                displayID: displayID, sidecarRefine: true, latencyStats: true,
                                                cursorImages: wantsCursorImages ? true : nil, pointScale: pointScale,
                                                windowID: client.supportsDesktopWindows ? windowID : nil,
                                                windowFit: client.supportsDesktopWindows && windowID != nil
                                                    ? windowFit.map { RemoteDesktopFit(width: $0.width, height: $0.height) } : nil)
        let wasConnected = client.state == .connected
        let startStep = trace.begin(.desktopStart, detail: wasConnected ? nil : String(localized: "含建连"))
        let attached: RemoteAttachment
        let info: RemoteDesktopInfo
        do {
            (attached, info) = try await client.startDesktop(request, sink: sink, prepareVideo: { video, link in
                receiver.attachVideo(video, link: link, generation: current)
                // 视频走数据报时声音也走数据报（Mac 那边同样按这条路选）。
                video.startAudioReceiving { payload, _ in audioReceiver.receive(frame: payload) }
            })
        } catch {
            trace.end(startStep, ok: false, detail: error.localizedDescription)
            finishOpenTrace(ok: false, outcome: error.localizedDescription)
            throw error
        }
        trace.end(startStep, ok: info.failure == nil, detail: client.path?.label)
        guard current == generation, !isStopped else {
            if info.failure == nil { client.stopDesktop(attached) }
            return
        }
        if info.failure != nil {
            let message = info.message ?? "Mac 拒绝了远程桌面请求"
            finishOpenTrace(ok: false, outcome: message)
            throw RemoteAttachError.rejected(message)
        }
        if firstImageGeneration == current {
            // 第一帧比开流回复先到（数据报视频）：画面已经有了。
            trace.end(trace.begin(.firstFrame), ok: true)
            finishOpenTrace(ok: true, outcome: client.path?.label ?? "")
        } else {
            firstFrameStep = trace.begin(.firstFrame)
            awaitingFirstFrame = true
        }
        self.info = info
        applyPendingGeometry()
        attachment = attached
        receiver.attach(link: attached.link, channel: attached.channel, generation: current)
        // 流在走、有人在看：静默断开几秒内就要发现（见 `RemoteLink.expectSteadyTraffic`）。
        attached.link.expectSteadyTraffic(!backgrounded)
        state = .streaming
        // 开流前画布就放大着（重连、换显示器）：新的流从整块起步，把想要的那一块补发过去。
        sendWantedRegion()
        // 后台里重连上的（一般是回前台前最后那几秒）：新流照样请 Mac 停下，别在没人看时推满码率。
        if backgrounded { sendPause(true) }
        // 重连后重新要声音：Mac 那边的声音流随旧的桌面流一起结束了。第一次开流时，上次看这台 Mac 开着声音就照样打开。
        if wantsAudio { requestAudio(true) } else { restoreAudioIfWanted() }
    }

    /// 只看一个窗口时画面对应的范围变了：点尺寸换掉（画布的比例与「1 点多大」跟着变），占比交给画布裁切。
    /// 几何可能比开流回复先到（`info` 还没有）：先记着，`open` 收到回复后套上。
    private func geometryArrived(_ update: RemoteDesktopGeometryUpdate, generation arrived: Int) {
        guard arrived == generation, !isStopped, update.width > 0, update.height > 0,
              update.contentWidth > 0, update.contentHeight > 0 else { return }
        pendingGeometry = update
        applyPendingGeometry()
    }

    private func applyPendingGeometry() {
        guard let update = pendingGeometry, info != nil else { return }
        pendingGeometry = nil
        info?.displayWidth = update.width
        info?.displayHeight = update.height
        contentFraction = CGSize(width: min(1, update.contentWidth), height: min(1, update.contentHeight))
    }

    @ObservationIgnored private var pendingGeometry: RemoteDesktopGeometryUpdate?
    /// 画布此刻想要的那一块，和已经告诉这条流的那一块（新开的流从整块起步）。
    @ObservationIgnored private var wantedRegion: RemoteDesktopRegion?
    @ObservationIgnored private var sentRegion: RemoteDesktopRegion?
    @ObservationIgnored private var firstFrameStep: Int?
    @ObservationIgnored private var firstImageGeneration: Int?

    private func firstImageArrived(generation arrived: Int) {
        guard arrived == generation, !isStopped else { return }
        firstImageGeneration = arrived
        awaitingFirstFrame = false
        guard firstFrameStep != nil else { return }
        if let trace = openTrace, let step = firstFrameStep {
            trace.end(step, ok: true)
        }
        firstFrameStep = nil
        finishOpenTrace(ok: true, outcome: client.path?.label ?? "")
    }

    private func finishOpenTrace(ok: Bool, outcome: String) {
        guard let trace = openTrace else { return }
        openTrace = nil
        firstFrameStep = nil
        trace.finish(ok: ok, outcome: outcome)
    }

    private func clipboardArrived(_ content: RemoteDesktopClipboard, generation arrived: Int) {
        guard arrived == generation, !isStopped else { return }
        onClipboard?(content)
    }

    private func channelClosed(generation closed: Int, reason: String, ended: Bool) {
        guard closed == generation, !isStopped else { return }
        finishOpenTrace(ok: false, outcome: reason)
        awaitingFirstFrame = false
        attachment?.link.expectSteadyTraffic(false)
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
        uploader()?.enqueue(content)
    }

    /// 同上，等内容全部交给链路才返回；发送的进度报给 `PasteProgressReporter`。不能粘贴、半路断开时抛错。
    func pasteAndWait(_ content: RemoteDesktopPaste) async throws {
        guard let uploader = uploader() else { throw RemoteProtocolError.closed }
        let sink = PasteProgressReporter.sink
        let progress: (@Sendable (Int, Int) -> Void)? = sink.map { sink in
            { @Sendable sent, total in sink(PasteProgress.sending(sent, of: total)) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            uploader.enqueue(content, progress: progress) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func uploader() -> RemoteDesktopPasteUploader? {
        guard let attachment, canPaste else { return nil }
        if pasteUploader?.isFor(link: attachment.link, channel: attachment.channel) != true {
            pasteUploader = RemoteDesktopPasteUploader(link: attachment.link, channel: attachment.channel,
                                                       supportsChunks: client.supportsDesktopPasteChunks)
        }
        return pasteUploader
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
        attachment?.link.expectSteadyTraffic(!backgrounded)
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

    // MARK: - 声音

    /// 打开 / 关闭声音（远程桌面工具栏上的扬声器按钮，见 `toggleAudio`）。
    func setAudio(_ on: Bool) {
        guard supportsAudio else { return }
        wantsAudio = on
        if on {
            audioState = .starting
            startAudioPlayback()
        } else {
            audioState = .off
            stopAudioPlayback()
        }
        // 本机播放没能打开时 `startAudioPlayback` 已把 `wantsAudio` 复位：这时不能再叫 Mac 开声音，
        // 不然 Mac 一路采集、编码、发送，手机这头没人放。
        requestAudio(wantsAudio)
    }

    private func requestAudio(_ on: Bool) {
        guard let attachment else { return }
        let request = RemoteDesktopAudioRequest(
            enabled: on, codecs: RemoteDesktopAudioRequest.codecs(lossless: client.supportsDesktopAudioLossless))
        attachment.link.send(RemoteMessage(.desktopAudio, channel: attachment.channel, payload: RemoteJSON.encode(request)))
    }

    private func audioFormatArrived(_ format: RemoteDesktopAudioFormat, generation arrived: Int) {
        guard arrived == generation, !isStopped else { return }
        guard wantsAudio else {
            // 手机已经不要声音了，Mac 却开起了一条（开关交错到达）：叫它停下，免得白白采集、发送。
            if format.codec != nil { requestAudio(false) }
            return
        }
        if format.codec == nil {
            wantsAudio = false
            stopAudioPlayback()
            audioState = .unavailable(format.message ?? "Mac 没有传来声音")
        } else {
            audioState = .playing
        }
    }

    private func startAudioPlayback() {
        guard !audioPlaying, let audioOutput else { return }
        let receiver = audioReceiver
        audioOutput.onInterrupted = { [weak self] reason in self?.audioInterrupted(reason) }
        let clock = ContinuousClock()
        let started = clock.now
        // 开屏时间线还开着（首帧还没上屏）就记下开声音占了主线程多久：这段时间「正在连接」那层撤不掉。
        // 播放引擎在自己的队列上启动（`RemoteAudioEnginePlayer`），这里应当只有几毫秒。
        defer {
            openTrace?.event("开声音占主线程 \(RemoteConnectTrace.millis(clock.now - started)) ms")
        }
        do {
            try audioOutput.start(pull: { receiver.pull(into: $0, frames: $1) })
            audioPlaying = true
        } catch {
            #if os(macOS)
            audioState = .unavailable("这台 Mac 上无法播放声音：\(error.localizedDescription)")
            #else
            audioState = .unavailable("手机上无法播放声音：\(error.localizedDescription)")
            #endif
            wantsAudio = false
        }
    }

    private func stopAudioPlayback() {
        guard audioPlaying else { return }
        audioPlaying = false
        audioOutput?.stop()
    }

    private func audioInterrupted(_ reason: String) {
        guard wantsAudio else { return }
        setAudio(false)
        audioState = .unavailable(reason)
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
            // Mac 解锁要叫醒锁屏（约 2 秒）+ 输入 + 轮询 6 秒，再留出链路余量；超时当失败处理。
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
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
                let audio = self.audioReceiver.snapshot()
                if self.audioStats != audio { self.audioStats = audio }
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
    /// 下一帧解出来时调一次（开流后量第一帧要多久）。
    private var onFirstImage: (@Sendable () -> Void)?
    /// 开屏时间线：第一帧上屏之前的各段记在它上面（见 `FirstImageProgress`）。
    private var firstImageTrace: RemoteConnectTrace?
    /// 只在解码队列上。
    private var firstImageProgress = FirstImageProgress()
    /// 每 2 秒一行的接收诊断（只在解码队列上）。
    private var receiveCounts = ReceiveCounts()
    private var lastReceiveLog: UInt64 = 0

    /// 收到什么、解出什么、为什么没解：看「卡在第一帧」是不是一直在等恢复帧。
    private struct ReceiveCounts {
        var keyframes = 0
        var refreshes = 0
        var normal = 0
        var sidecar = 0
        var decoded = 0
        var skippedRecovering = 0
        var failed = 0
        var lost = 0
        var nudges = 0
        var isEmpty: Bool { keyframes + refreshes + normal + sidecar + lost == 0 }
    }

    private func logReceiveIfDue(now: UInt64) {
        guard now &- lastReceiveLog >= 2_000_000_000 else { return }
        lastReceiveLog = now
        let c = receiveCounts
        receiveCounts = ReceiveCounts()
        guard !c.isEmpty else { return }
        let waiting = recovering ? String(format: "，在等恢复帧 %.1f s", Double(now &- recoveringStarted) / 1e9) : ""
        AppLogger.info("桌面接收：收到 关键帧 \(c.keyframes) 刷新 \(c.refreshes) 普通 \(c.normal) 旁路 \(c.sidecar)｜"
                       + "解出 \(c.decoded)，等恢复跳过 \(c.skippedRecovering)，解码失败 \(c.failed)，没收齐 \(c.lost)，"
                       + "催恢复 \(c.nudges)\(waiting)", category: RemoteLog.category)
    }

    /// 开流到第一帧上屏之间发生了什么：各记一次，第一帧解出来时一并报数。
    private struct FirstImageProgress {
        var sawFrame = false
        var reportedLost = false
        var reportedFailure = false
        var lost = 0
        var skipped = 0
        var failed = 0
        var stale = 0
    }
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
    /// 这一轮从什么时候开始等恢复帧（`recoveringSince` 每催一次会重置，日志看的是这个）。
    private var recoveringStarted: UInt64 = 0
    /// 暂停期间跳过过帧：解码器的参考链已经断了，恢复后要等关键帧。
    private var skippedWhilePaused = false

    /// 等恢复帧这么久还没来，再催一次。恢复帧自己也可能丢。
    static let recoveryRetryNanos: UInt64 = 500_000_000

    init(outputPixelFormat: OSType?) {
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
    /// 下一次解出画面时调 `callback` 一次。
    func expectFirstImage(trace: RemoteConnectTrace? = nil, _ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        onFirstImage = callback
        firstImageTrace = trace
        lock.unlock()
        decodeQueue.async { self.firstImageProgress = FirstImageProgress() }
    }

    /// 第一帧上屏之前的事记到开屏时间线上。在解码队列上调用。
    private func noteBeforeFirstImage(_ text: String) {
        lock.lock()
        let trace = firstImageTrace
        lock.unlock()
        trace?.event(text)
    }

    private var awaitingFirstImage: Bool {
        lock.lock(); defer { lock.unlock() }
        return firstImageTrace != nil
    }

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
        if awaitingFirstImage {
            firstImageProgress.lost += videoSequences.count
            if !firstImageProgress.reportedLost {
                firstImageProgress.reportedLost = true
                noteBeforeFirstImage("首帧前有帧没收齐、放弃（\(videoSequences.count) 帧）")
            }
        }
        decoder.markReferenceLost()
        if !recovering {
            recovering = true
            recoveringSince = DispatchTime.now().uptimeNanoseconds
            recoveringStarted = recoveringSince
        }
        receiveCounts.lost += videoSequences.count
        logReceiveIfDue(now: DispatchTime.now().uptimeNanoseconds)
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
        video?.stopAudioReceiving()
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
        let viaDatagram = video != nil
        lock.unlock()
        guard current else {
            if awaitingFirstImage { firstImageProgress.stale += 1 }
            return
        }
        guard let frame = try? RemoteDesktopFrame(decoding: payload) else { return }
        if frame.flags.contains(.sidecar) {
            receiveCounts.sidecar += 1
        } else if frame.isKeyframe {
            receiveCounts.keyframes += 1
        } else if frame.flags.contains(.ltrRefresh) {
            receiveCounts.refreshes += 1
        } else {
            receiveCounts.normal += 1
        }
        logReceiveIfDue(now: DispatchTime.now().uptimeNanoseconds)
        if awaitingFirstImage, !firstImageProgress.sawFrame {
            firstImageProgress.sawFrame = true
            let kind = frame.isKeyframe ? "关键帧" : frame.flags.contains(.ltrRefresh) ? "刷新帧" : "普通帧"
            noteBeforeFirstImage("收到首个视频帧（\(kind) \(payload.count / 1024) KB，序号 \(frame.sequence)，"
                                 + "\(viaDatagram ? "直连数据报" : "可靠通道")）")
        }
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
            receiveCounts.skippedRecovering += 1
            if awaitingFirstImage { firstImageProgress.skipped += 1 }
            if start &- recoveringSince >= Self.recoveryRetryNanos {
                receiveCounts.nudges += 1
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
        if image != nil { receiveCounts.decoded += 1 } else { receiveCounts.failed += 1 }
        if let image {
            handler?(image, frame)
            lock.lock()
            let first = onFirstImage
            let trace = firstImageTrace
            onFirstImage = nil
            firstImageTrace = nil
            lock.unlock()
            if let trace {
                let p = firstImageProgress
                trace.event("首帧解码完（\(frame.isKeyframe ? "关键帧" : "非关键帧")，解码 \(elapsed / 1_000_000) ms；此前"
                            + "没收齐 \(p.lost)、等恢复帧跳过 \(p.skipped)、解码失败 \(p.failed)、旧流丢弃 \(p.stale)）")
            }
            first?()
        } else if !sidecar {
            if awaitingFirstImage {
                firstImageProgress.failed += 1
                if !firstImageProgress.reportedFailure {
                    firstImageProgress.reportedFailure = true
                    noteBeforeFirstImage("首帧前解码失败（\(frame.isKeyframe ? "关键帧" : "非关键帧")，序号 \(frame.sequence)）")
                }
            }
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
