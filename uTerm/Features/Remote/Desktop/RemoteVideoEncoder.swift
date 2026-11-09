import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// 编码器吐出的一帧（AVCC 码流 + 关键帧时的参数集）。
nonisolated struct RemoteEncodedFrame: Sendable {
    var isKeyframe: Bool
    var parameterSets: [Data]
    var data: Data
    /// 这一帧是长期参考帧，手机确认后要交回 `acknowledgeLTR`。
    var ltrToken: UInt64? = nil
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
/// - 码率由 `RemoteRateController` 动态改；QP 上限由 `RemoteQualityCap` 动态改（低延迟码控自己选的 QP 偏高，
///   不压上限它不肯花码率）；静止精修时临时再压低 `MaxAllowedFrameQP`（只有低延迟模式认这个键）。
///
/// 旁路精修（`Purpose.still`）是另一个会话：普通码控、按画质（`stillQuality`）而不是码率编单帧关键帧。
/// 它不进主流的参考链，主流的码控也就不用为这一大帧还账（主流里精修时，之后 30 帧会被码控丢掉一半）。
///
/// 线程：`encode` 可在任意一条串行队列上调；完成回调在 VideoToolbox 自己的线程上。
nonisolated final class RemoteVideoEncoder: @unchecked Sendable {
    enum Purpose {
        /// 主流：低延迟码控，按码率。
        case stream
        /// 旁路精修：普通码控，按画质，每帧都是关键帧。
        case still
    }

    /// 旁路精修的画质。调研 §14 实测（2144×1206 真实桌面，10-bit）：0.75 → 234 KB、41.5 dB；
    /// 0.85 再大 60% 只多 0.5 dB。主流 10 Mbps 静止时是 36 dB。
    static let stillQuality = 0.75
    /// 精修帧的 QP 上限：越低越清楚、越大。28 在 1080p 桌面上一帧约百来 KB，肉眼看不出块效应。
    static let refineMaxQP = 28
    /// 平时不限 QP（H.264 / HEVC 的上限都是 51）。
    static let unrestrictedQP = 51

    let codec: RemoteVideoCodec
    let width: Int
    let height: Int
    /// 实际是否开上了低延迟码控（老机器不支持时退回普通模式）。
    let isLowLatency: Bool
    /// 开上了长期参考帧（只有低延迟模式支持）。
    let usesLTR: Bool
    private let session: VTCompressionSession
    private let lock = NSLock()
    private var acknowledgedLTR: [UInt64] = []
    /// 手机确认过至少一个长期参考帧。没有时不能要 LTR 刷新，见 `encode`。
    private var hasAcknowledgedLTR = false
    private var refineFramesInFlight = 0
    /// 主流平时的 QP 上限；精修帧编完恢复到它。
    private var streamMaxQP = RemoteVideoEncoder.unrestrictedQP

    /// - Parameter tenBit: HEVC Main10。低延迟模式认它，编码耗时不变，同码率画质高 1.4–2.6 dB（调研 §14）。
    ///   H.264 没有 10-bit 硬编，忽略。
    /// - Parameter ltr: 长期参考帧。丢帧时可以发一个只参考已确认帧的 P 帧恢复，比关键帧小 5–8 倍（调研 §15）。
    init(codec: RemoteVideoCodec, width: Int, height: Int, bitrate: Int, frameRate: Int, tenBit: Bool = false,
         purpose: Purpose = .stream, ltr: Bool = false) throws {
        self.codec = codec
        self.width = width
        self.height = height
        var created: VTCompressionSession?
        var lowLatency = purpose == .stream
        var status = Self.create(codec: codec, width: width, height: height, lowLatency: lowLatency, session: &created)
        if status != noErr, lowLatency {
            lowLatency = false
            status = Self.create(codec: codec, width: width, height: height, lowLatency: false, session: &created)
        }
        guard status == noErr, let created else { throw RemoteVideoEncoderError.create(status) }
        session = created
        isLowLatency = lowLatency
        usesLTR = ltr && lowLatency
            && VTSessionSetProperty(created, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue) == noErr
        set(kVTCompressionPropertyKey_RealTime, (purpose == .stream ? kCFBooleanTrue : kCFBooleanFalse)!)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, frameRate as CFNumber)
        if tenBit, codec == .hevc {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel)
        }
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
        switch purpose {
        case .stream: setBitrate(bitrate)
        case .still:
            set(kVTCompressionPropertyKey_Quality, Self.stillQuality as CFNumber)
            // 每帧都是关键帧：不留参考帧，会话占的显存 / 内存少一截（5K 虚拟屏上每张参考帧几十 MB）。
            set(kVTCompressionPropertyKey_AllowTemporalCompression, kCFBooleanFalse)
        }
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

    /// 主流的 QP 上限。精修帧在编时先记下，等它编完再生效。
    func setMaxQP(_ qp: Int) {
        lock.lock()
        streamMaxQP = qp
        let apply = refineFramesInFlight == 0
        lock.unlock()
        // 放开写 51；写 nil 清属性不管用，上限照旧生效。
        if apply { set(kVTCompressionPropertyKey_MaxAllowedFrameQP, qp as CFNumber) }
    }

    /// 手机解出了这个长期参考帧。下一次编码时告诉编码器。
    func acknowledgeLTR(_ token: UInt64) {
        lock.lock()
        acknowledgedLTR.append(token)
        hasAcknowledgedLTR = true
        lock.unlock()
    }

    /// 编一帧。`refine` = 静止精修：这一帧临时放开画质（压低 QP 上限），编完恢复。
    /// `forceLTRRefresh` = 只参考已确认的长期参考帧。一个都没确认时直接改要关键帧：VideoToolbox 虽然也出关键帧，
    /// 但之后的每一帧都跟关键帧一样大（实测 3024×1964 只变 4% 的画面，普通帧 182–307 KB，正常 2–10 KB），
    /// 窄链路上一帧接一帧收不齐、再要刷新，就此卡死（2026-11-08 mini：刚连上第一帧丢了）。
    func encode(_ image: CVPixelBuffer, presentationNanos: UInt64, forceKeyframe: Bool, forceLTRRefresh: Bool = false,
                refine: Bool,
                completion: @escaping @Sendable (Result<RemoteEncodedFrame, RemoteVideoEncoderError>) -> Void) {
        if refine {
            lock.lock()
            refineFramesInFlight += 1
            let qp = min(Self.refineMaxQP, streamMaxQP)
            lock.unlock()
            set(kVTCompressionPropertyKey_MaxAllowedFrameQP, qp as CFNumber)
        }
        var options: [CFString: Any] = [:]
        var forceKeyframe = forceKeyframe
        if usesLTR {
            lock.lock()
            let acknowledged = acknowledgedLTR
            acknowledgedLTR = []
            let canRefresh = hasAcknowledgedLTR
            lock.unlock()
            if forceLTRRefresh, !canRefresh { forceKeyframe = true }
            if !acknowledged.isEmpty {
                options[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acknowledged.map { $0 as NSNumber } as CFArray
            }
            if forceLTRRefresh, !forceKeyframe { options[kVTEncodeFrameOptionKey_ForceLTRRefresh] = kCFBooleanTrue }
        }
        if forceKeyframe { options[kVTEncodeFrameOptionKey_ForceKeyFrame] = kCFBooleanTrue }
        let properties: CFDictionary? = options.isEmpty ? nil : options as CFDictionary
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
        let qp = streamMaxQP
        lock.unlock()
        if restore {
            set(kVTCompressionPropertyKey_MaxAllowedFrameQP, qp as CFNumber)
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
        var ltrToken: UInt64?
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool { isKeyframe = !notSync }
            if let token = first[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? NSNumber {
                ltrToken = token.uint64Value
            }
        }
        var parameterSets: [Data] = []
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            parameterSets = Self.parameterSets(format, codec: codec)
            if parameterSets.isEmpty { return nil }
        }
        return RemoteEncodedFrame(isKeyframe: isKeyframe, parameterSets: parameterSets, data: data, ltrToken: ltrToken)
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
