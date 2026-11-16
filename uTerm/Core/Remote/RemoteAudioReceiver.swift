import AVFoundation
import Foundation

/// 手机这一侧的声音接收（调研 §17.4）：按格式建解码器 → 排序 → 解包（含冗余补洞）→ 抖动缓冲 → 播放回调来取。
///
/// 线程：包在连接队列（TCP）或数据报队列（直连）上到达，转到自己的解码队列；播放回调在音频线程上取样，
/// 抖动缓冲用锁保护（取样只是拷几百个采样，锁持有时间很短）。
///
/// 解码器只能按序号往前喂（Opus 每包接着上一包的状态），所以数据报乱序到达时先排序：缺的那包没到，后面的
/// 先存着不解。缺的到了就接着解；冗余里带着它也算到了；Mac 说过是静音的不用等。真等不到才跳过它（交给缓冲
/// 补洞）：缓冲在放时等到快放空（`giveUpMarginNanos`），没在放时等过乱序窗口。以前是谁先到解谁，晚到一步的
/// 包整个扔掉——每包独立抖动的链路上近一半的包这样没了（弱网矩阵「高延迟抖动」补洞 428–550 次，欠载 0）。
nonisolated final class RemoteAudioReceiver: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var stream: UInt16?
        var codec: RemoteAudioCodec?
        var counters = RemoteAudioJitterBuffer.Counters()
        var targetMillis = 0
        var bufferedMillis = 0
        var received = 0
        var recovered = 0
        /// 晚于后面的包到达、排序后照样解出来的包。
        var reordered = 0
        /// 等不到、跳过去的包（交给缓冲补洞）。
        var skipped = 0
        var reorderWindowMillis = 0
    }

    /// 缓冲在放时，缓冲里只剩这么多就不再等缺的包：要盖住一次播放回调取走的量（iOS 要的是 10 ms、系统可能给
    /// 21 ms）加上检查的间隔，不然缺的包没等到，后面存着的也没来得及放进去，缓冲整个放空、重新缓冲。
    static let giveUpMarginNanos: UInt64 = 30_000_000
    /// 有包在等时多久查一次。
    static let checkIntervalNanos: UInt64 = 5_000_000
    /// 乱序窗口的下限与起始值：缓冲没在放时（刚开流、静音之后）缺的包等这么久。实际按观察到的乱序撑大，
    /// 但不超过缓冲目标（再等下去缓冲本来也是空的）。
    static let minimumReorderWindowNanos: UInt64 = 10_000_000
    /// 最多存多少包等缺的那包：超出说明它不会来了。
    static let maxPending = 512

    private struct Pending {
        var frame: RemoteDesktopAudioFrame
        var arrival: UInt64
    }

    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.audio.decode", qos: .userInteractive)
    private let lock = NSLock()
    private let config: RemoteAudioJitterBuffer.Config
    /// 本机单调钟（纳秒）。单测换成手拨的钟。
    private let clock: @Sendable () -> UInt64
    // 锁内。
    private var buffer: RemoteAudioJitterBuffer?
    private var stream: UInt16?
    private var codec: RemoteAudioCodec?
    private var received = 0
    private var recovered = 0
    private var reordered = 0
    private var skippedCount = 0
    private var reorderWindowSnapshot: UInt64 = 0
    // 只在 queue 上。
    private var decoder: RemoteAudioDecoder?
    /// 解到第几个序号了（含跳过的）：比它旧的包不再解。
    private var lastDecoded: UInt32?
    /// 比 `lastDecoded + 1` 新、还在等前面的包。
    private var pending: [UInt32: Pending] = [:]
    /// Mac 说到这里为止都是静音（停发）：这些序号不会来，不用等。
    private var silentThrough: UInt32?
    /// 跳过的序号：之后到了按晚到算（让缓冲撑深）。只留最近的。
    private var skipped: [UInt32] = []
    private var reorderWindow = RemoteAudioReceiver.minimumReorderWindowNanos
    /// 每换一次流加一：换流之前排好的检查作废。
    private var generation = 0
    private var checkScheduled = false

    init(config: RemoteAudioJitterBuffer.Config,
         clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.config = config
        self.clock = clock
    }

    /// 新的声音流（或 Mac 说没有声音了：`codec == nil`）。
    func receive(format: RemoteDesktopAudioFormat) {
        queue.async { [self] in
            resetOrdering()
            decoder = format.codec != nil ? try? RemoteAudioDecoder(format: format) : nil
            var config = self.config
            config.framesPerPacket = Int(format.framesPerPacket)
            config.channels = Int(format.channels)
            config.sampleRate = format.sampleRate
            lock.lock()
            stream = format.codec != nil ? format.stream : nil
            codec = format.codec
            buffer = format.codec != nil ? RemoteAudioJitterBuffer(config: config) : nil
            received = 0
            recovered = 0
            reordered = 0
            skippedCount = 0
            lock.unlock()
        }
    }

    /// 一包声音（`RemoteDesktopAudioFrame` 编码后的字节）。
    func receive(frame payload: Data) {
        let arrival = clock()
        queue.async { [self] in
            guard let frame = try? RemoteDesktopAudioFrame(decoding: payload), decoder != nil else { return }
            lock.lock()
            let current = stream
            if frame.stream == current, !frame.isSilence {
                // 到达读数按包自己到的时刻记（存着等前面的包不影响）；静音包在 `markSilence` 里记。
                buffer?.observe(captureNanos: frame.captureNanos, arrivalNanos: arrival)
            }
            lock.unlock()
            guard frame.stream == current else { return }
            if frame.isSilence {
                lock.lock()
                buffer?.markSilence(through: frame.sequence, captureNanos: frame.captureNanos, arrivalNanos: arrival)
                lock.unlock()
                silentThrough = max(silentThrough ?? 0, frame.sequence)
                drain(now: arrival)
                return
            }
            if let lastDecoded, frame.sequence <= lastDecoded {
                // 已经解过（冗余里先到了）或已经跳过。跳过的才算晚到：缓冲要撑深到能接住它。
                if let index = skipped.firstIndex(of: frame.sequence) {
                    skipped.remove(at: index)
                    lock.lock()
                    buffer?.noteLate(captureNanos: frame.captureNanos, arrivalNanos: arrival)
                    lock.unlock()
                }
                return
            }
            guard pending[frame.sequence] == nil else { return }
            if lastDecoded.map({ frame.sequence == $0 &+ 1 }) == true, let earliest = pending.values.map(\.arrival).min() {
                // 缺的那包到了，比它后面的晚了这么久：按这个撑大乱序窗口（RACK 的思路，之后慢慢收回）。
                noteReordering(lateness: arrival &- earliest)
                lock.lock()
                reordered += 1
                lock.unlock()
            }
            pending[frame.sequence] = Pending(frame: frame, arrival: arrival)
            drain(now: arrival)
        }
    }

    /// 按序号能解的都解掉；缺的那包按规则等或跳过。还有包在等就排一次检查。
    private func drain(now: UInt64) {
        while !pending.isEmpty {
            let next = lastDecoded.map { $0 &+ 1 } ?? pending.keys.min()!
            if let item = pending.removeValue(forKey: next) {
                decodeAndStore(item.frame.data, sequence: next, captureNanos: item.frame.captureNanos,
                               arrival: item.arrival, recovered: false)
                continue
            }
            if let silentThrough, next <= silentThrough {
                // Mac 说过这段是静音：直接越过（解码器不用吃这些包，有声时 Mac 会把停发前最后一包当冗余带来接上状态）。
                lastDecoded = min(silentThrough, pending.keys.min()! &- 1)
                continue
            }
            if let (carrier, distance) = redundancyCarrier(for: next) {
                let frame = carrier.frame
                decodeAndStore(frame.redundant[distance - 1], sequence: next,
                               captureNanos: frame.captureNanos &- UInt64(distance) * packetNanos,
                               arrival: carrier.arrival, recovered: true)
                continue
            }
            guard shouldGiveUp(now: now) else { break }
            lastDecoded = next
            skipped.append(next)
            if skipped.count > 64 { skipped.removeFirst(skipped.count - 64) }
            lock.lock()
            skippedCount += 1
            lock.unlock()
        }
        lock.lock()
        reorderWindowSnapshot = reorderWindow
        lock.unlock()
        if !pending.isEmpty { scheduleCheck() }
    }

    /// 存着的包里有没有把 `sequence` 当冗余带着的。
    private func redundancyCarrier(for sequence: UInt32) -> (Pending, Int)? {
        for key in pending.keys.sorted() {
            let distance = Int(key &- sequence)
            guard let item = pending[key] else { continue }
            if distance <= item.frame.redundant.count { return (item, distance) }
            if distance > 2 + item.frame.redundant.count { break }
        }
        return nil
    }

    /// 缺的那包还要不要等。
    private func shouldGiveUp(now: UInt64) -> Bool {
        if pending.count > Self.maxPending { return true }
        lock.lock()
        let playing = buffer?.isPlaying ?? false
        let buffered = buffer?.bufferedNanos ?? 0
        let target = buffer?.targetNanos ?? 0
        let packet = buffer?.packetDuration ?? 0
        lock.unlock()
        guard let earliest = pending.values.map(\.arrival).min() else { return true }
        let waited = now &- earliest
        // 等得比缓冲最深还久，到了也用不上了。也兜住没人来取的时候（播放被打断、单测不拉取）：缓冲一直显得很满。
        if waited >= config.maximumTargetNanos { return true }
        if playing { return buffered <= Self.giveUpMarginNanos }
        // 没在放（刚开流、静音或欠载之后）：等过乱序窗口。不超过缓冲目标：缓冲要攒够目标深度才开始放，
        // 等这么久不会让开头更晚。
        let window = min(reorderWindow, max(Self.minimumReorderWindowNanos, target &- min(target, packet)))
        return waited >= window
    }

    private func noteReordering(lateness: UInt64) {
        if lateness > reorderWindow {
            reorderWindow = min(config.maximumTargetNanos, lateness + lateness / 8)
        } else {
            reorderWindow = max(Self.minimumReorderWindowNanos, reorderWindow - (reorderWindow - lateness) / 64)
        }
    }

    private var packetNanos: UInt64 {
        guard let decoder else { return 0 }
        return UInt64(Double(decoder.format.framesPerPacket) / decoder.format.sampleRate * 1e9)
    }

    private func decodeAndStore(_ data: Data, sequence: UInt32, captureNanos: UInt64, arrival: UInt64, recovered: Bool) {
        lastDecoded = sequence
        guard let decoder, let samples = try? decoder.decode(data) else { return }
        lock.lock()
        buffer?.store(sequence: sequence, samples: samples, captureNanos: captureNanos, arrivalNanos: arrival)
        if recovered { self.recovered += 1 } else { received += 1 }
        lock.unlock()
    }

    private func scheduleCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        let generation = self.generation
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(Self.checkIntervalNanos))) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.checkScheduled = false
            self.drain(now: self.clock())
        }
    }

    /// 单测：等解码队列上已经排着的活干完，再按当前的钟查一次缺的包。
    func settle() {
        queue.sync { drain(now: clock()) }
    }

    private func resetOrdering() {
        generation += 1
        checkScheduled = false
        lastDecoded = nil
        pending.removeAll()
        silentThrough = nil
        skipped.removeAll()
        reorderWindow = Self.minimumReorderWindowNanos
    }

    /// 播放回调来取 `frames` 个采样（每声道），交错写进 `output`。没有声音流时全是 0。音频线程上调用，不分配内存。
    func pull(into output: UnsafeMutableBufferPointer<Float>, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard buffer != nil else {
            output.update(repeating: 0)
            return
        }
        buffer!.pull(into: output, frames: frames)
    }

    func reset() {
        queue.async { [self] in
            decoder = nil
            resetOrdering()
            lock.lock()
            buffer = nil
            stream = nil
            codec = nil
            lock.unlock()
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(stream: stream, codec: codec, counters: buffer?.counters ?? .init(),
                        targetMillis: Int((buffer?.targetNanos ?? 0) / 1_000_000),
                        bufferedMillis: Int((buffer?.bufferedNanos ?? 0) / 1_000_000), received: received,
                        recovered: recovered, reordered: reordered, skipped: skippedCount,
                        reorderWindowMillis: Int(reorderWindowSnapshot / 1_000_000))
    }
}

