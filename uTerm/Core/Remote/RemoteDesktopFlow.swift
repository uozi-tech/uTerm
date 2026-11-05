import CoreGraphics
import Foundation

// 远程桌面的纯函数部分：背压与丢帧、码率控制、尺寸与坐标换算。
// 不碰采集、编码、网络，两端共用，Mac 单测全覆盖。时间一律是单调时钟纳秒（调用方传入）。

/// 发送节拍：决定一帧采集到的画面现在编、晚点编，还是被更新的画面替掉。
///
/// 规则（调研 §3.3「编码之前丢，绝不在编码之后丢」）：
/// - **在途** = 已交给编码器、还没收到手机「解码完」确认的帧。在途 ≥ `maxInflightFrames` 帧或
///   ≥ `maxInflightBytes` 字节时，新画面不送编码器，先**留着最新的一帧**（更旧的那帧直接丢掉）。
///   两个上限都跟着链路往返时间走（`RemoteRateController.inflightFrameLimit` / `inflightByteLimit`）：
///   固定 2 帧时往返一过 33 ms 就到不了 60 帧。
/// - 确认一回来（链路追上了），立刻把留着的那帧编出去。屏幕静止时 ScreenCaptureKit 不再出新帧，
///   不补这一下手机就会停在旧画面上。
/// - 帧率上限（码率控制降帧时用）：距上一次送编码器不足一个帧间隔的画面也先留着，到点再编。
///
/// 确认在手机**解码之后**才发，所以这里的背压是端到端的：网络慢、手机解码慢，都会让 Mac 少编。
nonisolated struct RemoteDesktopPacer<Frame> {
    static var defaultInflightFrames: Int { 2 }
    static var defaultInflightBytes: Int { 768 * 1024 }

    /// 在途上限，由码率控制按往返时间调。
    var maxInflightFrames = Self.defaultInflightFrames
    var maxInflightBytes = Self.defaultInflightBytes

    /// 序号 → 编出来的字节数（还在编码器里时为 0）。
    private(set) var inflight: [UInt32: Int] = [:]
    private(set) var inflightBytes = 0
    /// 留着待编的最新一帧。
    private(set) var pending: Frame?
    /// 因在途已满被替掉（没编就丢）的帧数。只做统计：码率控制看的是延迟，见 `RemoteRateController`。
    private(set) var congestionDrops = 0
    /// 因帧率上限被替掉的帧数（不算拥塞）。
    private(set) var pacingDrops = 0
    private(set) var nextSequence: UInt32 = 1
    private var lastSubmitNanos: UInt64?
    /// 两次送编码器之间的最短间隔；0 = 不限（跟着采集走）。
    var minimumIntervalNanos: UInt64 = 0

    init() {}

    var hasCapacity: Bool {
        inflight.count < maxInflightFrames && inflightBytes < maxInflightBytes
    }

    /// 采集到一帧。返回现在就该编的帧（带分配好的序号）；nil = 先留着。
    /// 被替掉的旧帧计入丢帧，返回值 `dropped` 告诉调用方这次是不是拥塞丢帧。
    mutating func offer(_ frame: Frame, now: UInt64) -> (submit: (UInt32, Frame)?, congestionDrop: Bool) {
        var congested = false
        if pending != nil {
            if hasCapacity {
                pacingDrops += 1
            } else {
                congestionDrops += 1
                congested = true
            }
        }
        pending = frame
        return (next(now: now), congested)
    }

    /// 有留着的帧、有在途名额、也到了帧间隔：取出来编。确认回来、帧间隔到点时都调它。
    mutating func next(now: UInt64) -> (UInt32, Frame)? {
        guard let frame = pending, hasCapacity, waitNanos(now: now) == 0 else { return nil }
        pending = nil
        let sequence = nextSequence
        nextSequence &+= 1
        inflight[sequence] = 0
        lastSubmitNanos = now
        return (sequence, frame)
    }

    /// 留着的帧还要等多久才到帧间隔（0 = 不用等；没有留着的帧也是 0）。
    func waitNanos(now: UInt64) -> UInt64 {
        guard pending != nil, minimumIntervalNanos > 0, let last = lastSubmitNanos else { return 0 }
        let due = last &+ minimumIntervalNanos
        return due > now ? due - now : 0
    }

    /// 编码器吐出了这一帧（字节数计入在途）。
    mutating func encoded(_ sequence: UInt32, bytes: Int) {
        guard inflight[sequence] != nil else { return }
        inflight[sequence] = bytes
        inflightBytes += bytes
    }

    /// 编码失败 / 编出来没发：释放名额。
    mutating func abandon(_ sequence: UInt32) {
        guard let bytes = inflight.removeValue(forKey: sequence) else { return }
        inflightBytes -= bytes
    }

    /// 手机确认解码完。返回 false = 不认识的序号（重复或伪造的确认，忽略）。
    @discardableResult
    mutating func acknowledge(_ sequence: UInt32) -> Bool {
        guard let bytes = inflight.removeValue(forKey: sequence) else { return false }
        inflightBytes -= bytes
        return true
    }

    /// 只取走留着的帧但不送编码器（用来重编最后一帧：关键帧请求、静止精修）。
    mutating func takePending() -> Frame? {
        defer { pending = nil }
        return pending
    }

    /// 送一帧不经过 `offer` 的画面（关键帧补发、静止精修）。没有名额时返回 nil。
    mutating func submitDirect(_ frame: Frame, now: UInt64) -> (UInt32, Frame)? {
        guard hasCapacity else { return nil }
        let sequence = nextSequence
        nextSequence &+= 1
        inflight[sequence] = 0
        lastSubmitNanos = now
        return (sequence, frame)
    }
}

