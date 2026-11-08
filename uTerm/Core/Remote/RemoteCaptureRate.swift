import CoreGraphics
import Foundation

/// 采集帧率随画面变化的面积走（SCK 每帧的 `dirtyRects`，思路同 WebRTC 的屏幕采集按变化区域降帧）。
///
/// - 一直只有一小块在变（打字、光标、时钟、转圈、终端里一行行出字）：降到 `reducedRate`。小块变化 30 fps
///   看不出差别，采集、缩放、编码的活却少一半。
/// - 一出现大面积变化（滚动、拖窗口、切 app、放视频）：立刻回到满帧。
/// - 降要等变化一直很小满 `reduceAfterNanos`，升不等：宁可多采，不让滚动卡一下。
///
/// 屏幕静止时 SCK 本来就不出帧（`idle`），这里只管「在变，但变得少」的那段。
nonisolated struct RemoteCaptureRateGovernor: Equatable, Sendable {
    static let reducedRate = 30
    /// 变化面积占整屏多少以下算「小块」。
    static let smallFraction = 0.08
    static let reduceAfterNanos: UInt64 = 1_000_000_000

    let fullRate: Int
    private(set) var rate: Int
    /// 这一段「只有小块在变」从什么时候开始；出现大面积变化时清掉。
    private var smallSince: UInt64?

    init(fullRate: Int) {
        self.fullRate = fullRate
        rate = fullRate
    }

    /// 来了一帧。`dirtyFraction` = 变化面积 / 整屏（不知道时为 nil，按大面积算）。帧率要变时返回新值。
    mutating func frame(dirtyFraction: Double?, now: UInt64) -> Int? {
        guard fullRate > Self.reducedRate else { return nil }
        guard let fraction = dirtyFraction, fraction < Self.smallFraction else {
            smallSince = nil
            return set(fullRate)
        }
        let since = smallSince ?? now
        smallSince = since
        return now - since >= Self.reduceAfterNanos ? set(Self.reducedRate) : nil
    }

    private mutating func set(_ value: Int) -> Int? {
        guard value != rate else { return nil }
        rate = value
        return value
    }

    /// 变化面积占整屏的比例。矩形可能重叠（SCK 不保证不重叠），按面积直接相加、封顶 1：宁可高估。
    static func dirtyFraction(_ rects: [CGRect], frameSize: CGSize) -> Double {
        let total = frameSize.width * frameSize.height
        guard total > 0 else { return 1 }
        let bounds = CGRect(origin: .zero, size: frameSize)
        let area = rects.reduce(0.0) { sum, rect in
            let clipped = rect.intersection(bounds)
            return clipped.isNull ? sum : sum + Double(clipped.width * clipped.height)
        }
        return min(1, area / Double(total))
    }
}
