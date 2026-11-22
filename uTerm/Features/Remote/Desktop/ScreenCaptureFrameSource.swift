import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit 采集一块显示器（调研 §3.2），或只采一个窗口（`display.windowID` 不为 nil）。
///
/// 只采一个窗口时（2026-11-17 探针，macOS 27.2.1）：
/// - 窗口被别的窗口挡住、一半在屏幕外都照采；面板、子窗口、弹出的菜单也在画面里。只有一种情形一帧都不出：
///   开流那一刻它正被同一个 App 的另一个窗口整个盖住（被别的 App 的窗口盖住、或者流已经在跑时才被盖住，都照出）。
///   没完全摸清，而且点击只会落到最上面的窗口上，所以开流前一律先把窗口提到最前（`RemoteDesktopWindows.raise`）。
/// - 输出尺寸开流后不变。窗口改大小、菜单伸出窗口时，系统把新的范围等比缩进同一帧、靠左上角放；每帧附带的几何
///   解成 `RemoteDesktopFrameGeometry` 报给 `observeGeometry` 的回调。
/// - 画面不变时系统照样一帧帧地出（`dirtyRects` 恒为整帧，不出 `idle`）：这里逐字节和上一张比，一样就不交出去，
///   否则静止精修永远轮不到、编码器也一直空转。
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
    /// 采集目标与要出的画面尺寸。只看一个窗口时原地换尺寸会改（`retarget`，在 `queue` 上改）。
    private var display: RemoteDesktopDisplay
    private var width: Int
    private var height: Int
    private let frameRate: Int
    private let tenBit: Bool
    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    /// 采集尺寸比视频大时才有。`start` 里在开始采集之前挂上，之后不变。运动帧用快的，精修用 Lanczos；
    /// 快的建不起来时运动帧也用 Lanczos。
    private var scaler: RemoteFrameScaler?
    private var fastScaler: RemoteFastFrameScaler?
    /// `scaler` 的一份，给精修用（`refinedImage` 在别的队列上调）。受 `lock` 保护。
    private var refineScaler: RemoteFrameScaler?
    /// 最后交出去的那帧（缩过的）与它的原始采集：精修时据此重缩。受 `lock` 保护。
    private var lastScaled: CVPixelBuffer?
    private var lastRaw: CVPixelBuffer?
    /// 以下只在 `queue` 上用：采集帧率的调速、当前配置（改帧率时整份交回 SCK）、采集尺寸。
    private var governor: RemoteCaptureRateGovernor
    private var configuration: SCStreamConfiguration?
    private var captureFrameSize = CGSize.zero
    /// 原地换尺寸之后在等的采集尺寸（像素）和开始等的时刻：到这个尺寸的帧出来之前，旧尺寸的帧不交出去。
    private var awaitedCaptureSize: (width: Int, height: Int, since: UInt64)?
    /// 最多等这么久，系统一直不出新尺寸的帧就不等了。
    static let retargetWaitNanos: UInt64 = 1_000_000_000
    private var onFrame: (@Sendable (CVPixelBuffer, UInt64) -> Void)?
    private var onStop: (@Sendable (Error?) -> Void)?
    /// 以下只在按窗口采集时用。`onGeometry` 在 `start` 之前设好、之后不变；另两个只在 `queue` 上用。
    private var onGeometry: (@Sendable (RemoteDesktopFrameGeometry) -> Void)?
    private var lastGeometry: RemoteDesktopFrameGeometry?
    /// 上一张原始采集：和新来的逐字节比，一样就丢。
    private var previousCapture: CVPixelBuffer?
    /// 主控端放大后只取这一块（nil = 整块）。只有采集比视频大（要缩）时才有意义：采集本来就是视频尺寸时已经是
    /// 原生像素，裁了也不会更清楚。只在 `queue` 上用。
    private var region: RemoteDesktopRegion?
    /// 最后一张原始采集：区域一换就拿它按新的一块重出一帧（屏幕静止时系统不会再送帧来）。只在 `queue` 上用。
    private var lastCapture: CVPixelBuffer?
    /// 开流时定的采集尺寸（按整数倍缩小的那一档）。按区域取时换成原生像素，回到整块再换回来。只在 `queue` 上用。
    private var baseCaptureSize = (width: 0, height: 0)
    /// 最后交出去那帧取的是哪一块、裁的像素矩形：精修重缩时照样裁。受 `lock` 保护。
    private var lastRegion: RemoteDesktopRegion?
    private var lastCrop: CGRect?

    /// 等可采集列表里出现这块屏最多多久、隔多久问一次。
    static let listingLimit: Duration = .seconds(2)
    static let listingRetry: Duration = .milliseconds(25)

    init(display: RemoteDesktopDisplay, width: Int, height: Int, tenBit: Bool, frameRate: Int = 60) {
        self.display = display
        self.width = width
        self.height = height
        self.tenBit = tenBit
        self.frameRate = frameRate
        governor = RemoteCaptureRateGovernor(fullRate: frameRate)
    }

    func observeGeometry(_ handler: @escaping @Sendable (RemoteDesktopFrameGeometry) -> Void) {
        lock.lock(); defer { lock.unlock() }
        onGeometry = handler
    }

    func start(onFrame: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void,
               onStop: @escaping @Sendable (Error?) -> Void) async throws {
        let filter: SCContentFilter
        if let windowID = display.windowID {
            filter = try await windowFilter(windowID)
        } else {
            filter = try await displayFilter()
        }
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
        // 采集）：再留 1 张余量，否则表面池被占满时 SCK 会停住不出帧。余量从 2 张减到 1 张：5K 虚拟屏上每张
        // 采集表面约 30 MB（10-bit），mini 上 uTerm + WindowServer 的常驻内存因此少约 60 MB。
        // 按窗口采集时这里还拿着上一张做比对，多留 1 张。
        configuration.queueDepth = (scaler != nil ? 6 : 5) + (display.windowID != nil ? 1 : 0)
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let frameSize = CGSize(width: configuration.width, height: configuration.height)
        lock.withLock { refineScaler = scaler }
        queue.sync {
            self.scaler = scaler
            self.fastScaler = fastScaler
            self.configuration = configuration
            self.captureFrameSize = frameSize
            self.baseCaptureSize = (configuration.width, configuration.height)
        }
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        install(stream: stream, onFrame: onFrame, onStop: onStop)
        try await stream.startCapture()
    }

    /// 只含这一个窗口的 filter。窗口刚被提到最前、刚换了桌面时列表里可能还没有它：同显示器一样等一会儿。
    private func windowFilter(_ windowID: UInt32) async throws -> SCContentFilter {
        let clock = ContinuousClock()
        let started = clock.now
        while true {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let window = content.windows.first(where: { $0.windowID == windowID }) {
                return SCContentFilter(desktopIndependentWindow: window)
            }
            if clock.now - started >= Self.listingLimit { throw RemoteDesktopCaptureError.windowNotFound }
            try? await Task.sleep(for: Self.listingRetry)
        }
    }

    private func displayFilter() async throws -> SCContentFilter {
        // 显示器刚醒来、虚拟屏刚建好时，可采集列表要过一会儿才有它：找不到就隔一会儿再问，最多约 2 秒。
        // 隔 25 ms 问一次（一次约 7 ms）：以前隔 200 ms，刚建好的虚拟屏第一次问不到，白等 200 ms
        //（2026-11-16 mini：建屏后的开屏「第一帧已发出」一组 89–140 ms、一组 325–375 ms）。
        var target: SCDisplay?
        let clock = ContinuousClock()
        let started = clock.now
        var attempts = 0
        while true {
            attempts += 1
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            target = content.displays.first(where: { $0.displayID == display.id })
            if target != nil || clock.now - started >= Self.listingLimit { break }
            try? await Task.sleep(for: Self.listingRetry)
        }
        if attempts > 1 {
            AppLogger.notice("远程桌面：采集列表第 \(attempts) 次才有这块屏（等了 \(RemoteConnectTrace.millis(clock.now - started)) ms）",
                             category: RemoteLog.category)
        }
        guard let target else {
            throw RemoteHeadlessDisplay.screenSharingHoldsDisplay()
                ? RemoteDesktopCaptureError.heldByScreenSharing : RemoteDesktopCaptureError.displayNotFound
        }
        return SCContentFilter(display: target, excludingWindows: [])
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
        queue.async {
            self.previousCapture = nil
            self.lastCapture = nil
        }
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
        if let awaited = awaitedCaptureSize {
            // 刚原地换过尺寸：系统换好之前出来的还是旧尺寸的帧，交出去会被按新尺寸硬缩，比例是错的。丢掉。
            let arrived = CVPixelBufferGetWidth(captured) == awaited.width && CVPixelBufferGetHeight(captured) == awaited.height
            guard arrived || nanos &- awaited.since > Self.retargetWaitNanos else { return }
            awaitedCaptureSize = nil
        }
        if display.windowID != nil {
            reportGeometry(attachments.first, captured: captured)
            // 画面没变（系统照样出帧）：不交出去，采集帧率按「没在变」算。
            let unchanged = previousCapture.map { RemoteFrameCompare.identical($0, captured) } ?? false
            previousCapture = captured
            adjustRate(dirtyFraction: unchanged ? 0 : 1, stream: stream, now: nanos)
            if unchanged { return }
        } else {
            adjustRate(attachments.first, stream: stream, now: nanos)
        }
        deliver(captured, nanos: nanos)
    }

    /// 把一张原始采集缩成视频尺寸（按区域取时只取那一块）交出去。在 `queue` 上。
    private func deliver(_ captured: CVPixelBuffer, nanos: UInt64) {
        var image = captured
        var crop: CGRect?
        if let scaler {
            crop = region.map {
                RemoteDesktopRegionPolicy.pixelRect(
                    $0, frameSize: CGSize(width: CVPixelBufferGetWidth(captured), height: CVPixelBufferGetHeight(captured)),
                    contentFraction: lastGeometry?.contentFraction ?? CGSize(width: 1, height: 1))
            }
            // 缩好的帧来自缩放器自己的缓冲池。缩失败就丢这一帧。
            guard let scaled = fastScaler?.scale(captured, crop: crop) ?? scaler.scale(captured, crop: crop) else { return }
            // 池里的缓冲轮着用：整块的帧也要把上一轮的区域标记摘掉。
            RemoteFrameRegionTag.set(region, on: scaled)
            image = scaled
            lastCapture = captured
        }
        lock.lock()
        let handler = onFrame
        if scaler != nil {
            // 留着原始采集给精修重缩（只留最后一张，下一帧来就换掉，SCK 的表面随之还回去）。
            lastScaled = fastScaler != nil ? image : nil
            lastRaw = fastScaler != nil ? captured : nil
            lastRegion = region
            lastCrop = crop
        }
        lock.unlock()
        handler?(image, nanos)
    }

    func refinedImage(of frame: CVPixelBuffer) -> CVPixelBuffer? {
        lock.lock()
        let raw = lastScaled === frame ? lastRaw : nil
        let region = lastRegion, crop = lastCrop
        let scaler = refineScaler
        lock.unlock()
        guard let raw, let scaler, let refined = scaler.scale(raw, crop: crop) else { return nil }
        RemoteFrameRegionTag.set(region, on: refined)
        return refined
    }

    /// 窗口改了大小：同一条采集流接着用，只把目标和输出尺寸换掉（`SCStream.updateConfiguration`），不重开。
    /// 重开一条流到出第一帧要一百多毫秒；改配置是异步的，改完前到的帧还是旧尺寸，推流器先缩着用。
    func retarget(display: RemoteDesktopDisplay, width: Int, height: Int) {
        queue.async { [self] in
            self.display = display
            self.width = width
            self.height = height
            guard let configuration else { return }
            let outputFormat = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let capture = RemoteDesktopGeometry.captureSize(
                displayPixels: CGSize(width: display.pixelWidth, height: display.pixelHeight), stream: (width, height))
            let scaler = capture != (width, height)
                ? RemoteFrameScaler(width: width, height: height, outputFormat: outputFormat) : nil
            let fastScaler = scaler != nil
                ? RemoteFastFrameScaler(width: width, height: height, outputFormat: outputFormat) : nil
            configuration.width = scaler != nil ? capture.width : width
            configuration.height = scaler != nil ? capture.height : height
            configuration.pixelFormat = scaler != nil ? kCVPixelFormatType_32BGRA : outputFormat
            self.scaler = scaler
            self.fastScaler = fastScaler
            if CGSize(width: configuration.width, height: configuration.height) != captureFrameSize {
                awaitedCaptureSize = (configuration.width, configuration.height, DispatchTime.now().uptimeNanoseconds)
            }
            captureFrameSize = CGSize(width: configuration.width, height: configuration.height)
            baseCaptureSize = (configuration.width, configuration.height)
            // 按旧尺寸留着的东西都作废：比对用的上一张、按区域重出用的那张、几何（下一帧重新报）。
            region = nil
            lastCapture = nil
            previousCapture = nil
            lastGeometry = nil
            lock.lock()
            refineScaler = scaler
            lastScaled = nil
            lastRaw = nil
            lastRegion = nil
            lastCrop = nil
            let stream = self.stream
            lock.unlock()
            guard let stream else { return }
            let size = (configuration.width, configuration.height)
            stream.updateConfiguration(configuration) { error in
                if let error {
                    AppLogger.info("远程桌面：采集尺寸没改成 \(size.0)×\(size.1)：\(error.localizedDescription)",
                                   category: RemoteLog.category)
                }
            }
        }
    }

    func setRegion(_ visible: RemoteDesktopRegion?) {
        queue.async { [self] in
            guard scaler != nil else { return }
            let next = visible.flatMap {
                RemoteDesktopRegionPolicy.captureRegion(
                    visible: $0, current: region,
                    targetPixels: CGSize(width: display.pixelWidth, height: display.pixelHeight), stream: (width, height))
            }
            guard next != region else { return }
            region = next
            resizeCapture(native: next != nil)
            // 屏幕静止时不会有新帧来：拿最后一张按新的一块马上重出。
            if let lastCapture { deliver(lastCapture, nanos: DispatchTime.now().uptimeNanoseconds) }
        }
    }

    /// 按区域取时要原生像素：开流时采集可能按整数倍缩小了（5K 屏给手机时采一半），这时改回原生；回到整块再改回去。
    /// 改配置是异步的，改完前到的帧还是旧尺寸，裁的矩形按每帧自己的尺寸算，只是那几帧没那么清楚。在 `queue` 上。
    private func resizeCapture(native: Bool) {
        guard let configuration else { return }
        let size = native ? (width: display.pixelWidth & ~1, height: display.pixelHeight & ~1) : baseCaptureSize
        guard size.width > 0, size.height > 0,
              configuration.width != size.width || configuration.height != size.height else { return }
        lock.lock()
        let stream = self.stream
        lock.unlock()
        guard let stream else { return }
        configuration.width = size.width
        configuration.height = size.height
        captureFrameSize = CGSize(width: size.width, height: size.height)
        stream.updateConfiguration(configuration) { error in
            if let error {
                AppLogger.info("远程桌面：采集尺寸没改成 \(size.width)×\(size.height)：\(error.localizedDescription)",
                               category: RemoteLog.category)
            }
        }
    }

    /// 这一帧附带的几何和上一帧不一样就报出去（在 `queue` 上）。
    private func reportGeometry(_ info: [SCStreamFrameInfo: Any]?, captured: CVPixelBuffer) {
        func rect(_ key: SCStreamFrameInfo) -> CGRect? {
            (info?[key] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        }
        guard let contentRect = rect(.contentRect), let screenRect = rect(.screenRect),
              let contentScale = (info?[.contentScale] as? NSNumber)?.doubleValue,
              let scaleFactor = (info?[.scaleFactor] as? NSNumber)?.doubleValue,
              let geometry = RemoteDesktopFrameGeometry.make(
                contentRect: contentRect, contentScale: contentScale, scaleFactor: scaleFactor, screenRect: screenRect,
                frameSize: CGSize(width: CVPixelBufferGetWidth(captured), height: CVPixelBufferGetHeight(captured))),
              geometry != lastGeometry else { return }
        lastGeometry = geometry
        lock.lock()
        let handler = onGeometry
        lock.unlock()
        handler?(geometry)
    }

    /// 按这一帧的变化面积调采集帧率（在 `queue` 上）。改配置是异步的，改完前到的帧照常处理。
    private func adjustRate(_ info: [SCStreamFrameInfo: Any]?, stream: SCStream, now: UInt64) {
        let rects = (info?[.dirtyRects] as? [NSDictionary])?.compactMap { CGRect(dictionaryRepresentation: $0) }
        let fraction = rects.map { RemoteCaptureRateGovernor.dirtyFraction($0, frameSize: captureFrameSize) }
        adjustRate(dirtyFraction: fraction, stream: stream, now: now)
    }

    private func adjustRate(dirtyFraction fraction: Double?, stream: SCStream, now: UInt64) {
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

/// 两张采集帧是不是逐字节一样（同格式、同尺寸才比）。只比每行用到的字节，行尾的填充不算。
nonisolated enum RemoteFrameCompare {
    static func identical(_ first: CVPixelBuffer, _ second: CVPixelBuffer) -> Bool {
        guard first !== second else { return true }
        guard CVPixelBufferGetPixelFormatType(first) == CVPixelBufferGetPixelFormatType(second),
              CVPixelBufferGetWidth(first) == CVPixelBufferGetWidth(second),
              CVPixelBufferGetHeight(first) == CVPixelBufferGetHeight(second) else { return false }
        CVPixelBufferLockBaseAddress(first, .readOnly)
        CVPixelBufferLockBaseAddress(second, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(second, .readOnly)
            CVPixelBufferUnlockBaseAddress(first, .readOnly)
        }
        let planar = CVPixelBufferIsPlanar(first)
        for plane in 0..<(planar ? CVPixelBufferGetPlaneCount(first) : 1) {
            let width = planar ? CVPixelBufferGetWidthOfPlane(first, plane) : CVPixelBufferGetWidth(first)
            let height = planar ? CVPixelBufferGetHeightOfPlane(first, plane) : CVPixelBufferGetHeight(first)
            let firstStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(first, plane) : CVPixelBufferGetBytesPerRow(first)
            let secondStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(second, plane) : CVPixelBufferGetBytesPerRow(second)
            guard width > 0, height > 0,
                  let firstBase = planar ? CVPixelBufferGetBaseAddressOfPlane(first, plane) : CVPixelBufferGetBaseAddress(first),
                  let secondBase = planar ? CVPixelBufferGetBaseAddressOfPlane(second, plane) : CVPixelBufferGetBaseAddress(second)
            else { return false }
            // 每个采样几个字节：行跨度除以宽（BGRA 是 4，4:2:0 的色度面是 2，10-bit 各翻倍）。
            let rowBytes = min(firstStride, secondStride, width * max(1, min(firstStride, secondStride) / width))
            for row in 0..<height where memcmp(firstBase + row * firstStride, secondBase + row * secondStride, rowBytes) != 0 {
                return false
            }
        }
        return true
    }
}

nonisolated enum RemoteDesktopCaptureError: LocalizedError {
    case displayNotFound
    /// 要看的那个窗口没了（关了、挪到别的桌面去了）。
    case windowNotFound
    /// 系统「屏幕共享」以高性能模式连着，它的独占虚拟屏把别的显示器都断开了，自己又采不到。
    case heldByScreenSharing

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return String(localized: "找不到要采集的显示器")
        case .windowNotFound: return String(localized: "找不到要看的窗口，它可能已经关闭或挪到了别的桌面")
        case .heldByScreenSharing: return String(localized: "这台 Mac 正被系统「屏幕共享」连着，它独占了显示器。断开屏幕共享后再试")
        }
    }
}