/// 码率 / 帧率控制：按排队延迟调，涨跌都是持续的。
///
/// - **基线** = 最近 `baselineWindow` 内最小的「采集 → 手机解码完」耗时：链路空着时的往返加编解码。
///   排队延迟 = 这一帧的耗时 − 基线。只看排队延迟、不看绝对耗时：往返本来就慢的链路（Wi-Fi、手机解码慢）
///   绝对耗时一直高，按绝对值判就会一直「拥塞」、码率压到底再也上不来。
/// - **拥塞** = 最近 `congestionWindow` 内**最快**的那帧也比基线慢了 `queueDelayThreshold`（至少
///   `samplesForCongestion` 个样本）：码率 ×0.7，两次下调至少隔 `decreaseSpacing`。码率到底还拥塞，帧率减半到 30。
///   取窗口里的最小值是为了分开排队与抖动：真排队时每一帧都慢，最小值跟着抬；Wi-Fi 抖动（手机省电、
///   空口重传）只让一部分帧慢。真机实测（iPhone 经 Wi-Fi，1 Mbps 几乎空载）：基线 30 ms，往返 p50 50、
///   p95 110 ms，「连续 3 帧超阈值」的判法在这上面一直报拥塞，码率钉死在 1 Mbps。
///   编码前丢帧（在途满了）**不算**拥塞：那只说明往返比帧间隔长，带宽真不够时延迟自己会涨上去。
/// - **恢复**：拥塞后静默 `stableInterval`，之后每 `increaseInterval` 往上调一档，先恢复帧率再加码率。
///   离上次出事的码率还远时 ×`increaseFactor` 快涨，到它上下 15% 以内 ×`probeFactor` 小步试探，
///   越过去了说明链路好转，接着快涨到上限：不能停在退避到的那一档。
///
/// 码率按局域网定（调研 §14）：低延迟 HEVC 在 2144×1206 的桌面上给多少都只用到 24–29 Mbps
///（约每像素 12 bit/s），从 10 Mbps 起步要白白糊几秒，起步就给到这个量。
nonisolated struct RemoteRateController: Equatable {
    struct Config: Equatable {
        var minBitrate: Int
        var maxBitrate: Int
        var decreaseFactor = 0.7
        var increaseFactor = 1.25
        var probeFactor = 1.08
        var decreaseSpacing: UInt64 = 500_000_000
        var stableInterval: UInt64 = 1_000_000_000
        var increaseInterval: UInt64 = 500_000_000
        var queueDelayThreshold: UInt64 = 60_000_000
        var congestionWindow: UInt64 = 300_000_000
        var samplesForCongestion = 3
        var baselineWindow: UInt64 = 10_000_000_000
        var fullFrameRate = 60
        var reducedFrameRate = 30
        var maxInflightFrames = 8
        var jitterMargin: UInt64 = 80_000_000
    }

    let config: Config
    private(set) var bitrate: Int
    private(set) var frameRate: Int
    private var lastDecrease: UInt64?
    private var lastCongestion: UInt64
    private var lastIncrease: UInt64
    /// 最近 `congestionWindow` 内的「采集 → 解码完」耗时。
    private var recent: [LatencySample] = []
    private var recentLostFrames: [UInt64] = []
    /// 上一轮拥塞开始时（第一次下调之前）的码率：涨回它附近就改成小步试探。一轮拥塞里会连降好几次，
    /// 记最后一次的话就成了底线附近，之后一路小步，涨回上限要几十秒。
    private var congestedBitrate: Int?
    /// 基线按两个半窗取最小：当前半窗与上一个半窗。旧的最小值最多留一个窗口，链路变了基线跟着变。
    private var baselineCurrent: UInt64?
    private var baselinePrevious: UInt64?
    private var baselineBucketStart: UInt64

    /// 起始码率按像素算：每像素 12 bit/s（2144×1206 ≈ 31 Mbps，低延迟编码器在桌面内容上用得到的量），
    /// 局域网轻松给得起；链路真吃紧时由拥塞控制往下压。上限每像素 24 bit/s（更复杂的画面留余量），下限 1 Mbps。
    static func config(width: Int, height: Int) -> Config {
        let pixels = max(1, width * height)
        return Config(minBitrate: 1_000_000, maxBitrate: max(2_000_000, pixels * 24))
    }

    /// 公网路径的配置：上限不变（不设固定额度），在途帧放宽到按字节算的带宽时延积说了算，否则
    /// 往返 200 ms 时被 8 帧卡在 40 fps。
    static func config(width: Int, height: Int, path: RemoteLinkPath) -> Config {
        var config = config(width: width, height: height)
        if path.isInternet { config.maxInflightFrames = 30 }
        return config
    }

    /// 公网起始码率：局域网那个起点（2144×1206 约 31 Mbps）在蜂窝和跨省链路上一开始就是几秒的排队。
    /// 从这里起步，链路空着再由码控往上涨。
    static let internetInitialBitrate = 6_000_000

    static func initialBitrate(width: Int, height: Int, path: RemoteLinkPath) -> Int {
        let bitrate = initialBitrate(width: width, height: height)
        return path.isInternet ? min(bitrate, internetInitialBitrate) : bitrate
    }

    static func initialBitrate(width: Int, height: Int) -> Int {
        let config = config(width: width, height: height)
        return min(config.maxBitrate, max(config.minBitrate, width * height * 12))
    }

    init(config: Config, initialBitrate: Int, now: UInt64) {
        self.config = config
        bitrate = min(config.maxBitrate, max(config.minBitrate, initialBitrate))
        frameRate = config.fullFrameRate
        lastCongestion = now
        lastIncrease = now
        baselineBucketStart = now
    }

    init(width: Int, height: Int, path: RemoteLinkPath = .localNetwork, now: UInt64) {
        self.init(config: Self.config(width: width, height: height, path: path),
                  initialBitrate: Self.initialBitrate(width: width, height: height, path: path), now: now)
    }

    /// 链路空着时的「采集 → 解码完」耗时；还没有确认时为 nil。
    var baselineLatency: UInt64? {
        switch (baselineCurrent, baselinePrevious) {
        case let (current?, previous?): return min(current, previous)
        case let (current, previous): return current ?? previous
        }
    }

    /// 在途帧数上限：一个往返（基线再加 `jitterMargin` 的 Wi-Fi 抖动）里能送出去的帧数 + 1，
    /// 至少 2、至多 `maxInflightFrames`。
    ///
    /// 余量要盖住确认回程的抖动：确认是手机经 Wi-Fi 上行发回来的小包，手机省电时会被攒着晚到，画面本身
    /// 早就到了。真机（基线 30、p50 50、p95 110 ms）：上限 4 帧时每 2 s 因在途满丢 10–19 帧、实发约 50 fps；
    /// 放到 8 帧丢帧归零、实发 55–57 fps，往返 p50 / p95 不变——说明没有排队，只是确认晚到。
    var inflightFrameLimit: Int {
        let interval = 1_000_000_000 / UInt64(max(1, frameRate))
        guard let baseline = baselineLatency else { return 2 }
        let frames = Int((baseline + config.jitterMargin + interval - 1) / interval) + 1
        return min(config.maxInflightFrames, max(2, frames))
    }

    /// 在途字节上限：目标码率下同一段时间里该发出去的量，至少 `RemoteDesktopPacer.defaultInflightBytes`。
    var inflightByteLimit: Int {
        let defaultLimit = RemoteDesktopPacer<Int>.defaultInflightBytes
        guard let baseline = baselineLatency else { return defaultLimit }
        let window = Double(baseline + config.jitterMargin) / 1e9
        return max(defaultLimit, Int(Double(bitrate) / 8 * window))
    }

    /// 报一次拥塞。返回码率或帧率有没有变。
    @discardableResult
    mutating func congestion(now: UInt64) -> Bool {
        let newEpisode = now &- lastCongestion >= config.stableInterval || congestedBitrate == nil
        lastCongestion = now
        if let lastDecrease, now &- lastDecrease < config.decreaseSpacing { return false }
        lastDecrease = now
        if bitrate > config.minBitrate {
            if newEpisode { congestedBitrate = bitrate }
            bitrate = max(config.minBitrate, Int(Double(bitrate) * config.decreaseFactor))
            return true
        }
        if frameRate > config.reducedFrameRate {
            frameRate = config.reducedFrameRate
            return true
        }
        return false
    }

    /// 链路丢包率。随机丢包有重传和纠错兜着，不降码率；丢到这个份上才当拥塞（多半撞上了限速）。
    static let heavyLossRate = 0.20

    @discardableResult
    mutating func observeLoss(lossRate: Double, now: UInt64) -> Bool {
        guard lossRate >= Self.heavyLossRate else { return false }
        return congestion(now: now)
    }

    /// 视频帧等到时限也没收齐。零星一帧是突发丢包，恢复一下就好；一秒内连着丢说明这个码率这条链路扛不住。
    @discardableResult
    mutating func observeLostFrames(count: Int, now: UInt64) -> Bool {
        recentLostFrames.removeAll { now &- $0 > 1_000_000_000 }
        recentLostFrames.append(contentsOf: repeatElement(now, count: count))
        guard recentLostFrames.count >= RemoteLossPolicy.lostFramesForCongestion else { return false }
        recentLostFrames.removeAll()
        return congestion(now: now)
    }

    private struct LatencySample: Equatable {
        var nanos: UInt64
        var latency: UInt64
    }

    /// 一帧的「采集 → 手机解码完」耗时。最近一小段里最快的一帧都排着队，才算拥塞。
    @discardableResult
    mutating func observe(latencyNanos: UInt64, now: UInt64) -> Bool {
        updateBaseline(latencyNanos, now: now)
        recent.removeAll { now &- $0.nanos > config.congestionWindow }
        recent.append(LatencySample(nanos: now, latency: latencyNanos))
        let fastest = recent.lazy.map(\.latency).min() ?? latencyNanos
        let queueDelay = fastest &- (baselineLatency ?? fastest)
        guard recent.count >= config.samplesForCongestion, queueDelay > config.queueDelayThreshold else {
            return queueDelay > config.queueDelayThreshold ? false : tick(now: now)
        }
        // 这一段已经判过了：清掉，下一次要靠新样本重新攒够。
        recent.removeAll()
        return congestion(now: now)
    }

    private mutating func updateBaseline(_ latency: UInt64, now: UInt64) {
        if now &- baselineBucketStart >= config.baselineWindow / 2 {
            baselinePrevious = baselineCurrent
            baselineCurrent = nil
            baselineBucketStart = now
        }
        baselineCurrent = min(baselineCurrent ?? latency, latency)
    }

    /// 定期调用（每次确认时顺带）：拥塞后静默够久就往上调。返回有没有变。
    @discardableResult
    mutating func tick(now: UInt64) -> Bool {
        guard now &- lastCongestion >= config.stableInterval, now &- lastIncrease >= config.increaseInterval else {
            return false
        }
        lastIncrease = now
        if frameRate < config.fullFrameRate {
            frameRate = config.fullFrameRate
            return true
        }
        guard bitrate < config.maxBitrate else { return false }
        let probing = congestedBitrate.map {
            (Double($0) * 0.85..<Double($0) * 1.15).contains(Double(bitrate))
        } ?? false
        let factor = probing ? config.probeFactor : config.increaseFactor
        bitrate = min(config.maxBitrate, max(bitrate + 1, Int(Double(bitrate) * factor)))
        return true
    }
}

