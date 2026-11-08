import CoreImage
import CoreVideo
import XCTest
@testable import uTerm

/// 采集帧缩放（调研 §14.5）：ScreenCaptureKit 只做整数倍缩小，剩下的由 `RemoteFrameScaler` 用 Lanczos 缩。
///
/// 画质本身（缩出来离「原生 5K 直接理想缩小」有多近）要拿真实屏幕量：SCK 直接缩 34.1 dB、VideoToolbox
/// 像素转换 33.4 dB、本实现 35.8 dB。合成图上量不出这个，这里只核对行为与混叠。
final class RemoteFrameScalerTests: XCTestCase {

    func test_capture_size_is_the_integer_step_that_still_covers_the_stream() {
        func size(_ width: CGFloat, _ height: CGFloat, _ stream: (Int, Int)) -> [Int] {
            let result = RemoteDesktopGeometry.captureSize(displayPixels: CGSize(width: width, height: height),
                                                           stream: (width: stream.0, height: stream.1))
            return [result.width, result.height]
        }
        XCTAssertEqual(size(5120, 2880, (2144, 1206)), [2560, 1440], "5K：缩 2 倍，剩下 1.19 倍交给 Lanczos")
        XCTAssertEqual(size(3024, 1964, (1856, 1206)), [3024, 1964], "不足 2 倍：采原生")
        XCTAssertEqual(size(3840, 2160, (1920, 1080)), [1920, 1080], "正好整数倍：采集尺寸就是视频尺寸，不用再缩")
        XCTAssertEqual(size(1512, 982, (1512, 982)), [1512, 982])
        XCTAssertEqual(size(6016, 3384, (2622, 1474)), [3008, 1692])
    }

