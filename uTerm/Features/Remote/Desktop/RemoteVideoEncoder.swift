import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 编码器吐出的一帧（AVCC 码流 + 关键帧时的参数集）。
nonisolated struct RemoteEncodedFrame: Sendable {
    var isKeyframe: Bool
    var parameterSets: [Data]
    var data: Data
}

nonisolated enum RemoteVideoEncoderError: Error, Equatable {
    case create(OSStatus)
    case encode(OSStatus)
    /// 码控为守住码率主动丢了这一帧（低延迟模式在码率吃紧时会这么做）。参考链没断，不需要关键帧。
    case dropped
    case noOutput
}

/// 远程桌面视频硬编（`VTCompressionSession`，低延迟码控）。
///
/// 参数依据调研 §3.3 的实测：
/// - `EnableLowLatencyRateControl`：单帧编码 p50 从 10–14 ms 降到 6 ms，码流小一半多；HEVC 在这台机器上也可用。
///   代价是**静默降成 4:2:0**（喂 4:4:4 也一样），所以采集直接要 4:2:0，不白费一次色彩转换。
/// - `RealTime`、不重排（没有 B 帧，编一帧出一帧）、无限 GOP（低延迟模式本身就是），关键帧只按需强制。
/// - 码率由 `RemoteRateController` 动态改；静止精修时临时压低 `MaxAllowedFrameQP`（只有低延迟模式认这个键）。
///
/// 线程：`encode` 可在任意一条串行队列上调；完成回调在 VideoToolbox 自己的线程上。
nonisolated final class RemoteVideoEncoder: @unchecked Sendable {
    /// 精修帧的 QP 上限：越低越清楚、越大。28 在 1080p 桌面上一帧约百来 KB，肉眼看不出块效应。
    static let refineMaxQP = 28
    /// 平时不限 QP（H.264 / HEVC 的上限都是 51）。
    static let unrestrictedQP = 51

    let codec: RemoteVideoCodec
    let width: Int
    let height: Int
    /// 实际是否开上了低延迟码控（老机器不支持时退回普通模式）。
    let isLowLatency: Bool
    private let session: VTCompressionSession
    private let lock = NSLock()
    private var refineFramesInFlight = 0

    init(codec: RemoteVideoCodec, width: Int, height: Int, bitrate: Int, frameRate: Int) throws {
        self.codec = codec
        self.width = width
        self.height = height
        var created: VTCompressionSession?
        var lowLatency = true
        var status = Self.create(codec: codec, width: width, height: height, lowLatency: true, session: &created)
        if status != noErr {
            lowLatency = false
            status = Self.create(codec: codec, width: width, height: height, lowLatency: false, session: &created)
        }
        guard status == noErr, let created else { throw RemoteVideoEncoderError.create(status) }
        session = created
        isLowLatency = lowLatency
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, frameRate as CFNumber)
        // 采集出的是 Display P3 码值（sRGB 曲线），按 709 矩阵转 YUV（见 `ScreenCaptureFrameSource`）。
        // 在码流里如实标出来，手机才按 P3 显示；标成 709 原色时饱和度约低 17%（调研 §14.3）。
        // 这几个值 VideoToolbox 会写进 VUI，解码输出原样带回。
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_P3_D65)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        if !lowLatency {
            // 普通模式下才需要自己关掉周期关键帧；低延迟模式本身是无限 GOP。
            set(kVTCompressionPropertyKey_MaxKeyFrameInterval, Int32.max as CFNumber)
        }
        setBitrate(bitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    private static func create(codec: RemoteVideoCodec, width: Int, height: Int, lowLatency: Bool,
                               session: inout VTCompressionSession?) -> OSStatus {
        var specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        if lowLatency {
            specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }
        return VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                          codecType: codec.codecType,
                                          encoderSpecification: specification as CFDictionary,
                                          imageBufferAttributes: nil, compressedDataAllocator: nil,
                                          outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    }

    @discardableResult
    private func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus {
        VTSessionSetProperty(session, key: key, value: value)
    }

    /// 改目标码率（bit/s）。同时设峰值限制：1 秒内不超过 1.5 倍，防止一次画面突变吐出一大帧把链路塞住。
    func setBitrate(_ bitrate: Int) {
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
    }

    func setFrameRate(_ frameRate: Int) {
        set(kVTCompressionPropertyKey_ExpectedFrameRate, frameRate as CFNumber)
    }

    /// 编一帧。`refine` = 静止精修：这一帧临时放开画质（压低 QP 上限），编完恢复。
    func encode(_ image: CVPixelBuffer, presentationNanos: UInt64, forceKeyframe: Bool, refine: Bool,
                completion: @escaping @Sendable (Result<RemoteEncodedFrame, RemoteVideoEncoderError>) -> Void) {
        if refine {
            lock.lock()
            refineFramesInFlight += 1
            lock.unlock()
            set(kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.refineMaxQP as CFNumber)
        }
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let pts = CMTime(value: CMTimeValue(presentationNanos), timescale: 1_000_000_000)
        let codec = self.codec
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts,
                                                     duration: .invalid, frameProperties: properties,
                                                     infoFlagsOut: nil) { [weak self] status, flags, sample in
            if refine { self?.refineFinished() }
            guard status == noErr else {
                completion(.failure(.encode(status)))
                return
            }
            if sample == nil, flags.contains(.frameDropped) {
                completion(.failure(.dropped))
                return
            }
            guard let sample, let frame = Self.extract(sample, codec: codec) else {
                completion(.failure(.noOutput))
                return
            }
            completion(.success(frame))
        }
        if status != noErr {
            if refine { refineFinished() }
            completion(.failure(.encode(status)))
        }
    }

    private func refineFinished() {
        lock.lock()
        refineFramesInFlight -= 1
        let restore = refineFramesInFlight == 0
        lock.unlock()
        if restore {
            set(kVTCompressionPropertyKey_MaxAllowedFrameQP, Self.unrestrictedQP as CFNumber)
        }
    }

    /// 从编码输出里取出 AVCC 码流；关键帧再带上参数集（解码端靠它建格式描述）。
    static func extract(_ sample: CMSampleBuffer, codec: RemoteVideoCodec) -> RemoteEncodedFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }
        var parameterSets: [Data] = []
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            parameterSets = Self.parameterSets(format, codec: codec)
            if parameterSets.isEmpty { return nil }
        }
        return RemoteEncodedFrame(isKeyframe: isKeyframe, parameterSets: parameterSets, data: data)
    }

    static func parameterSets(_ format: CMFormatDescription, codec: RemoteVideoCodec) -> [Data] {
        var count = 0
        var status: OSStatus
        switch codec {
        case .hevc:
            status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                        parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                        nalUnitHeaderLengthOut: nil)
        case .h264:
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                        parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                        nalUnitHeaderLengthOut: nil)
        }
        guard status == noErr, count > 0 else { return [] }
        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            switch codec {
            case .hevc:
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                                                                            parameterSetPointerOut: &pointer,
                                                                            parameterSetSizeOut: &size,
                                                                            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            case .h264:
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                            parameterSetPointerOut: &pointer,
                                                                            parameterSetSizeOut: &size,
                                                                            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let pointer, size > 0 else { return [] }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
    }
}
