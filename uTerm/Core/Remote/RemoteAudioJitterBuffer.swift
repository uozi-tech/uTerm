import Foundation

/// 手机端声音的抖动缓冲（调研 §17.4）。纯值类型：收包与取样都由调用方串行驱动，时间由调用方传入，便于单测。
///
/// - 收包 `insert`：解好的 PCM 按序号放进来，同时用「到达 − 采集」的波动估计该缓多深。两端的钟不同，
///   只用差值的变化，不用绝对值。接收端先排序再解码时，到达读数（`observe`）和放包（`store`）分开调。
/// - 晚到：包到时它的位置已经补过洞了（`noteLate`），说明缓得不够深。目标立刻撑到能接住这个晚到的深度，
///   之后一段时间没再晚到才按到达读数慢慢收回（弱网矩阵「高延迟抖动」：每包独立抖 0–150 ms）。
/// - 取样 `pull`：播放回调按输出节拍来取。缓冲不够目标深度时先出静音（缓冲中），够了开始放；轮到的包没到
///   就补一段静音（后面的包还在就接着放）；整个缓冲空了回到缓冲中；积压超过目标太多就丢包追上（先丢静音包）。
///   两端时钟几十 ppm 的漂移也靠这两条消掉。播放中目标升上去了、缓冲却浅了一截：在洞上或静音包前多垫一包静音
///   （`stretched`），把深度垫回目标；不垫的话深度只有欠载重缓时才会变深，乱序造成的补洞永远补不完。
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
        /// 只看到达波动时目标最深到哪：再往深只能是真有包晚到（补过洞）才撑。到达波动在开流的头一阵最容易虚高
        /// （样本少、p95 就是最大值，关键帧前后那一串），按它直接撑到上限的话正常网络也会白白缓深好几秒。
        var jitterCeilingNanos: UInt64
        /// 刚开流时的目标深度：这时还没有到达的读数，声音又正好和视频的第一个关键帧一起挤在链路上，
        /// 从下限起步会一连欠载好几次（真机上「刚连上时会抖」）。先缓深一点，`startupHoldNanos` 之后再按读数往下收。
        var startupTargetNanos: UInt64
        var startupHoldNanos: UInt64 = 2_000_000_000
        /// 超出目标多少才丢包追上。
        var dropSlackNanos: UInt64 = 60_000_000
        /// 估计波动看最近多久的到达。
        var windowNanos: UInt64 = 3_000_000_000
        /// 晚到撑起来的深度保持多久：这么久没再晚到才按到达读数往下收。太短的话收回去又晚到，来回补洞。
        var lateHoldNanos: UInt64 = 10_000_000_000
        /// 接住晚到的包之外再留多少余量。
        var lateMarginNanos: UInt64 = 5_000_000

        /// 直连与局域网：往返短、抖动小。到达波动最深撑到 150 ms（和以前一样）；真有包晚到才往下撑，最深 250 ms：
        /// 抖动大的直连（往返 300 ± 150 ms）要缓 170 ms 左右才接得住，再深的话声音比画面（同一链路 p95 约 250 ms）
        /// 还晚，不如补洞。
        static let direct = Config(minimumTargetNanos: 40_000_000, maximumTargetNanos: 250_000_000,
                                   jitterCeilingNanos: 150_000_000, startupTargetNanos: 120_000_000)
        /// TCP 中继：关键帧前后的排队会让包成串晚到。
        static let relay = Config(minimumTargetNanos: 80_000_000, maximumTargetNanos: 300_000_000,
                                  jitterCeilingNanos: 300_000_000, startupTargetNanos: 200_000_000)
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
        /// 为了把深度垫回目标多放的静音包。
        var stretched = 0
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
    /// 追积压时从中间丢掉的静音包：轮到时同样不算补洞。
    private var quietGaps: Set<UInt32> = []
    /// 最近的（到达时刻, 到达 − 采集）。
    private var transits: [(arrival: UInt64, transit: Int64)] = []
    /// 上一个放出去的采样（每声道），淡出从它开始。
    private var lastSample: [Float]
    /// 接下来几个采样要淡入。
    private var fadeIn = 0
    /// 上一次把目标往下调的时刻：只升得快，降得慢。
    private var lastTargetDecrease: UInt64 = 0
    /// 第一包到达的时刻（本机钟）：起步深度从这时起保持 `startupHoldNanos`。
    private var firstArrival: UInt64?
    /// 晚到的包要求的深度，和最近一次晚到的时刻。
    private var lateFloor: UInt64 = 0
    private var lastLate: UInt64?
    /// 正在垫的静音还剩几个采样（每声道）。
    private var stretching = 0

    private var fadeFrames: Int { max(1, Int(config.sampleRate / 1000)) }
    private var packetNanos: UInt64 { UInt64(Double(config.framesPerPacket) / config.sampleRate * 1e9) }

    init(config: Config) {
        self.config = config
        targetNanos = min(config.maximumTargetNanos, max(config.minimumTargetNanos, config.startupTargetNanos))
        lastSample = Array(repeating: 0, count: config.channels)
    }

    /// 缓冲里还有多少声音（纳秒）。
    var bufferedNanos: UInt64 {
        let samples = bufferedSamples / config.channels
        return UInt64(Double(samples) / config.sampleRate * 1e9)
    }

    var isPlaying: Bool { playhead != nil }

    /// 每包多长（纳秒）。
    var packetDuration: UInt64 { packetNanos }

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

    /// 放进一包解好的声音，同时记这一包的到达读数。`captureNanos` 是 Mac 的钟，`arrivalNanos` 是本机的钟。
    mutating func insert(sequence: UInt32, captureNanos: UInt64, samples: [Float], arrivalNanos: UInt64) {
        observe(captureNanos: captureNanos, arrivalNanos: arrivalNanos)
        store(sequence: sequence, samples: samples, captureNanos: captureNanos, arrivalNanos: arrivalNanos)
    }

    /// 只放包、不记到达读数（读数在包到达时已经 `observe` 过）。它的位置已经放过了就按晚到算。
    mutating func store(sequence: UInt32, samples: [Float], captureNanos: UInt64, arrivalNanos: UInt64) {
        if let playhead, sequence < playhead {
            noteLate(captureNanos: captureNanos, arrivalNanos: arrivalNanos)
            return
        }
        guard chunks[sequence] == nil, !samples.isEmpty else { return }
        chunks[sequence] = samples
    }

    /// 一包到了：记「到达 − 采集」，按最近的波动调目标。
    mutating func observe(captureNanos: UInt64, arrivalNanos: UInt64) {
        recordTransit(captureNanos: captureNanos, arrivalNanos: arrivalNanos)
    }

    /// 一包到得太晚，它的位置已经补过洞了（接收端放弃等它之后它才到，也走这里）。目标立刻撑到能接住它。
    mutating func noteLate(captureNanos: UInt64, arrivalNanos: UInt64) {
        counters.late += 1
        guard let fastest = transits.map(\.transit).min() else { return }
        let transit = Int64(bitPattern: arrivalNanos &- captureNanos)
        let lateness = UInt64(max(0, transit - fastest))
        if let lastLate, arrivalNanos &- lastLate >= config.lateHoldNanos { lateFloor = 0 }
        lateFloor = max(lateFloor, min(config.maximumTargetNanos, lateness + packetNanos + config.lateMarginNanos))
        lastLate = arrivalNanos
        updateTarget(now: arrivalNanos)
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

    /// 目标 = 最近到达波动的 p95 + 一包的时长（按包到达，缓冲深度天然会差一包），且不低于最近晚到的包要求的深度。
    /// 升得快、降得慢；开流头几秒只升不降。
    private mutating func updateTarget(now: UInt64) {
        let first = firstArrival ?? now
        firstArrival = first
        guard transits.count >= 5, let fastest = transits.map(\.transit).min() else { return }
        let jitters = transits.map { UInt64(max(0, $0.transit - fastest)) }.sorted()
        let p95 = jitters[min(jitters.count - 1, Int(Double(jitters.count) * 0.95))]
        let late = lastLate.map { now &- $0 < config.lateHoldNanos } == true ? lateFloor : 0
        let wanted = min(config.maximumTargetNanos,
                         max(config.minimumTargetNanos, min(config.jitterCeilingNanos, p95 + packetNanos), late))
        if wanted > targetNanos {
            targetNanos = wanted
        } else if wanted < targetNanos, now &- first >= config.startupHoldNanos,
                  now &- lastTargetDecrease >= 1_000_000_000 {
            // 每秒最多降 10%：一阵抖动刚过去就收紧，下一阵来时又会欠载。
            targetNanos = max(wanted, targetNanos - targetNanos / 10)
            lastTargetDecrease = now
        }
    }

    // MARK: - 取样

    /// 取 `frames` 个采样（每声道），返回交错数组。测试用；播放回调走不分配内存的 `pull(into:frames:)`。
    mutating func pull(frames: Int) -> [Float] {
        var output = [Float](repeating: 0, count: frames * config.channels)
        output.withUnsafeMutableBufferPointer { pull(into: $0, frames: frames) }
        return output
    }

    /// 把 `frames` 个采样（每声道）交错写进 `output`（至少 `frames × channels` 个）。不分配内存：在音频线程上调用。
    mutating func pull(into output: UnsafeMutableBufferPointer<Float>, frames: Int) {
        let channels = config.channels
        output.update(repeating: 0)
        var written = 0
        while written < frames {
            if playhead == nil {
                guard let start = startIfReady() else {
                    // 缓冲中：整段出静音。
                    writeSilence(into: output, from: written, count: frames - written)
                    return
                }
                playhead = start
                offset = 0
                fadeIn = fadeFrames
            }
            if stretching > 0 {
                let count = min(frames - written, stretching)
                writeSilence(into: output, from: written, count: count)
                written += count
                stretching -= count
                continue
            }
            dropIfBacklogged()
            guard let sequence = playhead else { continue }
            if offset == 0, shouldStretch(at: sequence) {
                stretching = config.framesPerPacket
                counters.stretched += 1
                continue
            }
            guard let chunk = chunks[sequence] else {
                if chunks.keys.contains(where: { $0 > sequence }) {
                    // 这包没到，后面的到了：补一包静音、往下走。Mac 说过是静音的不算补洞。
                    let remaining = config.framesPerPacket - offset / channels
                    let count = min(frames - written, remaining)
                    writeSilence(into: output, from: written, count: count)
                    written += count
                    offset += count * channels
                    if offset / channels >= config.framesPerPacket {
                        if !isAnnouncedSilent(sequence), quietGaps.remove(sequence) == nil { counters.concealed += 1 }
                        advance()
                    }
                } else {
                    // 缓冲空了：回到缓冲中。Mac 说过这里起是静音（停发了）的不算欠载，那是正常的停顿。
                    if !isAnnouncedSilent(sequence) { counters.underruns += 1 }
                    playhead = nil
                    offset = 0
                    stretching = 0
                    chunks.removeAll()
                    quietGaps.removeAll()
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
    }

    /// 播放中缓冲比目标浅了两包以上（目标因为晚到撑起来了）：在洞上（这包没到、后面的到了）或静音包前垫一包静音。
    /// 有声的包前面不垫，免得把一段声音从中间切开。
    private func shouldStretch(at sequence: UInt32) -> Bool {
        guard bufferedNanos + 2 * packetNanos < targetNanos else { return false }
        if let chunk = chunks[sequence] { return RemoteAudioJitterBuffer.isQuiet(chunk) }
        return chunks.keys.contains { $0 > sequence }
    }

    /// 缓冲到目标深度了就从最早的那包开始放。
    private func startIfReady() -> UInt32? {
        guard let first = chunks.keys.min(), bufferedNanos >= targetNanos else { return nil }
        return first
    }

    private mutating func advance() {
        guard let current = playhead else { return }
        chunks[current] = nil
        // 一格格往前走越不过任何记号（轮到的记号在补洞那里已经拿掉了），不必清理。
        playhead = current &+ 1
        offset = 0
    }

    /// 播放位置跳到 `next`（追积压、跳过洞时），顺手清掉已经越过的「丢掉的静音包」记号（不然长时间追积压会越攒越多）。
    private mutating func moveTo(_ next: UInt32) {
        playhead = next
        if !quietGaps.isEmpty { quietGaps = quietGaps.filter { $0 >= next } }
    }

    /// Mac 说过到这一包为止都是静音。
    private func isAnnouncedSilent(_ sequence: UInt32) -> Bool {
        silentThrough.map { $0 >= sequence } ?? false
    }

    /// 积压超过目标太多：在包的边界上丢包追上。先丢静音包，没有静音包丢最早的。
    ///
    /// 丢最早的就是让播放位置往前跳。播放位置停在洞上（那包丢了）时先跳过洞：要是还从洞后面最早的那包丢起，
    /// 丢的全是播放位置前面的包，播放位置自己卡在洞上一格格补静音，永远追不上（直连真机前在模拟链路上踩到过）。
    private mutating func dropIfBacklogged() {
        guard offset == 0, playhead != nil else { return }
        while bufferedNanos > targetNanos + config.dropSlackNanos, let current = playhead {
            let pending = chunks.keys.filter { $0 >= current }.sorted()
            guard pending.count > 1 else { return }
            if pending[0] != current {
                // 播放位置在洞上：先跳到下一包现有的（不算丢包，洞本来就没有内容）。
                moveTo(pending[0])
                fadeIn = fadeFrames
                continue
            }
            if let quiet = pending.first(where: { RemoteAudioJitterBuffer.isQuiet(chunks[$0] ?? []) }) {
                chunks[quiet] = nil
                counters.dropped += 1
                // 中间丢掉的静音包轮到时按静音处理，不算补洞。
                quietGaps.insert(quiet)
                if quiet == current { moveTo(pending[1]) }
                continue
            }
            chunks[current] = nil
            counters.dropped += 1
            moveTo(pending[1])
            fadeIn = fadeFrames
        }
    }

    static func isQuiet(_ samples: [Float]) -> Bool {
        for sample in samples where abs(sample) >= RemoteAudioPolicy.silenceThreshold { return false }
        return true
    }

    /// 写静音；刚从有声切过来时先用 1 ms 把上一个采样淡到 0，接回有声时再淡入。
    private mutating func writeSilence(into output: UnsafeMutableBufferPointer<Float>, from start: Int, count: Int) {
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