/// 主流编码的 QP 上限：让低延迟编码器把码率预算用上，又不透支。
///
/// 低延迟码控自己选的 QP 偏高，码率给多少都只用一点（实测 2600×1462、目标 90 Mbps、滚动终端文字：
/// 不设上限每帧 3–4 KB、约 1–2 Mbps，字是糊的；上限 30 时每帧 18 KB 且不丢帧）。但上限一压，编码器就按它出帧、
/// 不管预算：复杂画面上每帧近 1 MB，透支的码率要靠之后连续丢帧还，写回 51 放开后还要丢好几秒（实测 50 Mbps 下
/// 丢一半帧超过 4 s）。写 nil 清属性不管用。所以上限只能小步收、一超就退：
/// - 起步不限。每 `window` 结算：没丢帧、样本够、实发不到目标码率一半，收紧一档（不限时直接到 `relaxed`）。
/// - 非关键帧大过每帧预算的 `oversizeFactor` 倍、或一个窗口里码控丢到 `dropsToRaise` 帧：**当场**放宽 `raiseStep`
///  （到 `relaxed` 以上就不限），重新计窗。画面一下变复杂时一两帧之内退开，不攒成透支。
/// - 码率控制报拥塞时同样放宽。
nonisolated struct RemoteQualityCap: Equatable {
    static let floor = 24
    static let relaxed = 40
    static let unrestricted = 51
    static let raiseStep = 3
    static let dropsToRaise = 3
    static let oversizeFactor = 1.5
    static let window: UInt64 = 500_000_000
    static let minFramesToTighten = 10

    private(set) var maxQP = Self.unrestricted
    private var windowStart: UInt64
    private var frames = 0
    private var drops = 0
    private var bytes = 0

    init(now: UInt64) {
        windowStart = now
    }

    /// 编码器出了一帧（`bytes`）或丢了一帧（nil）。返回上限有没有变。
    @discardableResult
    mutating func record(encodedBytes: Int?, keyframe: Bool = false, targetBitrate: Int, frameRate: Int,
                         now: UInt64) -> Bool {
        frames += 1
        if let encodedBytes { bytes += encodedBytes } else { drops += 1 }
        let frameBudget = Double(targetBitrate) / 8 / Double(max(1, frameRate))
        let oversize = !keyframe && Double(encodedBytes ?? 0) > frameBudget * Self.oversizeFactor
        if oversize || drops >= Self.dropsToRaise {
            restartWindow(now)
            return raise()
        }
        let elapsed = now &- windowStart
        guard elapsed >= Self.window else { return false }
        defer { restartWindow(now) }
        let sentBitrate = Double(bytes) * 8 / (Double(elapsed) / 1e9)
        guard drops == 0, frames >= Self.minFramesToTighten, sentBitrate < Double(targetBitrate) / 2,
              maxQP > Self.floor else { return false }
        maxQP = min(maxQP, Self.relaxed + 1) - 1
        return true
    }

    /// 链路拥塞：放宽。
    @discardableResult
    mutating func congestion() -> Bool { raise() }

    private mutating func restartWindow(_ now: UInt64) {
        windowStart = now
        frames = 0
        drops = 0
        bytes = 0
    }

    private mutating func raise() -> Bool {
        guard maxQP < Self.unrestricted else { return false }
        maxQP = maxQP + Self.raiseStep > Self.relaxed ? Self.unrestricted : maxQP + Self.raiseStep
        return true
    }
}

