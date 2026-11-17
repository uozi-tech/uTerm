import CoreImage
import CoreVideo
import Metal
import VideoToolbox

/// 采集帧的高质量缩小：在线性光下用 Lanczos 缩到视频尺寸，直接写进编码器要的 4:2:0。
///
/// 为什么不让 ScreenCaptureKit 直接缩（调研 §14.5）：它的缩放与双线性相当，5K 缩 2.39 倍时字发软
///（锐度比 Lanczos 低约 18%），码率给多少都补不回来。所以采集只按整数倍缩（`RemoteDesktopGeometry.captureSize`），
/// 剩下那一截在这里缩。几种缩法实测（2560×1440 → 2144×1206，真实桌面 + 1 px 黑白条纹）：
/// - VideoToolbox 像素转换：最快，但偏糊（锐度 2.68）。
/// - Metal / Core Image 在 gamma 码值上做 Lanczos：锐（2.85），但缩小时没把高频压下去，条纹残留 33.8——滚动时细笔画会闪。
/// - **Core Image 在线性光下做 Lanczos**：最锐（2.94，≈ 原生 5K 直接 Lanczos 的效果），条纹残留 22.7。每帧约 5 ms。
///
/// 现在只给静止精修用（运动帧走 `RemoteFastFrameScaler`）：精修帧要的是看得清，几毫秒不要紧。
/// 采集队列与连接队列都会调（不同时），`CIContext` 与缓冲池都可跨线程用。
nonisolated final class RemoteFrameScaler: @unchecked Sendable {
    let width: Int
    let height: Int
    private let context: CIContext
    private let outputPool: CVPixelBufferPool
    private static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// 没有 Metal 设备等情况下返回 nil：调用方退回让 ScreenCaptureKit 直接缩。
    init?(width: Int, height: Int, outputFormat: OSType) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: outputFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            return nil
        }
        self.width = width
        self.height = height
        // 工作色彩空间用默认的线性 sRGB 扩展：滤波在线性光下做，缩小时高频才被正确压下去。
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        outputPool = pool
    }

    /// `image` 是 BGRA（Display P3 码值）。返回视频尺寸的 4:2:0，标注与编码器一致；失败返回 nil（这一帧丢掉）。
    /// `crop`：只取 `image` 里的这一块（像素，左上角原点）铺满输出；nil = 整张。
    func scale(_ image: CVPixelBuffer, crop: CGRect? = nil) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, outputPool, &created) == kCVReturnSuccess, let output = created,
              let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        // 先标好：Core Image 按输出缓冲上的矩阵转 YUV。
        Self.tag(output)
        var input = CIImage(cvPixelBuffer: image, options: [.colorSpace: Self.colorSpace])
        if let crop {
            // Core Image 是左下角原点：把要的那块裁出来，挪到原点。
            let flipped = CGRect(x: crop.minX, y: input.extent.height - crop.maxY, width: crop.width, height: crop.height)
            input = input.cropped(to: flipped).transformed(by: CGAffineTransform(translationX: -flipped.minX, y: -flipped.minY))
        }
        let scale = CGFloat(height) / input.extent.height
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(CGFloat(width) / input.extent.width / scale, forKey: kCIInputAspectRatioKey)
        guard let scaled = filter.outputImage else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.render(scaled.cropped(to: bounds), to: output, bounds: bounds, colorSpace: Self.colorSpace)
        return output
    }

    /// 采集给的码值是 Display P3、sRGB 曲线，转 YUV 用 709 矩阵：与 `RemoteVideoEncoder` 写进码流的标注一致。
    static func tag(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}

