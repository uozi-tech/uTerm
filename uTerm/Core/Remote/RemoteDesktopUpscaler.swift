import CoreImage
import CoreVideo
import Foundation

/// 画面比屏幕上要显示的像素少时，先用带锐化的双三次（Bicubic，B = 0、C = 1）放大到位，然后才交给显示层。
///
/// 为什么要它：窗口模式下送来的是窗口原生的像素（Mac 每个点 2 个像素），手机每个点 3 个像素，铺满画布要放大
/// 1.5 倍。显示层自己放大用的是双线性，字的边缘是糊的。2026-11-18 用一页文字量过（按 2 倍渲染放大到 3 倍，
/// 对比直接按 3 倍渲染；浅色 / 深色页面）：
///
///     方法                  PSNR (dB)        边缘能量      一帧（Mac，1902×1338 → 2852×2006，10-bit）
///     双线性（显示层）      23.67 / 24.70    47% / 47%     0.9 ms
///     Lanczos               24.60 / 25.59    61% / 63%     1.4 ms
///     Lanczos + 锐化 0.3    24.91 / 25.67    77% / 83%     4.5 ms
///     Bicubic B0 C1（现用） 24.88 / 25.63    68% / 74%     1.1 ms
///
/// 另起一趟锐化多花三倍时间只多几个点，所以用 C = 1 的双三次：它的负瓣本身就带锐化，一趟做完。
/// 同一次也量了编码：只有一小块在动的窗口画面，主流里静止的字就有 47 dB，不是瓶颈。真像素数上不去
/// （macOS 没有每点 3 像素的渲染），除非把窗口里的字调小。
///
/// 看整个屏幕时视频本来就按手机的像素数送来（Mac 那头缩好的），比例不到 `minimumRatio`，原样放行，这里不花时间。
///
/// 在送显示的队列上用（`RemoteDesktopPresenter`，不在收帧的队列上：它慢了不能拖住解码和确认）。
///
/// **画面在动时不放大。** 放大用 GPU（Core Image），Duo 上单独反复量是一帧 3 ms，但画面真的以每秒 60 帧在屏幕上
/// 换的时候 GPU 正忙，一帧要十来毫秒（同机实测 8–13 ms），赶不上；滚动时也看不出字利不利。所以按帧来得多密决定
/// （`admit`）：
/// - 两帧间隔不到 `motionGapNanos`（每秒 40 帧以上，滚动、拖窗口）：进入「在动」，原样放行。
/// - 「在动」之后要连着 `calmFramesToResume` 帧都来得慢（转圈的小动画、打字、光标闪）才重新放大，免得帧率在
///   分界上下晃时一帧利一帧糊。
/// - 间隔够，但最近放大一帧的耗时超过间隔的一半：这台设备赶不上，也原样放行。
/// - 画面停下来（`RemoteDesktopPresenter` 隔一小会儿没有新帧）而最后一张是没放大的：`settle` 把它补放大一次。
nonisolated final class RemoteDesktopUpscaler: @unchecked Sendable {
    /// 要放大到这个比例以上才动手：差一点点时双线性看不出糊。
    static let minimumRatio = 1.15
    /// 最多放大这么多倍。再往上原图的信息撑不住，白花时间。
    static let maximumRatio = 2.0
    /// 输出最多这么多像素（约 4K 一帧）。
    static let maximumPixels = 8_500_000
    /// 双三次的两个参数（Mitchell–Netravali 的 B、C）。B = 0、C = 1：插值、负瓣最深，边缘最利。
    static let bicubicB = 0.0
    static let bicubicC = 1.0
    /// 两帧间隔小于这个算「在动」（每秒 40 帧以上）。
    static let motionGapNanos: UInt64 = 25_000_000
    /// 「在动」之后连着这么多帧来得慢才重新放大。
    static let calmFramesToResume = 8

    private let lock = NSLock()
    private let context: CIContext
    private var target: (width: Int, height: Int)?
    private var pool: CVPixelBufferPool?
    private var poolKey: (width: Int, height: Int, format: OSType)?
    // 以下只在送显示的队列上读写。
    private var lastArrival: UInt64?
    private var calmFrames = RemoteDesktopUpscaler.calmFramesToResume
    /// 最近放大一帧大约多久（毫秒，指数平均）。
    private var costMillis = 5.0
    /// 最后送去显示的那张是不是没放大的（该放大而没放）。
    private var lastWasPassedThrough = false
    private var loggedSize: (Int, Int)?

    init() {
        // 不做色彩管理：放大和锐化都在码流原本的编码值上做，出来的缓冲照搬原来的色彩标记，颜色和不经这里时一样。
        context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    }

    /// 整帧画面在屏幕上占多少像素（没放大时）。画布排版时在主线程上报；nil = 不知道，原样放行。
    func setDisplayPixels(width: Int, height: Int) {
        lock.lock()
        target = width > 0 && height > 0 ? (width, height) : nil
        lock.unlock()
    }

    /// 这一帧该放大到多大；不用放大时 nil。
    static func outputSize(image: (width: Int, height: Int), display: (width: Int, height: Int)) -> (width: Int, height: Int)? {
        guard image.width > 0, image.height > 0 else { return nil }
        var ratio = min(Double(display.width) / Double(image.width), Double(display.height) / Double(image.height))
        guard ratio >= minimumRatio else { return nil }
        ratio = min(ratio, maximumRatio, (Double(maximumPixels) / Double(image.width * image.height)).squareRoot())
        guard ratio >= minimumRatio else { return nil }
        // 4:2:0 的缓冲宽高要是偶数。
        return (Int((Double(image.width) * ratio).rounded()) & ~1, Int((Double(image.height) * ratio).rounded()) & ~1)
    }

    /// 这一帧要送去显示了：放大后的画面；不用放大、画面在动、赶不上或放不了时就是原来那张。
    func process(_ image: CVPixelBuffer, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> CVPixelBuffer {
        let admitted = admit(now: now)
        guard let output = outputSize(for: image) else {
            lastWasPassedThrough = false
            return image
        }
        guard admitted, let scaled = scale(image, to: output) else {
            lastWasPassedThrough = true
            return image
        }
        lastWasPassedThrough = false
        return scaled
    }

    /// 画面停下来了（一小会儿没有新帧）。最后显示的那张是该放大而没放大的就补一张放大的，否则 nil。
    func settle(_ image: CVPixelBuffer) -> CVPixelBuffer? {
        // 停下来了：之后来得慢的帧直接放大，不用再数。
        calmFrames = Self.calmFramesToResume
        guard lastWasPassedThrough, let output = outputSize(for: image), let scaled = scale(image, to: output) else { return nil }
        lastWasPassedThrough = false
        return scaled
    }

    /// 按帧来得多密决定这一帧放不放大（规则见类型注释）。每送一帧调一次。
    func admit(now: UInt64) -> Bool {
        defer { lastArrival = now }
        guard let lastArrival else { return true }
        let gap = now &- lastArrival
        guard gap >= Self.motionGapNanos else {
            calmFrames = 0
            return false
        }
        calmFrames = min(Self.calmFramesToResume, calmFrames + 1)
        guard calmFrames >= Self.calmFramesToResume else { return false }
        return Double(gap) / 1e6 >= costMillis * 2
    }

    /// 记一次放大花了多久（指数平均，`admit` 用它判断赶不赶得上）。
    func record(costMillis millis: Double) {
        costMillis = costMillis * 0.8 + millis * 0.2
    }

    private func outputSize(for image: CVPixelBuffer) -> (width: Int, height: Int)? {
        lock.lock()
        let target = self.target
        lock.unlock()
        guard let target else { return nil }
        return Self.outputSize(image: (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)), display: target)
    }

    private func scale(_ image: CVPixelBuffer, to output: (width: Int, height: Int)) -> CVPixelBuffer? {
        let size = (width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        let start = DispatchTime.now().uptimeNanoseconds
        guard let scaled = render(image, from: size, to: output) else { return nil }
        let millis = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e6
        record(costMillis: millis)
        if loggedSize?.0 != output.width || loggedSize?.1 != output.height {
            loggedSize = (output.width, output.height)
            AppLogger.info("远程桌面：画面 \(size.width)×\(size.height) 放大到 \(output.width)×\(output.height) 再显示"
                           + "（双三次，这一帧 \(String(format: "%.1f", millis)) ms）", category: RemoteLog.category)
        }
        return scaled
    }

    private func render(_ image: CVPixelBuffer, from size: (width: Int, height: Int),
                        to output: (width: Int, height: Int)) -> CVPixelBuffer? {
        guard let destination = destination(width: output.width, height: output.height,
                                            format: CVPixelBufferGetPixelFormatType(image)) else { return nil }
        // 先把色彩标记搬过去：Core Image 写 YCbCr 缓冲时按目的缓冲上的矩阵换算，和读源图用的是同一套，颜色才不变。
        CVBufferPropagateAttachments(image, destination)
        let scaleX = CGFloat(output.width) / CGFloat(size.width), scaleY = CGFloat(output.height) / CGFloat(size.height)
        let extent = CGRect(x: 0, y: 0, width: output.width, height: output.height)
        let picture = CIImage(cvPixelBuffer: image)
            .clampedToExtent()
            .applyingFilter("CIBicubicScaleTransform", parameters: [kCIInputScaleKey: scaleY,
                                                                     kCIInputAspectRatioKey: scaleX / scaleY,
                                                                     "inputB": Self.bicubicB, "inputC": Self.bicubicC])
            .cropped(to: extent)
        context.render(picture, to: destination, bounds: extent, colorSpace: nil)
        return destination
    }

    private func destination(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        if poolKey?.width != width || poolKey?.height != height || poolKey?.format != format {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                    attributes as CFDictionary, &created)
            pool = created
            poolKey = (width, height, format)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        // 显示层还拿着前几张：池子最多给这么多，再要就先不放大（原样放行），不无限涨内存。
        let limit = [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }
}