/// 尺寸与坐标换算。
nonisolated enum RemoteDesktopGeometry {
    /// 视频尺寸：把显示器的像素尺寸等比塞进手机要的框（框按显示器的横竖摆），不放大，宽高取偶数
    ///（4:2:0 色度按 2×2 采样，奇数尺寸编码器会自己补边，解出来多一列杂色）。
    static func streamSize(displayPixels: CGSize, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        guard displayPixels.width > 0, displayPixels.height > 0 else { return (0, 0) }
        let long = CGFloat(max(maxWidth, maxHeight)), short = CGFloat(max(1, min(maxWidth, maxHeight)))
        let landscape = displayPixels.width >= displayPixels.height
        let box = landscape ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
        let scale = min(1, box.width / displayPixels.width, box.height / displayPixels.height)
        // 先四舍五入再取偶：1964 × (1206 / 1964) 在浮点里是 1205.999…，直接截断会白丢 2 像素。
        func even(_ value: CGFloat, limit: CGFloat) -> Int { max(64, min(Int(value.rounded()), Int(limit)) & ~1) }
        return (even(displayPixels.width * scale, limit: displayPixels.width),
                even(displayPixels.height * scale, limit: displayPixels.height))
    }

    /// 采集尺寸：显示器原生像素按整数倍缩小、且两边都不小于视频尺寸的那一档。
    ///
    /// ScreenCaptureKit 自己缩放的质量与双线性相当，非整数倍缩小时细字发软、滚动时闪烁；整数倍（2 倍 =
    /// 每 2×2 取平均）是干净的。剩下的那一截由 `RemoteFrameScaler` 用 Lanczos 缩（调研 §14.5）。
    /// 5120×2880 → 视频 2144×1206：采 2560×1440；3024×1964 → 1856×1206：不足 2 倍，采原生。
    static func captureSize(displayPixels: CGSize, stream: (width: Int, height: Int)) -> (width: Int, height: Int) {
        guard stream.width > 0, stream.height > 0, displayPixels.width > 0, displayPixels.height > 0 else { return stream }
        let ratio = min(displayPixels.width / CGFloat(stream.width), displayPixels.height / CGFloat(stream.height))
        let divisor = max(1, Int(ratio.rounded(.down)))
        let width = max(stream.width, Int(displayPixels.width) / divisor)
        let height = max(stream.height, Int(displayPixels.height) / divisor)
        return (width & ~1, height & ~1)
    }

    /// 归一化坐标 → Mac 全局坐标（左上角原点、单位是点，`CGEvent` 用的那套）。夹在显示器内：
    /// 指针贴到最右 / 最下时停在最后一个点上，不会跑到旁边那块屏去。
    static func globalPoint(x: Float, y: Float, displayBounds: CGRect) -> CGPoint {
        let nx = CGFloat(min(1, max(0, x.isFinite ? x : 0)))
        let ny = CGFloat(min(1, max(0, y.isFinite ? y : 0)))
        let px = displayBounds.minX + min(displayBounds.width - 1, nx * displayBounds.width)
        let py = displayBounds.minY + min(displayBounds.height - 1, ny * displayBounds.height)
        return CGPoint(x: px, y: py)
    }

    /// Mac 全局坐标 → 归一化（光标回报用）。
    static func normalized(_ point: CGPoint, displayBounds: CGRect) -> (x: Float, y: Float) {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return (0, 0) }
        let x = (point.x - displayBounds.minX) / displayBounds.width
        let y = (point.y - displayBounds.minY) / displayBounds.height
        return (Float(min(1, max(0, x))), Float(min(1, max(0, y))))
    }
}

