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
    /// 链路节奏给的目标上限（见 `linkHeadroom`）；nil = 没有链路节奏（局域网、中继）。
    private(set) var linkCeiling: Int?
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
    /// 局域网轻松给得起；链路真吃紧时由拥塞控制往下压。上限每像素 24 bit/s（更复杂的画面留余量），封顶
    /// `absoluteMaxBitrate`；下限见 `minimumBitrate`。
    static func config(width: Int, height: Int) -> Config {
        let pixels = max(1, width * height)
        return Config(minBitrate: minimumBitrate(pixels: pixels),
                      maxBitrate: min(absoluteMaxBitrate, max(2_000_000, pixels * 24)))
    }

    /// 码率上限的绝对值。按像素算的上限在大屏上离谱：5120×2880 的虚拟屏是 353.9 Mbps，局域网上没有链路节奏
    /// 兜底，这个数会原样交给编码器，要等延迟涨起来才往下压（2026-11-09 真机 931 读数）。
    static let absoluteMaxBitrate = 150_000_000

    /// 有链路节奏时目标码率最多是视频份额（`RemoteLossPolicy.videoShare`）的这么多倍。
    ///
    /// 直连上编码器拿的是 min(目标, 视频份额)，延迟一直低，目标就每 0.5 s 乘 1.25 涨到上限停着（5K 虚拟屏
    /// 353.9 Mbps，链路才 60 Mbps）。码控行显示的目标因此没有参考价值，拥塞时按 0.7 倍往下压也压不到编码器
    /// 头上——要连降好几次才降到链路以下。留 1.25 倍：链路一变宽，编码器马上跟得上。
    static let linkHeadroom = 1.25

    /// 码率下限：每像素 1 bit/s，夹在 2–8 Mbps（1920×1080 约 2 Mbps、2600×1462 约 3.8 Mbps、3840×2160 8 Mbps）。
    ///
    /// 以前一律 1 Mbps：真机 3840×2160 公网直连被压到 1.2–2 Mbps，QP 一直顶在 51，一动就糊成色块。下限只管
    /// 「采集 → 解码完」这条信号能压到多低；链路真扛不住时，编码器拿到的是链路实测节奏（`linkShare`）与它取小，
    /// 下限再高也不会多发。
    static func minimumBitrate(pixels: Int) -> Int {
        min(maxMinimumBitrate, max(minMinimumBitrate, pixels))
    }

    static let minMinimumBitrate = 2_000_000
    static let maxMinimumBitrate = 8_000_000
    /// 没有链路节奏兜底时（中继转发的 TCP：视频不走数据报）的下限。那里「采集 → 解码完」是唯一的拥塞信号，
    /// 下限定高了，窄链路上就是一直排着几秒的队。
    static let unpacedMinimumBitrate = 1_000_000

    /// 按路径的配置。公网上限不变（不设固定额度），在途帧放宽到按字节算的带宽时延积说了算，否则
    /// 往返 200 ms 时被 8 帧卡在 40 fps。`paced`：视频走数据报、有链路节奏兜底。公网上没有它时下限退回
    /// `unpacedMinimumBitrate`。
    static func config(width: Int, height: Int, path: RemoteLinkPath, paced: Bool = false) -> Config {
        var config = config(width: width, height: height)
        if path.isInternet {
            config.maxInflightFrames = 30
            if !paced { config.minBitrate = unpacedMinimumBitrate }
        }
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

    init(width: Int, height: Int, path: RemoteLinkPath = .localNetwork, paced: Bool = false, now: UInt64) {
        self.init(config: Self.config(width: width, height: height, path: path, paced: paced),
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
    ///
    /// `linkQueueing`：链路层（`RemoteLinkEstimator`）此刻量没量到网络排队；nil = 没有链路层估计（局域网 TCP、
    /// 中继转发），只能靠这条信号。有估计、且它说网络没排队时，帧耗时再高也不降码率：多出来的是自己的大帧
    /// （关键帧、旁路精修）在发送队列里排着、或者确认在 Wi-Fi 上行晚到，降码率既治不了也只会让画面糊。
    /// 真机 3840×2160 公网直连：链路 丢包 0%、往返 27–85 ms，帧往返 p95 却 1.1–2 s，码率被一路压到 1.2 Mbps。
    /// 网络真排队时链路层自己会退节奏（编码器拿到的码率跟着节奏走），也会让这里照旧降。
    @discardableResult
    mutating func observe(latencyNanos: UInt64, now: UInt64, linkQueueing: Bool? = nil) -> Bool {
        updateBaseline(latencyNanos, now: now)
        recent.removeAll { now &- $0.nanos > config.congestionWindow }
        recent.append(LatencySample(nanos: now, latency: latencyNanos))
        let fastest = recent.lazy.map(\.latency).min() ?? latencyNanos
        let queueDelay = fastest &- (baselineLatency ?? fastest)
        guard recent.count >= config.samplesForCongestion, queueDelay > config.queueDelayThreshold else {
            return queueDelay > config.queueDelayThreshold ? false : tick(now: now)
        }
        // 排队不在网络上：不当拥塞。照常往上试——编码器拿到的码率还受链路节奏管着，涨的只是这条信号的上限。
        guard linkQueueing != false else { return tick(now: now) }
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

    /// 链路节奏变了：目标最多是视频份额的 `linkHeadroom` 倍，但不低于下限。返回目标有没有被往下拉——
    /// 这是跟着链路走，不是拥塞，调用方别把它当降码率处理（画质上限不收紧）。
    @discardableResult
    mutating func capToLink(videoShare: Double) -> Bool {
        let ceiling = max(config.minBitrate, Int(videoShare * Self.linkHeadroom))
        linkCeiling = ceiling
        guard bitrate > ceiling else { return false }
        bitrate = ceiling
        return true
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
        let limit = min(config.maxBitrate, linkCeiling ?? config.maxBitrate)
        guard bitrate < limit else { return false }
        let probing = congestedBitrate.map {
            (Double($0) * 0.85..<Double($0) * 1.15).contains(Double(bitrate))
        } ?? false
        let factor = probing ? config.probeFactor : config.increaseFactor
        bitrate = min(limit, max(bitrate + 1, Int(Double(bitrate) * factor)))
        return true
    }
}

/// 告诉编码器的帧率（`ExpectedFrameRate`）：按实际送进编码器的主流帧率，平滑过、隔一阵才改一次。
///
/// 送进编码器的帧 ≤ 采集的帧：在途满了的画面编码前就丢（`RemoteDesktopPacer`）。宽链路上两者一样；窄链路上
/// （3G 0.75 Mbps，采集 30 fps 只送得进几帧）按采集报会让每帧预算小到装不下任何一帧（2026-11-09）。
///
/// 低延迟码控按「码率 ÷ 预期帧率」给每帧分预算。一直报 60 fps 而画面每秒只变 6 次时，每帧只分到十分之一，
/// 稍大一点的帧（恢复帧、一个窗口整片刷新）就被编码器整帧丢掉（2026-11-08 mini：采集 6 fps，丢 3 出 1）。
/// - 采集间隔按指数平均；静止的长间隔按 `maxInterval` 算，一段静止不会把帧率拉到 0。
/// - 快升慢降：间隔变短（画面动起来了）按 `attack` 快跟、立刻写给编码器——报低了每帧预算偏大，满屏在变时
///   一帧比一帧大、链路排队；间隔变长按 `smoothing` 慢跟，离上次改不到 `minChangeInterval`、差不到
///   `changeRatio` 不改，别每帧都去动编码器。
/// - 报给编码器的是采集帧率的 `headroom` 倍：如实报时，画面每帧都在变（30 fps 满屏细节）每帧预算翻倍、帧变大、
///   码控丢得更多，显示帧数少两成（随机丢包闸门 188 vs 233）。留一倍余量后 30 fps 仍报 60，跟以前一样；
///   6 fps 报 12，每帧预算比报 60 时大五倍，恢复帧不再被整帧丢掉。
/// - 结果夹在 `[floor, 码控帧率]`：帧太少时也不让一帧独吞好几秒的预算（一帧要发那么久，延迟就上去了）。
nonisolated struct RemoteEncoderFrameRate: Equatable {
    static let smoothing = 0.2
    static let attack = 0.5
    static let maxInterval: UInt64 = 1_000_000_000
    static let floor = 5
    static let headroom = 2.0
    static let changeRatio = 0.2
    static let minChangeInterval: UInt64 = 1_000_000_000

    private var lastCapture: UInt64?
    private var interval: Double?
    private var lastChange: UInt64 = 0
    /// 当前告诉编码器的帧率（nil = 还没定过，用码控帧率）。
    private(set) var applied: Int?

    /// 送了一帧进编码器。
    mutating func record(now: UInt64) {
        defer { lastCapture = now }
        guard let lastCapture else { return }
        let gap = Double(min(now &- lastCapture, Self.maxInterval))
        interval = interval.map { $0 + (gap - $0) * (gap < $0 ? Self.attack : Self.smoothing) } ?? gap
    }

    /// 给编码器的帧率；`limit` = 码控现在允许的帧率。返回值跟上次不同才需要写给编码器。
    mutating func expected(limit: Int, now: UInt64) -> Int {
        let ceiling = max(1, limit)
        guard let interval, interval > 0 else { return applied.map { min($0, ceiling) } ?? ceiling }
        let measured = min(ceiling, max(min(Self.floor, ceiling), Int((Self.headroom * 1e9 / interval).rounded())))
        guard let current = applied else {
            applied = measured
            lastChange = now
            return measured
        }
        // 画面动快了、或码控把帧率压下去了：立刻跟。
        if measured > current || current > ceiling {
            applied = measured
            lastChange = now
            return measured
        }
        guard now &- lastChange >= Self.minChangeInterval,
              abs(Double(measured - current)) >= Double(current) * Self.changeRatio else { return current }
        applied = measured
        lastChange = now
        return measured
    }
}

/// 主流编码的 QP 上限：让低延迟编码器把码率预算用上，又不透支。
///
/// 低延迟码控自己选的 QP 偏高，码率给多少都只用一点（实测 2600×1462、目标 90 Mbps、滚动终端文字：
/// 不设上限每帧 3–4 KB、约 1–2 Mbps，字是糊的；上限 30 时每帧 18 KB 且不丢帧）。但上限一压，编码器就按它出帧、
/// 不管预算：复杂画面上每帧近 1 MB，透支的码率要靠之后连续丢帧还，写回 51 放开后还要丢好几秒（实测 50 Mbps 下
/// 丢一半帧超过 4 s）。写 nil 清属性不管用。所以上限只能小步收、一超就退：
/// - 起步不限。每 `window` 结算：没丢帧、窗口里出过帧、实发不到目标码率一半，收紧一档（不限时直接到 `relaxed`）。
///   帧少不是不收的理由：屏幕上只有光标闪、时钟走时每秒只采到 3–5 帧，以前要求半秒 10 帧就永远收不紧，
///   上限卡在开头那档，静止的字一直是关键帧那张的糊样子（真机 3840×2160、目标 199 Mbps、实发 4–9 Mbps、
///   上限停在 37）。帧少时每帧分到的预算反而宽，收紧之后画面一动、单帧超预算就当场退开。
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
    static let minFramesToTighten = 1

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

/// 只看一个窗口时，请 Mac 把窗口调成多大。
///
/// 窗口的点数和画布一样时，窗口里的字在设备上和在 Mac 上一样大（Mac 的 13 pt 就是这里的 13 pt）。想让字更大，
/// 就让窗口比画布小：窗口里排得下的内容少了，整个画面放大铺满画布，字跟着变大。App 有最小窗口尺寸
///（2026-11-17：Chrome 500×375、Xcode 400×350、Claude 600×400），要的比它小时得到的是它的最小尺寸。
nonisolated enum RemoteDesktopWindowFit {
    /// 可选的字的大小：窗口的点数 = 画布的点数 ÷ 它。
    static let textScales: [Double] = [0.8, 1, 1.25, 1.5]

    /// 「最清晰」：Mac 的像素和主控端屏幕的像素一一对应，不经放大。存的是这个记号，用的时候按主控端的屏幕换算
    /// （`scale(for:displayScale:)`）。默认就是它（user 定，2026-11-18）：标准字号下窗口只有每点 2 个像素，
    /// 手机每点 3 个，放大 1.5 倍后达不到手机原生的清晰度。
    static let sharpest = 0.0
    static let defaultTextScale = sharpest
    /// Mac 的视网膜屏每个点 2 个像素。窗口在非视网膜的外接屏上时对不上（那时每点 1 个像素），主控端无从知道。
    static let macPixelsPerPoint = 2.0

    /// 存下来的字号 → 实际的比例。「最清晰」= Mac 每点的像素数 ÷ 主控端每点的像素数：手机（3 倍屏）上是 2/3，
    /// 窗口是画布的 1.5 倍大、字是标准的三分之二；2 倍屏的 iPad 上就是 1，和「标准」一样。
    static func scale(for stored: Double, displayScale: Double) -> Double {
        stored == sharpest ? macPixelsPerPoint / max(1, displayScale) : stored
    }

    /// 按存下来的字号（可能是「最清晰」）算窗口该多大。
    ///
    /// 「最清晰」按像素算、往下取整：窗口的像素数不超过画布的像素数（画布 2853×2007 像素 → 窗口 1426×1003 点 =
    /// 2852×2006 像素）。多出一个像素，Mac 就得把整帧缩一丝、手机再拉回去，一比一就没了。
    static func size(canvas: CGSize, textScale: Double, displayScale: Double) -> CGSize? {
        guard textScale == sharpest, displayScale >= 1, canvas.width > 0, canvas.height > 0 else {
            return size(canvas: canvas, textScale: scale(for: textScale, displayScale: displayScale))
        }
        // 先把画布的像素数取整再除：951 × 3 在浮点里可能差一丝，直接往下取整会白丢一个点。
        return CGSize(width: ((canvas.width * displayScale).rounded() / macPixelsPerPoint).rounded(.down),
                      height: ((canvas.height * displayScale).rounded() / macPixelsPerPoint).rounded(.down))
    }

    static func size(canvas: CGSize, textScale: Double) -> CGSize? {
        guard canvas.width > 0, canvas.height > 0, textScale.isFinite else { return nil }
        let scale = min(2, max(0.5, textScale))
        return CGSize(width: (canvas.width / scale).rounded(), height: (canvas.height / scale).rounded())
    }
}

/// 主控端放大后，Mac 该取哪一块画面。
///
/// 视频帧的像素数是固定的，比被看的那块显示器的原生像素少（手机的屏幕没那么多像素）。整块取时是缩小了的；
/// 放大后只看得见一小块，改成只取那一小块，同样的像素数就能按原生像素给，字是锐的（调研 §14.1：放大 2 倍时
/// 27.1 dB → 37.4 dB）。
nonisolated enum RemoteDesktopRegionPolicy {
    /// 取的范围比看得见的每边多出这么多（占看得见的宽高）：手指拖一小段不用等新画面。
    static let margin = 0.25
    /// 要取的范围快到整块了（任一边达到这个比例）就还是取整块。
    static let wholeThreshold = 0.9

    /// - Parameters:
    ///   - visible: 主控端此刻看得见的那一块。
    ///   - current: 现在取的那一块（nil = 整块）。它还罩得住、大小也对就不动，免得拖一点点就换。
    ///   - targetPixels: 被看的那块显示器（或窗口）的原生像素。
    ///   - stream: 视频帧的像素尺寸。
    /// - Returns: 要取的那一块；nil = 取整块。
    static func captureRegion(visible: RemoteDesktopRegion, current: RemoteDesktopRegion?, targetPixels: CGSize,
                              stream: (width: Int, height: Int)) -> RemoteDesktopRegion? {
        let targetWidth = Double(targetPixels.width), targetHeight = Double(targetPixels.height)
        guard let visible = visible.clamped, targetWidth > 0, targetHeight > 0, stream.width > 0, stream.height > 0 else {
            return nil
        }
        // 至少取视频帧那么多像素（一比一，不放大）；看得见的加上余量比它大就按后者，比例和视频帧一样。
        let aspect = Double(stream.width) / Double(stream.height)
        var width = max(Double(stream.width), visible.width * targetWidth * (1 + 2 * margin))
        var height = width / aspect
        let neededHeight = max(Double(stream.height), visible.height * targetHeight * (1 + 2 * margin))
        if height < neededHeight {
            height = neededHeight
            width = height * aspect
        }
        guard width < targetWidth * wholeThreshold, height < targetHeight * wholeThreshold else { return nil }
        if let current, abs(current.width * targetWidth - width) < 2, abs(current.height * targetHeight - height) < 2,
           current.contains(visible) {
            return current
        }
        // 落在整像素上、取偶数：一比一时每个原生像素正好对上视频帧的一个像素。
        func even(_ value: Double) -> Double { (value / 2).rounded() * 2 }
        width = min(even(width), even(targetWidth)); height = min(even(height), even(targetHeight))
        let x = min(max(0, even((visible.x + visible.width / 2) * targetWidth - width / 2)), targetWidth - width)
        let y = min(max(0, even((visible.y + visible.height / 2) * targetHeight - height / 2)), targetHeight - height)
        return RemoteDesktopRegion(x: x / targetWidth, y: y / targetHeight,
                                   width: width / targetWidth, height: height / targetHeight)
    }

    /// 放大到这个倍数以上主控端才向 Mac 要区域：只放大一点点时整块的画面够用，不值得换。
    static let zoomThreshold: CGFloat = 1.15

    /// 画面（整块显示器在视图里的位置）露在视图里的那一块，归一化到画面。没放大、或一点都没露出来时是 nil。
    static func visibleRegion(picture: CGRect, view: CGRect, zoom: CGFloat) -> RemoteDesktopRegion? {
        guard zoom >= zoomThreshold, picture.width > 0, picture.height > 0 else { return nil }
        let visible = picture.intersection(view)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return RemoteDesktopRegion(x: Double((visible.minX - picture.minX) / picture.width),
                                   y: Double((visible.minY - picture.minY) / picture.height),
                                   width: Double(visible.width / picture.width), height: Double(visible.height / picture.height))
    }

    /// 归一化的一块 → 采集帧里的像素矩形。`contentFraction`：只看一个窗口时内容只占帧的左上角一部分。
    static func pixelRect(_ region: RemoteDesktopRegion, frameSize: CGSize,
                          contentFraction: CGSize = CGSize(width: 1, height: 1)) -> CGRect {
        let contentWidth = Double(frameSize.width) * Double(contentFraction.width)
        let contentHeight = Double(frameSize.height) * Double(contentFraction.height)
        let x = (region.x * contentWidth).rounded(), y = (region.y * contentHeight).rounded()
        let width = max(2, (region.width * contentWidth).rounded()), height = max(2, (region.height * contentHeight).rounded())
        return CGRect(x: x, y: y, width: min(width, Double(frameSize.width) - x), height: min(height, Double(frameSize.height) - y))
    }
}

/// 手机上看桌面的视口：整块显示器按 `zoom` 放大后，视图里露出哪一块。
///
/// `zoom == 1` 是「适配屏幕」（整块显示器完整放进视图，留黑边）。`center` 是可见区域中心在显示器上的
/// 归一化坐标。放大后拖不出显示器边界；某个方向内容比视图小时那个方向居中（画面的角落进屏幕圆角时往黑边里挪，
/// 见 `RemoteDesktopCornerFit`）。
/// 缩放下限就是适配（`minZoom == 1`），不允许缩到适配以下：再缩只是四周多黑边、内容更小，
/// 主流远程桌面也都这么做。想看到更多应该改 Mac 端的输出分辨率，而不是缩画面。
nonisolated struct RemoteDesktopViewport: Equatable {
    static let minZoom: CGFloat = 1
    static let maxZoom: CGFloat = 8

    /// 显示器的点尺寸（只用纵横比与相对大小）。
    var contentSize: CGSize
    var viewSize: CGSize
    /// 视图四个角各自落在多大的圆角里（视图点）：画布铺到了屏幕 / 窗口的圆角里时由视图量出来。
    var corners: RemoteDesktopCornerRadii = .square
    /// 画面的角在黑边里挪也躲不开圆角时怎么办。false（Mac 窗口）：四边留一圈窄边、切同心圆角。
    /// true（手机）：照旧贴边铺满、直角，落进屏幕圆角的那一点由屏幕自己切掉——手机上要的是不留黑边
    /// （2026-11-15 Duo 实测：留的那圈 8pt 窄边被看成黑边，user 定「完全铺满」）。
    var bleedsIntoCorners = false
    private(set) var zoom: CGFloat = 1
    private(set) var center = CGPoint(x: 0.5, y: 0.5)

    /// 画面按原生像素一比一显示时该占多少点（视频里内容的像素数 ÷ 屏幕每点的像素数）。给了它、它放得进视图、
    /// 适配出来的大小又和它只差一丝（`snapTolerance`）时，就照它排、位置落在整像素上，不拉去铺满：
    /// 差一两个像素的拉伸会让画面中间的字偏半个像素，整片发糊（窗口模式「最清晰」要的就是一比一）。
    var nativeSize: CGSize?
    /// 屏幕每点几个像素（位置取整用）。
    var pixelsPerPoint: CGFloat = 1
    static let snapTolerance: CGFloat = 0.015

    /// 这时按原生像素排（见 `nativeSize`）；否则 nil。
    var snappedSize: CGSize? {
        guard let native = nativeSize, native.width > 0, native.height > 0, contentSize.width > 0, contentSize.height > 0,
              native.width <= viewSize.width + 0.01, native.height <= viewSize.height + 0.01 else { return nil }
        let fit = min(viewSize.width / contentSize.width, viewSize.height / contentSize.height)
        guard abs(native.width / contentSize.width / fit - 1) <= Self.snapTolerance,
              abs(native.height / contentSize.height / fit - 1) <= Self.snapTolerance else { return nil }
        return native
    }

    /// 贴边铺满时，显示器和视图的宽高比差在这个比例以内就把画面拉成视图的比例，整块铺满。
    /// 显示器的宽高比是对方按我们要的框定的，点数取整、顶栏高度在开流后又变了一点（出读数条），总会差一丝：
    /// 不拉的话这一丝就成了一条黑边，下角又进了屏幕圆角（2026-11-15 Duo 实测差 0.9%，底下 6pt 黑条）。
    /// 2% 的变形看不出来，触点照样按画面换算，点得准。
    static let stretchTolerance: CGFloat = 0.02

    init(contentSize: CGSize, viewSize: CGSize, corners: RemoteDesktopCornerRadii = .square,
         bleedsIntoCorners: Bool = false) {
        self.contentSize = contentSize
        self.viewSize = viewSize
        self.corners = corners
        self.bleedsIntoCorners = bleedsIntoCorners
    }

    /// 画面按这个点尺寸排：通常就是 `contentSize`；贴边铺满、宽高比和视图只差一丝时（`stretchTolerance`）
    /// 保留宽度、把高度拉到视图的比例。只用于排版，归一化坐标照旧对应整块显示器。
    var pictureSize: CGSize {
        if let native = snappedSize {
            // 乘上 `fitScale`（= 原生宽 ÷ 显示器宽）正好是原生大小。
            return CGSize(width: contentSize.width, height: native.height * contentSize.width / native.width)
        }
        guard bleedsIntoCorners, contentSize.width > 0, contentSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return contentSize }
        let viewAspect = viewSize.width / viewSize.height
        let ratio = (contentSize.width / contentSize.height) / viewAspect
        guard ratio != 1, abs(ratio - 1) <= Self.stretchTolerance else { return contentSize }
        return CGSize(width: contentSize.width, height: contentSize.width / viewAspect)
    }

    /// 适配时四边留的窄边（见 `RemoteDesktopCornerFit.margin`）；贴边铺满的不留。
    private var fitMargin: CGFloat {
        bleedsIntoCorners ? 0 : RemoteDesktopCornerFit.margin(content: contentSize, view: viewSize, corners: corners)
    }

    /// 适配时每个显示器点占多少视图点：等比放进视图；画面的角会落进外圆角时四边留一圈窄边
    ///（见 `RemoteDesktopCornerFit`；`bleedsIntoCorners` 时不留）。
    var fitScale: CGFloat {
        guard contentSize.width > 0, contentSize.height > 0 else { return 1 }
        if let native = snappedSize { return native.width / contentSize.width }
        return RemoteDesktopCornerFit.scale(content: pictureSize, view: viewSize,
                                            corners: bleedsIntoCorners ? .square : corners)
    }

    /// 画面四角与视图圆角同心的圆角（放大后出了视图的角不切；`bleedsIntoCorners` 时总是直角）。
    var pictureCorners: RemoteDesktopPictureCorners {
        guard !bleedsIntoCorners else { return .square }
        return RemoteDesktopCornerFit.pictureCorners(frame: contentFrame, view: viewSize, corners: corners)
    }

    var scale: CGFloat { fitScale * zoom }

    /// 整块显示器在视图坐标里的位置与大小（画面就画在这里）。比视图小的方向不看 `center`：按
    /// `RemoteDesktopCornerFit.origin` 放，画面的角落进圆弧时往黑边宽的那头挪（同心圆角那种适配照旧居中）。
    var contentFrame: CGRect {
        let size = CGSize(width: pictureSize.width * scale, height: pictureSize.height * scale)
        let shifts = fitMargin == 0
        let rest = RemoteDesktopCornerFit.origin(size: size, view: viewSize, corners: corners, shifts: shifts)
        var origin = CGPoint(x: size.width > viewSize.width ? viewSize.width / 2 - center.x * size.width : rest.x,
                             y: size.height > viewSize.height ? viewSize.height / 2 - center.y * size.height : rest.y)
        if snappedSize != nil, pixelsPerPoint > 0 {
            // 一比一时位置也要在整像素上，偏半个像素同样会糊。
            origin = CGPoint(x: (origin.x * pixelsPerPoint).rounded() / pixelsPerPoint,
                             y: (origin.y * pixelsPerPoint).rounded() / pixelsPerPoint)
        }
        return CGRect(origin: origin, size: size)
    }

    // MARK: 角落让开（贴边铺满时）

    /// 屏幕圆角从角上沿对角线往里切多深，按半径的比例：iOS 的连续曲线圆角量出来是 0.2915，
    /// 正圆弧是 0.2929（1 − sin45°），取 0.3 留一丝余量。画面的角往里退这么多，就落在弧线里面。
    static let cornerClearance: CGFloat = 0.3
    /// 指针离角多近（沿两条边，按半径的比例）开始让开：连续曲线圆角从角起沿边约 1.49 个半径才变直。
    static let cornerZone: CGFloat = 1.5

    /// 当前画面四条边往里收了多少（视图点），由画布逐帧往 `cornerPeek(for:)` 逼近。只影响画面画在哪
    ///（`displayedFrame`），不影响缩放、平移和指针换算——那些照旧按 `contentFrame`。
    var peekInsets = RemoteDesktopEdgeInsets.zero

    /// 画面实际画在哪：`contentFrame` 四边各收 `peekInsets`。
    var displayedFrame: CGRect {
        let f = contentFrame
        return CGRect(x: f.minX + peekInsets.left, y: f.minY + peekInsets.top,
                      width: f.width - peekInsets.left - peekInsets.right,
                      height: f.height - peekInsets.top - peekInsets.bottom)
    }

    /// 指针走进某个被屏幕圆角切掉的角时，画面四边该收多少（视图点），否则为零。
    ///
    /// 贴边铺满时画面的角由屏幕圆角切掉（`bleedsIntoCorners`），程序坞两头、触发角就落在里面看不全。
    /// 指针进到那个角附近，画面以视图的对角（左下角让开时是右上角）为不动点等比缩小，直到这个角在两个方向上
    /// 都退开 `cornerClearance` 个半径；离开后回到原样。按对角缩小而不是平移：平移会把对边推出视图——
    /// 往上挪就把 Mac 的菜单栏压到顶栏底下（2026-11-16 Duo 实测），缩小时对角那两条边纹丝不动。
    /// 缩小比例按视图的短边算，长边方向退得更多（Duo 横着：下边退 17pt、左边退约 26pt）。
    /// 用不带收缩的位置判断（`contentFrame`），收缩本身不会让指针出入区域、来回抖。
    /// 只在画面的那两条边正好贴着视图边（适配屏幕，或放大后拖到了那个角）时才让开。
    func cornerPeek(for pointer: CGPoint) -> RemoteDesktopEdgeInsets {
        guard bleedsIntoCorners else { return .zero }
        let frame = contentFrame
        let side = min(viewSize.width, viewSize.height)
        guard frame.width > 0, frame.height > 0, side > 0 else { return .zero }
        let p = viewPoint(normalized: pointer)
        let touchesLeft = frame.minX >= -0.5, touchesRight = frame.maxX <= viewSize.width + 0.5
        let touchesTop = frame.minY >= -0.5, touchesBottom = frame.maxY <= viewSize.height + 0.5
        // (半径, 横向是不是左边, 纵向是不是上边)
        let candidates: [(CGFloat, Bool, Bool)] = [
            (corners.topLeft, true, true), (corners.topRight, false, true),
            (corners.bottomLeft, true, false), (corners.bottomRight, false, false),
        ]
        for (radius, left, top) in candidates where radius > 0 {
            guard (left ? touchesLeft : touchesRight), (top ? touchesTop : touchesBottom) else { continue }
            let zone = radius * Self.cornerZone
            let dx = left ? p.x : viewSize.width - p.x
            let dy = top ? p.y : viewSize.height - p.y
            guard dx <= zone, dy <= zone else { continue }
            let clearance = (radius * Self.cornerClearance).rounded(.up)
            let shrink = min(0.5, clearance / side)
            // 不动点：视图的对角。
            let anchor = CGPoint(x: left ? viewSize.width : 0, y: top ? viewSize.height : 0)
            return RemoteDesktopEdgeInsets(left: shrink * (anchor.x - frame.minX), top: shrink * (anchor.y - frame.minY),
                                           right: shrink * (frame.maxX - anchor.x),
                                           bottom: shrink * (frame.maxY - anchor.y))
        }
        return .zero
    }

    /// 朝目标收缩走一帧（四条边各自指数逼近，`duration` 秒）。离目标都不到 0.25 点时直接到位，
    /// 返回还要不要再走。从一个角换到另一个角时四条边各走各的，中间几帧比例差一丝，看不出来。
    mutating func stepPeek(toward target: RemoteDesktopEdgeInsets, duration: CFTimeInterval) -> Bool {
        let t = 1 - exp(-max(0, duration) / Self.peekTimeConstant)
        let next = peekInsets.moved(toward: target, by: t)
        if next.distance(to: target) < 0.25 {
            peekInsets = target
            return false
        }
        peekInsets = next
        return true
    }

    /// 让开的时间常数：约 0.25 s 走完 95%。
    static let peekTimeConstant: CFTimeInterval = 0.08

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
        let size = CGSize(width: pictureSize.width * scale, height: pictureSize.height * scale)
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

    /// 内容比视图大的方向不让拖出边界；比视图小的方向 `center` 归中（位置由 `contentFrame` 按圆角定）。
    mutating func clamp() {
        let size = CGSize(width: pictureSize.width * scale, height: pictureSize.height * scale)
        func axis(_ value: CGFloat, content: CGFloat, view: CGFloat) -> CGFloat {
            guard content > view, content > 0 else { return 0.5 }
            let half = view / 2 / content
            return min(1 - half, max(half, value))
        }
        center = CGPoint(x: axis(center.x, content: size.width, view: viewSize.width),
                         y: axis(center.y, content: size.height, view: viewSize.height))
    }
}

/// 画面四条边各往里收多少（视图点，正数往里）。
nonisolated struct RemoteDesktopEdgeInsets: Equatable {
    var left: CGFloat = 0
    var top: CGFloat = 0
    var right: CGFloat = 0
    var bottom: CGFloat = 0

    static let zero = RemoteDesktopEdgeInsets()

    func moved(toward target: RemoteDesktopEdgeInsets, by t: CGFloat) -> RemoteDesktopEdgeInsets {
        RemoteDesktopEdgeInsets(left: left + (target.left - left) * t, top: top + (target.top - top) * t,
                                right: right + (target.right - right) * t, bottom: bottom + (target.bottom - bottom) * t)
    }

    /// 四条边里差得最多的那条。
    func distance(to other: RemoteDesktopEdgeInsets) -> CGFloat {
        max(abs(left - other.left), abs(top - other.top), abs(right - other.right), abs(bottom - other.bottom))
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
        let picture = viewport.pictureSize
        guard scale > 0, picture.width > 0, picture.height > 0 else { return pointer }
        let gain = acceleration(speed: speed)
        let dx = delta.width / scale * gain / picture.width
        let dy = delta.height / scale * gain / picture.height
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
