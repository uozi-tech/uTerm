import CoreGraphics
import Foundation

// 远程桌面的纯函数部分：背压与丢帧、码率控制、尺寸与坐标换算。
// 不碰采集、编码、网络，两端共用，Mac 单测全覆盖。时间一律是单调时钟纳秒（调用方传入）。

/// 发送节拍：决定一帧采集到的画面现在编、晚点编，还是被更新的画面替掉。
///
/// 规则（调研 §3.3「编码之前丢，绝不在编码之后丢」）：
/// - **在途** = 已交给编码器、还没收到手机「解码完」确认的帧。在途 ≥ `maxInflightFrames` 帧或
///   ≥ `maxInflightBytes` 字节时，新画面不送编码器，先**留着最新的一帧**（更旧的那帧直接丢掉）。
/// - 确认一回来（链路追上了），立刻把留着的那帧编出去。屏幕静止时 ScreenCaptureKit 不再出新帧，
///   不补这一下手机就会停在旧画面上。
/// - 帧率上限（码率控制降帧时用）：距上一次送编码器不足一个帧间隔的画面也先留着，到点再编。
///
/// 确认在手机**解码之后**才发，所以这里的背压是端到端的：网络慢、手机解码慢，都会让 Mac 少编。
nonisolated struct RemoteDesktopPacer<Frame> {
    static var maxInflightFrames: Int { 2 }
    static var maxInflightBytes: Int { 768 * 1024 }

    /// 序号 → 编出来的字节数（还在编码器里时为 0）。
    private(set) var inflight: [UInt32: Int] = [:]
    private(set) var inflightBytes = 0
    /// 留着待编的最新一帧。
    private(set) var pending: Frame?
    /// 因链路拥塞被替掉（没编就丢）的帧数——码率控制据此判断拥塞。
    private(set) var congestionDrops = 0
    /// 因帧率上限被替掉的帧数（不算拥塞）。
    private(set) var pacingDrops = 0
    private(set) var nextSequence: UInt32 = 1
    private var lastSubmitNanos: UInt64?
    /// 两次送编码器之间的最短间隔；0 = 不限（跟着采集走）。
    var minimumIntervalNanos: UInt64 = 0

    init() {}

    var hasCapacity: Bool {
        inflight.count < Self.maxInflightFrames && inflightBytes < Self.maxInflightBytes
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

/// 码率 / 帧率控制。
///
/// - 拥塞（编码前丢帧、或「采集 → 手机解码完」超过 `latencyThreshold`）：码率 ×0.7，两次下调至少隔
///   `decreaseSpacing`（一次拥塞往往连着报好几帧，不隔开会一口气砍到底）。码率已到下限还拥塞，帧率减半到 30。
/// - 连续 `stableInterval` 没有拥塞：先把帧率恢复到 60，再码率 ×1.15，直到上限。
nonisolated struct RemoteRateController: Equatable {
    struct Config: Equatable {
        var minBitrate: Int
        var maxBitrate: Int
        var decreaseFactor = 0.7
        var increaseFactor = 1.15
        var decreaseSpacing: UInt64 = 500_000_000
        var stableInterval: UInt64 = 2_000_000_000
        var latencyThreshold: UInt64 = 120_000_000
        var fullFrameRate = 60
        var reducedFrameRate = 30
    }

    let config: Config
    private(set) var bitrate: Int
    private(set) var frameRate: Int
    private var lastDecrease: UInt64?
    private var lastCongestion: UInt64
    private var lastIncrease: UInt64

    /// 起始码率按像素算：每像素约 4.5 bit/s（1080p ≈ 9.3 Mbps，低延迟模式下静态桌面足够清楚，
    /// 滚动时由拥塞控制往下压）。上限每像素 12 bit/s，下限 1 Mbps。
    static func config(width: Int, height: Int) -> Config {
        let pixels = max(1, width * height)
        return Config(minBitrate: 1_000_000, maxBitrate: max(2_000_000, pixels * 12))
    }

    static func initialBitrate(width: Int, height: Int) -> Int {
        let config = config(width: width, height: height)
        return min(config.maxBitrate, max(config.minBitrate, width * height * 9 / 2))
    }

    init(config: Config, initialBitrate: Int, now: UInt64) {
        self.config = config
        bitrate = min(config.maxBitrate, max(config.minBitrate, initialBitrate))
        frameRate = config.fullFrameRate
        lastCongestion = now
        lastIncrease = now
    }

    init(width: Int, height: Int, now: UInt64) {
        self.init(config: Self.config(width: width, height: height),
                  initialBitrate: Self.initialBitrate(width: width, height: height), now: now)
    }

    /// 报一次拥塞。返回码率或帧率有没有变。
    @discardableResult
    mutating func congestion(now: UInt64) -> Bool {
        lastCongestion = now
        if let lastDecrease, now &- lastDecrease < config.decreaseSpacing { return false }
        lastDecrease = now
        if bitrate > config.minBitrate {
            bitrate = max(config.minBitrate, Int(Double(bitrate) * config.decreaseFactor))
            return true
        }
        if frameRate > config.reducedFrameRate {
            frameRate = config.reducedFrameRate
            return true
        }
        return false
    }

    /// 一帧的「采集 → 手机解码完」耗时。超过阈值算拥塞。
    @discardableResult
    mutating func observe(latencyNanos: UInt64, now: UInt64) -> Bool {
        guard latencyNanos > config.latencyThreshold else { return tick(now: now) }
        return congestion(now: now)
    }

    /// 定期调用（每次确认时顺带）：稳定够久就往上调。返回有没有变。
    @discardableResult
    mutating func tick(now: UInt64) -> Bool {
        guard now &- lastCongestion >= config.stableInterval, now &- lastIncrease >= config.stableInterval else {
            return false
        }
        lastIncrease = now
        if frameRate < config.fullFrameRate {
            frameRate = config.fullFrameRate
            return true
        }
        guard bitrate < config.maxBitrate else { return false }
        bitrate = min(config.maxBitrate, Int(Double(bitrate) * config.increaseFactor))
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
nonisolated struct RemoteDesktopViewport: Equatable {
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
        zoom = min(Self.maxZoom, max(1, zoom * factor))
        // 缩放后让 fixed 仍落在 anchor 下面。
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        guard size.width > 0, size.height > 0 else { return }
        center = CGPoint(x: fixed.x - (anchor.x - viewSize.width / 2) / size.width,
                         y: fixed.y - (anchor.y - viewSize.height / 2) / size.height)
        clamp()
    }

    mutating func setZoom(_ value: CGFloat) {
        zoom = min(Self.maxZoom, max(1, value))
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

    /// 加速曲线：≤150 点/秒 不加速，之后线性增长，最大 2.5 倍。
    static func acceleration(speed: CGFloat) -> CGFloat {
        let v = max(0, speed.isFinite ? speed : 0)
        return min(2.5, 1 + max(0, v - 150) / 800)
    }
}