/// 声音放到哪里：生产是 `AVAudioEngine`，Mac 单测里是什么都不放的假输出（测试不能真出声）。
@MainActor
protocol RemoteAudioOutput: AnyObject {
    /// 开始放。`pull(缓冲, 帧数)` 在音频线程上调用，把交错采样写进缓冲（至少 `帧数 × 2` 个）。
    func start(pull: @escaping @Sendable (UnsafeMutableBufferPointer<Float>, Int) -> Void) throws
    func stop()
    /// 系统要求停下（iOS：拔了耳机、被来电打断后不再恢复）。参数是给人看的原因。
    var onInterrupted: ((String) -> Void)? { get set }
}

/// 播放回调的交错采样中转区。随最后一个持有者（节点的渲染闭包）释放。
nonisolated final class RemoteAudioScratch: @unchecked Sendable {
    let frames: Int
    let channels: Int
    let buffer: UnsafeMutableBufferPointer<Float>

    init(frames: Int, channels: Int) {
        self.frames = frames
        self.channels = channels
        buffer = .allocate(capacity: frames * channels)
        buffer.initialize(repeating: 0)
    }

    deinit { buffer.deallocate() }
}

/// `AVAudioEngine` + `AVAudioSourceNode`：音频线程按输出节拍来取，缓冲深度完全由抖动缓冲控制。
///
/// 引擎与音频会话的开关一律在 `EngineHost.queue` 上做，主线程只发起：`AVAudioEngine.start()` 很慢（Duo 实测
/// App 启动后第一次 1047 ms，之后约 250 ms），以前在主线程上同步做，开屏时画面早就解出来了，「正在连接」那层
/// 却要等它做完才撤（2026-11-16：首帧解码完 +522 ms，画面层 +1604 ms 才撤）。启动失败经 `onInterrupted` 报，
/// 和被系统打断一样处理（关掉声音、说明原因）。
@MainActor
final class RemoteAudioEnginePlayer: RemoteAudioOutput {
    /// 只在 `queue` 上碰（通知里拿 `engine` 当 `object` 比对身份除外）。
    nonisolated private final class EngineHost: @unchecked Sendable {
        let engine = AVAudioEngine()
        let queue = DispatchQueue(label: "com.uozi.uTerm.remote.audio-engine", qos: .userInitiated)
        var node: AVAudioSourceNode?
    }