/// 手机上看桌面的视口：整块显示器按 `zoom` 放大后，视图里露出哪一块。
///
/// `zoom == 1` 是「适配屏幕」（整块显示器完整放进视图，留黑边）。`center` 是可见区域中心在显示器上的
/// 归一化坐标。放大后拖不出显示器边界；某个方向内容比视图小时那个方向居中。
/// 允许缩到适配以下（`minZoom`）：边缘落在圆角 / 开孔附近时，缩小一点才看得全、点得着。
nonisolated struct RemoteDesktopViewport: Equatable {
    static let minZoom: CGFloat = 0.5
    static let maxZoom: CGFloat = 8

    /// 显示器的点尺寸（只用纵横比与相对大小）。
    var contentSize: CGSize
    var viewSize: CGSize
    private(set) var zoom: CGFloat = 1
    private(set) var center = CGPoint(x: 0.5, y: 0.5)

    init(contentSize: CGSize, viewSize: CGSize) {
        self.contentSize = contentSize
        self.viewSize = viewSize
    }

    /// 适配时每个显示器点占多少视图点。
    var fitScale: CGFloat {
        guard contentSize.width > 0, contentSize.height > 0 else { return 1 }
        return min(viewSize.width / contentSize.width, viewSize.height / contentSize.height)
    }

    var scale: CGFloat { fitScale * zoom }

    /// 整块显示器在视图坐标里的位置与大小（画面就画在这里）。
    var contentFrame: CGRect {
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        let origin = CGPoint(x: viewSize.width / 2 - center.x * size.width,
                             y: viewSize.height / 2 - center.y * size.height)
        return CGRect(origin: origin, size: size)
    }

    func viewPoint(normalized point: CGPoint) -> CGPoint {
        let frame = contentFrame
        return CGPoint(x: frame.minX + point.x * frame.width, y: frame.minY + point.y * frame.height)
    }

    /// 视图点 → 归一化坐标（不夹：点到黑边上会 <0 或 >1，由调用方决定怎么处理）。
    func normalized(viewPoint point: CGPoint) -> CGPoint {
        let frame = contentFrame
        guard frame.width > 0, frame.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
    }

    /// 以视图上的 `anchor` 为不动点缩放（捏合）。
    mutating func zoom(by factor: CGFloat, anchor: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let fixed = normalized(viewPoint: anchor)
        zoom = min(Self.maxZoom, max(Self.minZoom, zoom * factor))
        // 缩放后让 fixed 仍落在 anchor 下面。
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        guard size.width > 0, size.height > 0 else { return }
        center = CGPoint(x: fixed.x - (anchor.x - viewSize.width / 2) / size.width,
                         y: fixed.y - (anchor.y - viewSize.height / 2) / size.height)
        clamp()
    }

    mutating func setZoom(_ value: CGFloat) {
        zoom = min(Self.maxZoom, max(Self.minZoom, value))
        clamp()
    }

    /// 拖动画面（视图点）。手指往右拖，看到的是左边的内容。
    mutating func pan(by delta: CGSize) {
        let frame = contentFrame
        guard frame.width > 0, frame.height > 0 else { return }
        center.x -= delta.width / frame.width
        center.y -= delta.height / frame.height
        clamp()
    }

    /// 回到适配屏幕。
    mutating func reset() {
        zoom = 1
        center = CGPoint(x: 0.5, y: 0.5)
    }

    /// 让某个归一化点留在可见区内（离边至少 `margin` 视图点）：放大后指针走到边上，画面跟着走。
    mutating func ensureVisible(_ point: CGPoint, margin: CGFloat) {
        let frame = contentFrame
        guard frame.width > 0, frame.height > 0 else { return }
        let view = viewPoint(normalized: point)
        let insetX = min(margin, viewSize.width / 2), insetY = min(margin, viewSize.height / 2)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if view.x < insetX { dx = view.x - insetX } else if view.x > viewSize.width - insetX { dx = view.x - (viewSize.width - insetX) }
        if view.y < insetY { dy = view.y - insetY } else if view.y > viewSize.height - insetY { dy = view.y - (viewSize.height - insetY) }
        guard dx != 0 || dy != 0 else { return }
        center.x += dx / frame.width
        center.y += dy / frame.height
        clamp()
    }

    /// 把归一化点收进可见区，留的边距和 `ensureVisible` 一样，之后移动光标画面才不会跳。
    /// 显示器的边已经露出来的那一侧不留边距：光标本来就能走到那里。
    func keepingVisible(_ point: CGPoint, margin: CGFloat) -> CGPoint {
        let frame = contentFrame
        func axis(_ value: CGFloat, origin: CGFloat, length: CGFloat, view: CGFloat) -> CGFloat {
            guard length > view else { return value }
            let inset = min(margin, view / 2)
            let low = origin < 0 ? (inset - origin) / length : 0
            let high = origin + length > view ? (view - inset - origin) / length : 1
            return min(high, max(low, value))
        }
        return CGPoint(x: axis(point.x, origin: frame.minX, length: frame.width, view: viewSize.width),
                       y: axis(point.y, origin: frame.minY, length: frame.height, view: viewSize.height))
    }

    /// 内容比视图大的方向不让拖出边界，比视图小的方向居中。
    mutating func clamp() {
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        func axis(_ value: CGFloat, content: CGFloat, view: CGFloat) -> CGFloat {
            guard content > view, content > 0 else { return 0.5 }
            let half = view / 2 / content
            return min(1 - half, max(half, value))
        }
        center = CGPoint(x: axis(center.x, content: size.width, view: viewSize.width),
                         y: axis(center.y, content: size.height, view: viewSize.height))
    }
}

