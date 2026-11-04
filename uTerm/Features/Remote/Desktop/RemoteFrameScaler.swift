import CoreImage
import CoreVideo
import Metal

/// 采集帧的高质量缩小：在线性光下用 Lanczos 缩到视频尺寸，直接写进编码器要的 4:2:0。
///
/// 为什么不让 ScreenCaptureKit 直接缩（调研 §14.5）：它的缩放与双线性相当，5K 缩 2.39 倍时字发软
///（锐度比 Lanczos 低约 18%），码率给多少都补不回来。所以采集只按整数倍缩（`RemoteDesktopGeometry.captureSize`），
/// 剩下那一截在这里缩。几种缩法实测（2560×1440 → 2144×1206，真实桌面 + 1 px 黑白条纹）：
/// - VideoToolbox 像素转换：最快，但偏糊（锐度 2.68）。
/// - Metal / Core Image 在 gamma 码值上做 Lanczos：锐（2.85），但缩小时没把高频压下去，条纹残留 33.8——滚动时细笔画会闪。
/// - **Core Image 在线性光下做 Lanczos**：最锐（2.94，≈ 原生 5K 直接 Lanczos 的效果），条纹残留 22.7。每帧约 5 ms。
///
/// 只在采集源自己的串行队列上调用。
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
    func scale(_ image: CVPixelBuffer) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, outputPool, &created) == kCVReturnSuccess, let output = created,
              let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        // 先标好：Core Image 按输出缓冲上的矩阵转 YUV。
        Self.tag(output)
        let input = CIImage(cvPixelBuffer: image, options: [.colorSpace: Self.colorSpace])
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
