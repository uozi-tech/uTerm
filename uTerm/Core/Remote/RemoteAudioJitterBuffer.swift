import Foundation

/// 手机端声音的抖动缓冲（调研 §16.4）。纯值类型：收包与取样都由调用方串行驱动，时间由调用方传入，便于单测。
///
/// - 收包 `insert`：解好的 PCM 按序号放进来，同时用「到达 − 采集」的波动估计该缓多深。两端的钟不同，
///   只用差值的变化，不用绝对值。
/// - 取样 `pull`：播放回调按输出节拍来取。缓冲不够目标深度时先出静音（缓冲中），够了开始放；轮到的包没到
///   就补一段静音（后面的包还在就接着放）；整个缓冲空了回到缓冲中；积压超过目标太多就丢包追上（先丢静音包）。
///   两端时钟几十 ppm 的漂移也靠这两条消掉。
/// - 从有声切到补静音、从静音接回有声，都做 1 ms 的淡出 / 淡入，免得咔哒一声。
nonisolated struct RemoteAudioJitterBuffer {
    struct Config: Equatable, Sendable {
        var sampleRate: Double = RemoteAudioPolicy.sampleRate
        var channels: Int = Int(RemoteAudioPolicy.channels)
        /// 每包多少采样（每声道）。
        var framesPerPacket: Int = 960
        /// 目标深度的下限与上限。
        var minimumTargetNanos: UInt64
        var maximumTargetNanos: UInt64
        /// 超出目标多少才丢包追上。
        var dropSlackNanos: UInt64 = 60_000_000
        /// 估计波动看最近多久的到达。
        var windowNanos: UInt64 = 3_000_000_000

        /// 直连与局域网：往返短、抖动小。
        static let direct = Config(minimumTargetNanos: 40_000_000, maximumTargetNanos: 150_000_000)
        /// TCP 中继：关键帧前后的排队会让包成串晚到。
        static let relay = Config(minimumTargetNanos: 80_000_000, maximumTargetNanos: 300_000_000)
    }

    struct Counters: Equatable, Sendable {
        /// 正常放出去的包。
        var played = 0
        /// 轮到时没到、补了静音的包。
        var concealed = 0
        /// 缓冲整个空掉、重新缓冲的次数。
        var underruns = 0
        /// 为了追上目标丢掉的包。
        var dropped = 0
        /// 到得太晚（已经放过它的位置）被扔掉的包。
        var late = 0
    }

    let config: Config
    private(set) var counters = Counters()
    /// 当前的目标深度。
    private(set) var targetNanos: UInt64

    private var chunks: [UInt32: [Float]] = [:]
    /// 下一个该放的序号；nil = 还没开始放（缓冲中）。
    private var playhead: UInt32?
    /// 当前这包已经放到第几个采样（交错数组下标）。
    private var offset = 0
    /// 确定是静音的序号（Mac 发了静音包）：轮到时不算补洞。
    private var silentThrough: UInt32?
    /// 最近的（到达时刻, 到达 − 采集）。
    private var transits: [(arrival: UInt64, transit: Int64)] = []
    /// 上一个放出去的采样（每声道），淡出从它开始。
    private var lastSample: [Float]
    /// 接下来几个采样要淡入。
    private var fadeIn = 0
    /// 上一次把目标往下调的时刻：只升得快，降得慢。
    private var lastTargetDecrease: UInt64 = 0

    private var fadeFrames: Int { max(1, Int(config.sampleRate / 1000)) }
    private var packetNanos: UInt64 { UInt64(Double(config.framesPerPacket) / config.sampleRate * 1e9) }

    init(config: Config) {
        self.config = config
        targetNanos = config.minimumTargetNanos
        lastSample = Array(repeating: 0, count: config.channels)
    }

    /// 缓冲里还有多少声音（纳秒）。
    var bufferedNanos: UInt64 {
        let samples = bufferedSamples / config.channels
        return UInt64(Double(samples) / config.sampleRate * 1e9)
    }

    var isPlaying: Bool { playhead != nil }

    private var bufferedSamples: Int {
        var total = 0
        for (sequence, chunk) in chunks {
            if let playhead, sequence < playhead { continue }
            total += chunk.count
        }
        if let playhead, let current = chunks[playhead] { total -= min(offset, current.count) }
        return total
    }

    // MARK: - 收包

    /// 放进一包解好的声音。`captureNanos` 是 Mac 的钟，`arrivalNanos` 是本机的钟。
    mutating func insert(sequence: UInt32, captureNanos: UInt64, samples: [Float], arrivalNanos: UInt64) {
        recordTransit(captureNanos: captureNanos, arrivalNanos: arrivalNanos)
        if let playhead, sequence < playhead {
            counters.late += 1
            return
        }
        guard chunks[sequence] == nil, !samples.isEmpty else { return }
        chunks[sequence] = samples
    }

    /// Mac 说到 `sequence` 为止都是静音（停发期间的心跳包）。
    mutating func markSilence(through sequence: UInt32, captureNanos: UInt64, arrivalNanos: UInt64) {
        recordTransit(captureNanos: captureNanos, arrivalNanos: arrivalNanos)
        silentThrough = max(silentThrough ?? 0, sequence)
    }

    /// 已经解过 / 放过，不必再解的包（冗余里重复带来的）。
    func contains(_ sequence: UInt32) -> Bool {
        if let playhead, sequence < playhead { return true }
        return chunks[sequence] != nil
    }

    private mutating func recordTransit(captureNanos: UInt64, arrivalNanos: UInt64) {
        let transit = Int64(bitPattern: arrivalNanos &- captureNanos)
        transits.append((arrivalNanos, transit))
        let horizon = arrivalNanos > config.windowNanos ? arrivalNanos - config.windowNanos : 0
        if let firstKept = transits.firstIndex(where: { $0.arrival >= horizon }), firstKept > 0 {
            transits.removeFirst(firstKept)
        }
        updateTarget(now: arrivalNanos)
    }

    /// 目标 = 最近到达波动的 p95 + 一包的时长（按包到达，缓冲深度天然会差一包）。升得快、降得慢。
    private mutating func updateTarget(now: UInt64) {
        guard transits.count >= 5, let fastest = transits.map(\.transit).min() else { return }
        let jitters = transits.map { UInt64(max(0, $0.transit - fastest)) }.sorted()
        let p95 = jitters[min(jitters.count - 1, Int(Double(jitters.count) * 0.95))]
        let wanted = min(config.maximumTargetNanos, max(config.minimumTargetNanos, p95 + packetNanos))
        if wanted > targetNanos {
            targetNanos = wanted
        } else if wanted < targetNanos, now &- lastTargetDecrease >= 1_000_000_000 {
            // 每秒最多降 10%：一阵抖动刚过去就收紧，下一阵来时又会欠载。
            targetNanos = max(wanted, targetNanos - targetNanos / 10)
            lastTargetDecrease = now
        }
    }

    // MARK: - 取样

    /// 取 `frames` 个采样（每声道），返回交错数组。
    mutating func pull(frames: Int) -> [Float] {
        let channels = config.channels
        var output = [Float](repeating: 0, count: frames * channels)
        var written = 0
        while written < frames {
            if playhead == nil {
                guard let start = startIfReady() else {
                    // 缓冲中：整段出静音。
                    writeSilence(into: &output, from: written, count: frames - written)
                    return output
                }
                playhead = start
                offset = 0
                fadeIn = fadeFrames
            }
            dropIfBacklogged()
            guard let sequence = playhead else { continue }
            guard let chunk = chunks[sequence] else {
                if chunks.keys.contains(where: { $0 > sequence }) {
                    // 这包没到，后面的到了：补一包静音、往下走。Mac 说过是静音的不算补洞。
                    let remaining = config.framesPerPacket - offset / channels
                    let count = min(frames - written, remaining)
                    writeSilence(into: &output, from: written, count: count)
                    written += count
                    offset += count * channels
                    if offset / channels >= config.framesPerPacket {
                        if (silentThrough ?? 0) < sequence { counters.concealed += 1 }
                        advance()
                    }
                } else {
                    // 缓冲空了：回到缓冲中。
                    counters.underruns += 1
                    playhead = nil
                    offset = 0
                    chunks.removeAll()
                }
                continue
            }
            let available = (chunk.count - offset) / channels
            let count = min(frames - written, available)
            for frame in 0..<count {
                var gain: Float = 1
                if fadeIn > 0 {
                    gain = Float(fadeFrames - fadeIn) / Float(fadeFrames)
                    fadeIn -= 1
                }
                for channel in 0..<channels {
                    let value = chunk[offset + frame * channels + channel] * gain
                    output[(written + frame) * channels + channel] = value
                    lastSample[channel] = value
                }
            }
            written += count
            offset += count * channels
            if offset >= chunk.count {
                counters.played += 1
                advance()
            }
        }
        return output
    }

    /// 缓冲到目标深度了就从最早的那包开始放。
    private func startIfReady() -> UInt32? {
        guard let first = chunks.keys.min(), bufferedNanos >= targetNanos else { return nil }
        return first
    }

    private mutating func advance() {
        guard let current = playhead else { return }
        chunks[current] = nil
        playhead = current &+ 1
        offset = 0
    }

    /// 积压超过目标太多：在包的边界上丢包追上。先丢静音包，没有静音包丢最早的。
    private mutating func dropIfBacklogged() {
        guard offset == 0, let current = playhead else { return }
        while bufferedNanos > targetNanos + config.dropSlackNanos {
            let pending = chunks.keys.filter { $0 >= current }.sorted()
            guard pending.count > 1 else { return }
            let quiet = pending.first { RemoteAudioJitterBuffer.isQuiet(chunks[$0] ?? []) }
            let victim = quiet ?? pending[0]
            chunks[victim] = nil
            counters.dropped += 1
            if victim == playhead {
                playhead = victim &+ 1
                fadeIn = fadeFrames
            }
        }
    }

    static func isQuiet(_ samples: [Float]) -> Bool {
        for sample in samples where abs(sample) >= RemoteAudioPolicy.silenceThreshold { return false }
        return true
    }

    /// 写静音；刚从有声切过来时先用 1 ms 把上一个采样淡到 0，接回有声时再淡入。
    private mutating func writeSilence(into output: inout [Float], from start: Int, count: Int) {
        let channels = config.channels
        let ramp = lastSample.contains { $0 != 0 } ? min(count, fadeFrames) : 0
        for frame in 0..<ramp {
            let gain = Float(ramp - frame - 1) / Float(ramp)
            for channel in 0..<channels {
                output[(start + frame) * channels + channel] = lastSample[channel] * gain
            }
        }
        if ramp > 0 { lastSample = Array(repeating: 0, count: channels) }
        if count > 0 { fadeIn = fadeFrames }
    }
}