/// 触控板式指针：手指相对移动 → 指针在显示器上的相对移动。
nonisolated enum RemoteTrackpad {
    /// 手指移动 `delta`（视图点），速度 `speed`（视图点/秒）。
    ///
    /// 换算到显示器点时除以视口比例（放大后同样的手指位移走得更细），再乘一个随速度增长的加速系数：
    /// 慢移精确到像素，快甩一下能横穿整屏。结果夹在显示器内。
    static func advance(_ pointer: CGPoint, by delta: CGSize, speed: CGFloat,
                        viewport: RemoteDesktopViewport) -> CGPoint {
        let scale = viewport.scale
        guard scale > 0, viewport.contentSize.width > 0, viewport.contentSize.height > 0 else { return pointer }
        let gain = acceleration(speed: speed)
        let dx = delta.width / scale * gain / viewport.contentSize.width
        let dy = delta.height / scale * gain / viewport.contentSize.height
        return CGPoint(x: min(1, max(0, pointer.x + dx)), y: min(1, max(0, pointer.y + dy)))
    }

    /// 指针增益：≤40 点/秒 减到一半（精确点中小目标），到 150 点/秒 回到 1，之后线性增长，最大 2.5 倍。
    static func acceleration(speed: CGFloat) -> CGFloat {
        let v = max(0, speed.isFinite ? speed : 0)
        if v < 150 { return 0.5 + 0.5 * max(0, v - 40) / 110 }
        return min(2.5, 1 + (v - 150) / 800)
    }

    /// 拖拽时手指停在视图边缘：光标继续朝这条边走的速度（视图点/秒），越贴边越快。不在边缘时为零。
    static func edgeVelocity(at location: CGPoint, in viewSize: CGSize, zone: CGFloat = 32,
                             maxSpeed: CGFloat = 400) -> CGSize {
        func axis(_ value: CGFloat, length: CGFloat) -> CGFloat {
            guard length > zone * 2 else { return 0 }
            if value < zone { return -maxSpeed * (zone - value) / zone }
            if value > length - zone { return maxSpeed * (value - (length - zone)) / zone }
            return 0
        }
        return CGSize(width: axis(location.x, length: viewSize.width),
                      height: axis(location.y, length: viewSize.height))
    }
}