/// 运动帧的缩小：VideoToolbox 像素转换，走专用的缩放硬件，GPU 时间≈0、每帧约 1 ms（调研 §14.5 的 B 项实测）。
///
/// 画质与让 ScreenCaptureKit 自己缩同级（先整数步再缩 1.19 时锐度是 Lanczos 的 87%），比 Lanczos 软一点；
/// 画面在动时看不出来，静止下来后由精修帧换成 `RemoteFrameScaler` 的 Lanczos 版本。它的 CPU 只有 Lanczos
/// 的四分之一左右（Core Image 每帧在 CPU 上还要 4–7 ms）。
///
/// 只在采集源自己的串行队列上调用。
nonisolated final class RemoteFastFrameScaler: @unchecked Sendable {
    let width: Int
    let height: Int
    private let session: VTPixelTransferSession
    private let outputPool: CVPixelBufferPool

    init?(width: Int, height: Int, outputFormat: OSType) {
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr,
              let session = created else { return nil }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        // 码值本来就是 Display P3、sRGB 曲线：目标标得一样，转换只缩放、转 YUV，不做色域变换。
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                             value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                             value: kCVImageBufferColorPrimaries_P3_D65)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
                             value: kCVImageBufferTransferFunction_sRGB)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: outputFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            VTPixelTransferSessionInvalidate(session)
            return nil
        }
        self.width = width
        self.height = height
        self.session = session
        outputPool = pool
    }

    deinit { VTPixelTransferSessionInvalidate(session) }

    /// 现在是不是「只取源图的 clean aperture」那一档（只在调用的队列上读写）。
    private var cropping = false

    /// `image` 是 BGRA（Display P3 码值）。失败返回 nil（这一帧丢掉）。
    /// `crop`：只取 `image` 里的这一块（像素，左上角原点）铺满输出；nil = 整张。裁的那块写在源图的 clean aperture
    /// 上，转换时只取它。
    func scale(_ image: CVPixelBuffer, crop: CGRect? = nil) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, outputPool, &created) == kCVReturnSuccess, let output = created else {
            return nil
        }
        RemoteFrameScaler.tag(output)
        if let crop {
            // 偏移量是这一块的中心相对整张图中心的位置。
            let aperture: [CFString: Any] = [
                kCVImageBufferCleanApertureWidthKey: crop.width,
                kCVImageBufferCleanApertureHeightKey: crop.height,
                kCVImageBufferCleanApertureHorizontalOffsetKey: crop.midX - CGFloat(CVPixelBufferGetWidth(image)) / 2,
                kCVImageBufferCleanApertureVerticalOffsetKey: crop.midY - CGFloat(CVPixelBufferGetHeight(image)) / 2,
            ]
            CVBufferSetAttachment(image, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldNotPropagate)
        } else {
            CVBufferRemoveAttachment(image, kCVImageBufferCleanApertureKey)
        }
        if cropping != (crop != nil) {
            cropping = crop != nil
            VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode,
                                 value: cropping ? kVTScalingMode_CropSourceToCleanAperture : kVTScalingMode_Normal)
        }
        let status = VTPixelTransferSessionTransferImage(session, from: image, to: output)
        // 源图还会被别人用（精修时重缩）：标记用完就摘掉。
        if crop != nil { CVBufferRemoveAttachment(image, kCVImageBufferCleanApertureKey) }
        return status == noErr ? output : nil
    }
}

/// 缩好的帧画的是哪一块：挂在帧上，从采集源带到发送端（写进视频帧头）。
nonisolated enum RemoteFrameRegionTag {
    private static var key: CFString { "com.uozi.uTerm.remote.frameRegion" as CFString }

    /// 缩放器的输出缓冲是池里轮着用的：整块的帧也要调一次，把上一轮的标记摘掉。
    static func set(_ region: RemoteDesktopRegion?, on image: CVPixelBuffer) {
        guard let region else {
            CVBufferRemoveAttachment(image, key)
            return
        }
        let values = [region.x, region.y, region.width, region.height] as CFArray
        CVBufferSetAttachment(image, key, values, .shouldNotPropagate)
    }

    static func region(of image: CVPixelBuffer) -> RemoteDesktopRegion? {
        guard let values = CVBufferCopyAttachment(image, key, nil) as? [Double], values.count == 4 else { return nil }
        return RemoteDesktopRegion(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}