    func test_output_has_stream_size_format_and_color_tags() throws {
        let scaler = try XCTUnwrap(RemoteFrameScaler(width: 2144, height: 1206,
                                                     outputFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange))
        let output = try XCTUnwrap(scaler.scale(Self.bgra(width: 2560, height: 1440) { _, _ in 128 }))
        XCTAssertEqual(CVPixelBufferGetWidth(output), 2144)
        XCTAssertEqual(CVPixelBufferGetHeight(output), 1206)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferColorPrimariesKey, nil) as? String,
                       kCVImageBufferColorPrimaries_P3_D65 as String)
        XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferYCbCrMatrixKey, nil) as? String,
                       kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    }

    func test_flat_regions_keep_their_brightness() throws {
        let scaler = try XCTUnwrap(RemoteFrameScaler(width: 2144, height: 1206,
                                                     outputFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        // 左半边暗、右半边亮的两大块。
        let output = try XCTUnwrap(scaler.scale(Self.bgra(width: 2560, height: 1440) { x, _ in x < 1280 ? 40 : 210 }))
        let left = Self.lumaMean(output, columns: 200..<800), right = Self.lumaMean(output, columns: 1300..<1900)
        // 视频范围：Y = 16 + 219 × 值 / 255。
        XCTAssertEqual(left, 16 + 219 * 40 / 255, accuracy: 2)
        XCTAssertEqual(right, 16 + 219 * 210 / 255, accuracy: 2)
    }

    /// 表示不了的细节要压下去：1 像素宽的黑白竖条超出了缩小后的频率上限，残留越多，滚动时细笔画越闪。
    /// 在线性光下滤波比直接在 gamma 码值上滤波压得更干净（实测 22.7 vs 33.8）。
    func test_suppresses_unrepresentable_detail_better_than_gamma_space_lanczos() throws {
        let stripes = Self.bgra(width: 2560, height: 1440) { x, _ in x % 2 == 0 ? 0 : 255 }
        let scaler = try XCTUnwrap(RemoteFrameScaler(width: 2144, height: 1206,
                                                     outputFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        let linear = Self.lumaSpread(try XCTUnwrap(scaler.scale(stripes)))
        let gamma = Self.lumaSpread(try Self.gammaSpaceLanczos(stripes, width: 2144, height: 1206))
        print(String(format: "[桌面探针] 1 px 条纹残留（越小越不闪）：线性光 Lanczos %.1f，gamma 空间 Lanczos %.1f", linear, gamma))
        XCTAssertLessThan(linear, gamma * 0.85)
    }

    /// 运动帧的快缩法（VideoToolbox）：尺寸、格式、色彩标注与 Lanczos 版一致，平坦区亮度不变，
    /// 这样运动帧与精修帧交替时画面不跳色、不跳亮度。
    func test_fast_scaler_matches_lanczos_size_tags_and_brightness() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange] {
            let fast = try XCTUnwrap(RemoteFastFrameScaler(width: 2144, height: 1206, outputFormat: format))
            let output = try XCTUnwrap(fast.scale(Self.bgra(width: 2560, height: 1440) { _, _ in 128 }))
            XCTAssertEqual(CVPixelBufferGetWidth(output), 2144)
            XCTAssertEqual(CVPixelBufferGetHeight(output), 1206)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), format)
            XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferColorPrimariesKey, nil) as? String,
                           kCVImageBufferColorPrimaries_P3_D65 as String)
            XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferYCbCrMatrixKey, nil) as? String,
                           kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
            XCTAssertEqual(CVBufferCopyAttachment(output, kCVImageBufferTransferFunctionKey, nil) as? String,
                           kCVImageBufferTransferFunction_sRGB as String)
        }
        let fast = try XCTUnwrap(RemoteFastFrameScaler(width: 2144, height: 1206,
                                                       outputFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        let lanczos = try XCTUnwrap(RemoteFrameScaler(width: 2144, height: 1206,
                                                      outputFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        let blocks = Self.bgra(width: 2560, height: 1440) { x, _ in x < 1280 ? 40 : 210 }
        let quick = try XCTUnwrap(fast.scale(blocks)), sharp = try XCTUnwrap(lanczos.scale(blocks))
        for columns in [200..<800, 1300..<1900] {
            XCTAssertEqual(Self.lumaMean(quick, columns: columns), Self.lumaMean(sharp, columns: columns), accuracy: 1.5,
                           "\(columns)")
        }
    }

    // MARK: - 夹具

    private static func bgra(width: Int, height: Int, value: (Int, Int) -> UInt8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                             kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
        let image = buffer!
        CVPixelBufferLockBaseAddress(image, [])
        let stride = CVPixelBufferGetBytesPerRow(image)
        let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let v = value(x, y)
                let pixel = base + y * stride + x * 4
                pixel[0] = v; pixel[1] = v; pixel[2] = v; pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        RemoteFrameScaler.tag(image)
        return image
    }

    /// 同样的 Lanczos，但不做色彩管理：直接在 gamma 码值上滤波。
    private static func gammaSpaceLanczos(_ image: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &output)
        let result = try XCTUnwrap(output)
        RemoteFrameScaler.tag(result)
        let input = CIImage(cvPixelBuffer: image)
        let filter = try XCTUnwrap(CIFilter(name: "CILanczosScaleTransform"))
        let scale = CGFloat(height) / input.extent.height
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(CGFloat(width) / input.extent.width / scale, forKey: kCIInputAspectRatioKey)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            .render(try XCTUnwrap(filter.outputImage).cropped(to: bounds), to: result, bounds: bounds, colorSpace: nil)
        return result
    }

    /// 8-bit 4:2:0 的亮度平面，按列范围取中间几行的平均。
    private static func lumaMean(_ image: CVPixelBuffer, columns: Range<Int>) -> Double {
        lumaValues(image, columns: columns).reduce(0, +) / Double(lumaValues(image, columns: columns).count)
    }

    /// 中间区域亮度的标准差（避开边缘的滤波边界）。
    private static func lumaSpread(_ image: CVPixelBuffer) -> Double {
        let values = lumaValues(image, columns: 100..<(CVPixelBufferGetWidth(image) - 100))
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
    }

    private static func lumaValues(_ image: CVPixelBuffer, columns: Range<Int>) -> [Double] {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
        let middle = CVPixelBufferGetHeight(image) / 2
        var values: [Double] = []
        for y in (middle - 50)..<(middle + 50) {
            for x in columns { values.append(Double(base[y * stride + x])) }
        }
        return values
    }
}
