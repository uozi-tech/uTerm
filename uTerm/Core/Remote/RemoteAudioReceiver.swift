import AVFoundation
import Foundation

/// 手机这一侧的声音接收（调研 §17.4）：按格式建解码器 → 解包（含冗余补洞）→ 抖动缓冲 → 播放回调来取。
///
/// 线程：包在连接队列（TCP）或数据报队列（直连）上到达，转到自己的解码队列；播放回调在音频线程上取样，
/// 抖动缓冲用锁保护（取样只是拷几百个采样，锁持有时间很短）。
nonisolated final class RemoteAudioReceiver: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        var stream: UInt16?
        var codec: RemoteAudioCodec?
        var counters = RemoteAudioJitterBuffer.Counters()
        var targetMillis = 0
        var bufferedMillis = 0
        var received = 0
        var recovered = 0
    }

    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.audio.decode", qos: .userInteractive)
    private let lock = NSLock()
    private let config: RemoteAudioJitterBuffer.Config
    // 锁内。
    private var buffer: RemoteAudioJitterBuffer?
    private var stream: UInt16?
    private var codec: RemoteAudioCodec?
    private var received = 0
    private var recovered = 0
    // 只在 queue 上。
    private var decoder: RemoteAudioDecoder?
    /// 解到第几个序号了：解码器要按顺序喂，比它旧的包（含冗余里的）不再解。
    private var lastDecoded: UInt32?

    init(config: RemoteAudioJitterBuffer.Config) {
        self.config = config
    }

    /// 新的声音流（或 Mac 说没有声音了：`codec == nil`）。
    func receive(format: RemoteDesktopAudioFormat) {
        queue.async { [self] in
            lastDecoded = nil
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
            lock.unlock()
        }
    }

    /// 一包声音（`RemoteDesktopAudioFrame` 编码后的字节）。
    func receive(frame payload: Data) {
        let arrival = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            guard let frame = try? RemoteDesktopAudioFrame(decoding: payload), let decoder else { return }
            lock.lock()
            let current = stream
            lock.unlock()
            guard frame.stream == current else { return }
            if frame.isSilence {
                lastDecoded = max(lastDecoded ?? 0, frame.sequence)
                lock.lock()
                buffer?.markSilence(through: frame.sequence, captureNanos: frame.captureNanos, arrivalNanos: arrival)
                lock.unlock()
                return
            }
            // 冗余里的旧包先解（序号从小到大），补上前面丢的洞；解码器只能往前走。
            let packetNanos = UInt64(Double(decoder.format.framesPerPacket) / decoder.format.sampleRate * 1e9)
            for (offset, data) in frame.redundant.enumerated().reversed() {
                let distance = UInt32(offset + 1)
                guard frame.sequence >= distance else { continue }
                let sequence = frame.sequence - distance
                guard lastDecoded.map({ sequence > $0 }) ?? true else { continue }
                lock.lock()
                let have = buffer?.contains(sequence) ?? true
                lock.unlock()
                guard !have, let samples = try? decoder.decode(data) else { continue }
                lastDecoded = sequence
                insert(sequence: sequence, captureNanos: frame.captureNanos &- UInt64(distance) * packetNanos,
                       samples: samples, arrival: arrival, recovered: true)
            }
            guard lastDecoded.map({ frame.sequence > $0 }) ?? true, let samples = try? decoder.decode(frame.data) else {
                return
            }
            lastDecoded = frame.sequence
            insert(sequence: frame.sequence, captureNanos: frame.captureNanos, samples: samples, arrival: arrival,
                   recovered: false)
        }
    }

    private func insert(sequence: UInt32, captureNanos: UInt64, samples: [Float], arrival: UInt64, recovered: Bool) {
        lock.lock()
        buffer?.insert(sequence: sequence, captureNanos: captureNanos, samples: samples, arrivalNanos: arrival)
        if recovered { self.recovered += 1 } else { received += 1 }
        lock.unlock()
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
            lastDecoded = nil
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
                        recovered: recovered)
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
@MainActor
final class RemoteAudioEnginePlayer: RemoteAudioOutput {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    var onInterrupted: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {}

    func start(pull: @escaping @Sendable (UnsafeMutableBufferPointer<Float>, Int) -> Void) throws {
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // 声音按钮默认关，打开是用户的选择：静音键下也出声，与看视频一致。
        try session.setCategory(.playback, mode: .default, options: [])
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        observeSession()
        #endif
        observeEngineConfiguration()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: RemoteAudioPolicy.sampleRate,
                                         channels: AVAudioChannelCount(RemoteAudioPolicy.channels)) else { return }
        // 交错采样的中转区：一次分配、跟着节点的闭包走，音频线程上不再分配内存。
        let scratch = RemoteAudioScratch(frames: 8192, channels: Int(RemoteAudioPolicy.channels))
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
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
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.node = node
        try engine.start()
    }

    func stop() {
        engine.stop()
        if let node {
            engine.detach(node)
            self.node = nil
        }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// 输出设备或硬件格式变了（连上 AirPods、采样率变了）：系统会把引擎停掉并发这个通知，连接还在，重新 start 即可。
    /// 不接的话引擎静悄悄停着，按钮还亮着却没有声音。
    private func observeEngineConfiguration() {
        observers.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.node != nil, !self.engine.isRunning else { return }
                do {
                    try self.engine.start()
                } catch {
                    self.onInterrupted?("声音输出设备已更改，无法继续播放：\(error.localizedDescription)")
                }
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
                    try? AVAudioSession.sharedInstance().setActive(true)
                    try? self.engine.start()
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
