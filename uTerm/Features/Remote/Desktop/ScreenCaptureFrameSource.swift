import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit 采集一块显示器（调研 §3.2）。
///
/// - 输出 4:2:0（`420v`，或 10-bit 的 `x420`）IOSurface，交给编码器。
/// - 缩放：SCK 只做整数倍缩小（`RemoteDesktopGeometry.captureSize`）；还要再缩时采 BGRA，运动帧由
///   `RemoteFastFrameScaler`（VideoToolbox，专用缩放硬件）缩到视频尺寸并转 4:2:0；静止精修时
///   `refinedImage(of:)` 拿最后一张原始采集用 `RemoteFrameScaler` 的 Lanczos 重缩（SCK 自己缩非整数倍会让字
///   发软、滚动时闪烁）。
///   采集尺寸正好等于视频尺寸时 SCK 直接出 4:2:0，零拷贝。
/// - 屏幕静止时 SCK 只出 `idle` 状态的帧，这里不交出去 → 不编码不发送，空闲带宽≈0。
/// - 一直只有一小块在变时把采集降到 30 fps，大面积变化立刻回满帧（`RemoteCaptureRateGovernor`，看每帧的
///   `dirtyRects`）。编码器的期望帧率由发送端按实际到达间隔自己跟上，这里不管。
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
    /// 采集尺寸比视频大时才有。`start` 里在开始采集之前挂上，之后不变。运动帧用快的，精修用 Lanczos；
    /// 快的建不起来时运动帧也用 Lanczos。
    private var scaler: RemoteFrameScaler?
    private var fastScaler: RemoteFastFrameScaler?
    /// 最后交出去的那帧（缩过的）与它的原始采集：精修时据此重缩。受 `lock` 保护。
    private var lastScaled: CVPixelBuffer?
    private var lastRaw: CVPixelBuffer?
    /// 以下只在 `queue` 上用：采集帧率的调速、当前配置（改帧率时整份交回 SCK）、采集尺寸。
    private var governor: RemoteCaptureRateGovernor
    private var configuration: SCStreamConfiguration?
    private var captureFrameSize = CGSize.zero
    private var onFrame: (@Sendable (CVPixelBuffer, UInt64) -> Void)?
    private var onStop: (@Sendable (Error?) -> Void)?

    init(display: RemoteDesktopDisplay, width: Int, height: Int, tenBit: Bool, frameRate: Int = 60) {
        self.display = display
        self.width = width
        self.height = height
        self.tenBit = tenBit
        self.frameRate = frameRate
        governor = RemoteCaptureRateGovernor(fullRate: frameRate)
    }

    func start(onFrame: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void,
               onStop: @escaping @Sendable (Error?) -> Void) async throws {
        // 显示器刚从睡眠里醒来时，可采集列表要过一会儿才有它：找不到就隔一会儿再问，最多约 2 秒。
        var target: SCDisplay?
        for attempt in 0..<10 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            target = content.displays.first(where: { $0.displayID == display.id })
            if target != nil { break }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(200)) }
        }
        guard let target else {
            throw RemoteHeadlessDisplay.screenSharingHoldsDisplay()
                ? RemoteDesktopCaptureError.heldByScreenSharing : RemoteDesktopCaptureError.displayNotFound
        }
        let filter = SCContentFilter(display: target, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let outputFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let capture = RemoteDesktopGeometry.captureSize(
            displayPixels: CGSize(width: display.pixelWidth, height: display.pixelHeight), stream: (width, height))
        let scaler = capture != (width, height)
            ? RemoteFrameScaler(width: width, height: height, outputFormat: outputFormat) : nil
        let fastScaler = scaler != nil
            ? RemoteFastFrameScaler(width: width, height: height, outputFormat: outputFormat) : nil
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
        // 编码器里最多压着 2 帧、发送端再留 1 帧最新的、静止精修还要拿着最后 1 帧（要缩时还多拿 1 张原始
        // 采集）：留足余量，否则表面池被占满时 SCK 会停住不出帧。
        configuration.queueDepth = scaler != nil ? 7 : 6
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let frameSize = CGSize(width: configuration.width, height: configuration.height)
        queue.sync {
            self.scaler = scaler
            self.fastScaler = fastScaler
            self.configuration = configuration
            self.captureFrameSize = frameSize
        }
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
        lastScaled = nil
        lastRaw = nil
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
        adjustRate(attachments.first, stream: stream, now: nanos)
        var image = captured
        if let scaler {
            // 缩好的帧来自缩放器自己的缓冲池。缩失败就丢这一帧。
            guard let scaled = fastScaler?.scale(captured) ?? scaler.scale(captured) else { return }
            image = scaled
        }
        lock.lock()
        let handler = onFrame
        if scaler != nil {
            // 留着原始采集给精修重缩（只留最后一张，下一帧来就换掉，SCK 的表面随之还回去）。
            lastScaled = fastScaler != nil ? image : nil
            lastRaw = fastScaler != nil ? captured : nil
        }
        lock.unlock()
        handler?(image, nanos)
    }

    func refinedImage(of frame: CVPixelBuffer) -> CVPixelBuffer? {
        lock.lock()
        let raw = lastScaled === frame ? lastRaw : nil
        lock.unlock()
        guard let raw, let scaler else { return nil }
        return scaler.scale(raw)
    }

    /// 按这一帧的变化面积调采集帧率（在 `queue` 上）。改配置是异步的，改完前到的帧照常处理。
    private func adjustRate(_ info: [SCStreamFrameInfo: Any]?, stream: SCStream, now: UInt64) {
        let rects = (info?[.dirtyRects] as? [NSDictionary])?.compactMap { CGRect(dictionaryRepresentation: $0) }
        let fraction = rects.map { RemoteCaptureRateGovernor.dirtyFraction($0, frameSize: captureFrameSize) }
        guard let rate = governor.frame(dirtyFraction: fraction, now: now), let configuration else { return }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(rate))
        AppLogger.debug("远程桌面：采集帧率 → \(rate) fps", category: RemoteLog.category)
        stream.updateConfiguration(configuration) { error in
            if let error {
                AppLogger.info("远程桌面：采集帧率没改成 \(rate) fps：\(error.localizedDescription)",
                               category: RemoteLog.category)
            }
        }
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
    /// 系统「屏幕共享」以高性能模式连着，它的独占虚拟屏把别的显示器都断开了，自己又采不到。
    case heldByScreenSharing

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "找不到要采集的显示器"
        case .heldByScreenSharing: return "这台 Mac 正被系统「屏幕共享」连着，它独占了显示器。断开屏幕共享后再试"
        }
    }
}