    private let host = EngineHost()
    /// 每次 start / stop 加一：排在队列上的旧结果回到主线程时认得出来、不作数。
    private var generation = 0
    private var isStarted = false
    var onInterrupted: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {}

    func start(pull: @escaping @Sendable (UnsafeMutableBufferPointer<Float>, Int) -> Void) throws {
        stop()
        generation += 1
        isStarted = true
        #if os(iOS)
        observeSession()
        #endif
        observeEngineConfiguration()
        let current = generation
        Self.startOnQueue(host, pull: pull) { [weak self] failure in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isStarted, self.generation == current, let failure else { return }
                    self.onInterrupted?(failure)
                }
            }
        }
    }

    /// 在引擎队列上：设好音频会话、挂上节点、启动。`done(nil)` = 成功，否则是给人看的失败原因。
    nonisolated private static func startOnQueue(_ host: EngineHost,
                                                 pull: @escaping @Sendable (UnsafeMutableBufferPointer<Float>, Int) -> Void,
                                                 done: @escaping @Sendable (String?) -> Void) {
        host.queue.async {
            let clock = ContinuousClock()
            let started = clock.now
            do {
                #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                // 声音按钮默认关，打开是用户的选择：静音键下也出声，与看视频一致。
                try session.setCategory(.playback, mode: .default, options: [])
                try? session.setPreferredIOBufferDuration(0.01)
                try session.setActive(true)
                #endif
                guard let format = AVAudioFormat(standardFormatWithSampleRate: RemoteAudioPolicy.sampleRate,
                                                 channels: AVAudioChannelCount(RemoteAudioPolicy.channels)) else {
                    done(nil)
                    return
                }
                // 交错采样的中转区：一次分配、跟着节点的闭包走，音频线程上不再分配内存。
                let scratch = RemoteAudioScratch(frames: 8192, channels: Int(RemoteAudioPolicy.channels))
                let node = AVAudioSourceNode(format: format, renderBlock: renderBlock(scratch: scratch, pull: pull))
                host.engine.attach(node)
                host.engine.connect(node, to: host.engine.mainMixerNode, format: format)
                host.node = node
                try host.engine.start()
                AppLogger.info("远程桌面声音：播放引擎启动 \(RemoteConnectTrace.millis(clock.now - started)) ms",
                               category: RemoteLog.category)
                done(nil)
            } catch {
                #if os(macOS)
                done("这台 Mac 上无法播放声音：\(error.localizedDescription)")
                #else
                done("手机上无法播放声音：\(error.localizedDescription)")
                #endif
            }
        }
    }

    /// 播放回调。必须在 nonisolated 的地方建：在本类（`@MainActor`）的方法里直接写闭包，Swift 会把它推断成主线程隔离、
    /// 进入时检查执行者，而它是在音频线程上被调的——真机一开声音就在 `dispatch_assert_queue` 上崩（Mac 单测用的是假输出，
    /// 碰不到这里）。
    nonisolated static func renderBlock(scratch: RemoteAudioScratch,
                                        pull: @escaping @Sendable (UnsafeMutableBufferPointer<Float>, Int) -> Void)
        -> AVAudioSourceNodeRenderBlock {
        { _, _, frameCount, bufferList in
            let frames = min(Int(frameCount), scratch.frames)
            let channels = scratch.channels
            let samples = UnsafeMutableBufferPointer(rebasing: scratch.buffer[0..<frames * channels])
            pull(samples, frames)
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            // 标准格式是每声道一块（非交错）。
            for (channel, buffer) in buffers.enumerated() {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let source = min(channel, channels - 1)
                for frame in 0..<Int(frameCount) {
                    data[frame] = frame < frames ? samples[frame * channels + source] : 0
                }
            }
            return noErr
        }
    }

    func stop() {
        generation += 1
        let wasStarted = isStarted
        isStarted = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        guard wasStarted else { return }
        Self.stopOnQueue(host)
    }

    nonisolated private static func stopOnQueue(_ host: EngineHost) {
        host.queue.async {
            host.engine.stop()
            if let node = host.node {
                host.engine.detach(node)
                host.node = nil
            }
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    /// 引擎停着、节点还挂着时重新 start（输出设备变了、打断结束后）。失败时 `failure` 是给人看的原因。
    private func restart(failure: String, reactivateSession: Bool) {
        let current = generation
        Self.restartOnQueue(host, reactivateSession: reactivateSession) { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isStarted, self.generation == current, let error else { return }
                    self.onInterrupted?("\(failure)：\(error)")
                }
            }
        }
    }

    nonisolated private static func restartOnQueue(_ host: EngineHost, reactivateSession: Bool,
                                                   done: @escaping @Sendable (String?) -> Void) {
        host.queue.async {
            guard host.node != nil, !host.engine.isRunning else {
                done(nil)
                return
            }
            #if os(iOS)
            if reactivateSession { try? AVAudioSession.sharedInstance().setActive(true) }
            #endif
            do {
                try host.engine.start()
                done(nil)
            } catch {
                done(error.localizedDescription)
            }
        }
    }

    /// 输出设备或硬件格式变了（连上 AirPods、采样率变了）：系统会把引擎停掉并发这个通知，连接还在，重新 start 即可。
    /// 不接的话引擎静悄悄停着，按钮还亮着却没有声音。
    private func observeEngineConfiguration() {
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: host.engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restart(failure: "声音输出设备已更改，无法继续播放", reactivateSession: false)
            }
        })
    }

    #if os(iOS)
    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            MainActor.assumeIsolated {
                guard let self else { return }
                if options.contains(.shouldResume) {
                    self.restart(failure: "声音被其他应用打断后无法恢复", reactivateSession: true)
                } else {
                    self.onInterrupted?("声音被其他应用打断")
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            // 拔了耳机：按系统惯例停下，免得突然从扬声器外放。
            MainActor.assumeIsolated { self?.onInterrupted?("耳机已断开") }
        })
    }
    #endif
}
