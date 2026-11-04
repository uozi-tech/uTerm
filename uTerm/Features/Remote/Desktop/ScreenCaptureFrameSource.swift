import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit 采集一块显示器（调研 §3.2）。
///
/// - 输出 4:2:0（`420v`，或 10-bit 的 `x420`）IOSurface，交给编码器。
/// - 缩放：SCK 只做整数倍缩小（`RemoteDesktopGeometry.captureSize`）；还要再缩时采 BGRA，由
///   `RemoteFrameScaler` 用 Lanczos 缩到视频尺寸并转 4:2:0（SCK 自己缩非整数倍会让字发软、滚动时闪烁）。
///   采集尺寸正好等于视频尺寸时 SCK 直接出 4:2:0，零拷贝。
/// - 屏幕静止时 SCK 只出 `idle` 状态的帧，这里不交出去 → 不编码不发送，空闲带宽≈0。
/// - `showsCursor = false`：光标位置单独发，手机本地画（光标移动不触发编码）。
/// - 只在有人看的时候存在：桌面流结束即 `stopCapture`，不在后台空转。
nonisolated final class ScreenCaptureFrameSource: NSObject, RemoteDesktopFrameSource, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable {
    private let display: RemoteDesktopDisplay
    private let width: Int
    private let height: Int
    private let frameRate: Int
    private let tenBit: Bool
    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    /// 采集尺寸比视频大时才有。只在 `queue` 上用（`start` 里在开始采集之前挂上）。
    private var scaler: RemoteFrameScaler?
    private var onFrame: (@Sendable (CVPixelBuffer, UInt64) -> Void)?
    private var onStop: (@Sendable (Error?) -> Void)?

    init(display: RemoteDesktopDisplay, width: Int, height: Int, tenBit: Bool, frameRate: Int = 60) {
        self.display = display
        self.width = width
        self.height = height
        self.tenBit = tenBit
        self.frameRate = frameRate
    }

    func start(onFrame: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void,
               onStop: @escaping @Sendable (Error?) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.displays.first(where: { $0.displayID == display.id }) else {
            throw RemoteDesktopCaptureError.displayNotFound
        }
        let filter = SCContentFilter(display: target, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let outputFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let capture = RemoteDesktopGeometry.captureSize(
            displayPixels: CGSize(width: display.pixelWidth, height: display.pixelHeight), stream: (width, height))
        let scaler = capture != (width, height)
            ? RemoteFrameScaler(width: width, height: height, outputFormat: outputFormat) : nil
        if scaler != nil {
            configuration.width = capture.width
            configuration.height = capture.height
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
        } else {
            configuration.width = width
            configuration.height = height
            configuration.pixelFormat = outputFormat
        }
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // 色域要显式给：不设时 SCK 跟着显示器自己的色域出码值（内建屏、Studio Display 都是 P3 级，
        // 外接 sRGB 屏又是 sRGB），而帧上的标注恒为 709，不随 `colorSpaceName` 变（调研 §14.3）。
        // 固定 Display P3，编码器才能标得对（见 `RemoteVideoEncoder`）。
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        // 编码器里最多压着 2 帧、发送端再留 1 帧最新的、静止精修还要拿着最后 1 帧：留足余量，
        // 否则表面池被占满时 SCK 会停住不出帧。
        configuration.queueDepth = 6
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        queue.sync { self.scaler = scaler }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        install(stream: stream, onFrame: onFrame, onStop: onStop)
        try await stream.startCapture()
    }

    private func install(stream: SCStream, onFrame: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void,
                         onStop: @escaping @Sendable (Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.onFrame = onFrame
        self.onStop = onStop
        self.stream = stream
    }

    func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        onFrame = nil
        onStop = nil
        lock.unlock()
        guard let stream else { return }
        Task { try? await stream.stopCapture() }
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let captured = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let nanos = DispatchTime.now().uptimeNanoseconds
        var image = captured
        if let scaler {
            // 缩好的帧来自缩放器自己的缓冲池：SCK 的这块表面用完即还，不占它的采集队列。缩失败就丢这一帧。
            guard let scaled = scaler.scale(captured) else { return }
            image = scaled
        }
        lock.lock()
        let handler = onFrame
        lock.unlock()
        handler?(image, nanos)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let handler = onStop
        lock.unlock()
        handler?(error)
    }
}

nonisolated enum RemoteDesktopCaptureError: LocalizedError {
    case displayNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "找不到要采集的显示器"
        }
    }
}
