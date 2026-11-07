import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

nonisolated enum RemoteVideoDecodeError: Error, Equatable {
    /// 还没收到关键帧（或上一个关键帧之后解码出过错），P 帧没有参考，解了也是花屏。
    case needsKeyframe
    case formatDescription(OSStatus)
    case session(OSStatus)
    case decode(OSStatus)
    case noImage
}

/// 远程桌面视频硬解（`VTDecompressionSession`），同步解：调一次 `decode` 拿回一张解好的画面。
///
/// 同步解码是有意的：低延迟流没有 B 帧、不重排，解码器不需要攒帧；同步调用让「这一帧解完了」
/// 的时刻确定，背压确认（`RemoteDesktopAck`）就在这之后发。不是线程安全的，由调用方在一条串行队列上用。
nonisolated final class RemoteVideoDecoder {
    private let outputPixelFormat: OSType
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    /// 解码出过错之后，要等下一个关键帧才继续。
    private(set) var awaitingKeyframe = true

    /// - Parameter outputPixelFormat: 解出来的像素格式。显示用 4:2:0（`AVSampleBufferDisplayLayer` 直接吃，
    ///   零拷贝）；测试比对像素时用 BGRA。
    init(outputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
        self.outputPixelFormat = outputPixelFormat
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        format = nil
        parameterSets = []
        awaitingKeyframe = true
    }

    /// 前面有帧没收到，参考链断了。在关键帧或 LTR 刷新帧之前不能再解：实测把参考断掉的 P 帧喂给 HEVC 硬解，
    /// 它会一直报错（-12909），连之后的 LTR 刷新帧也解不开，所以必须跳过，不能指望解码器自己报错再恢复。
    func markReferenceLost() {
        awaitingKeyframe = true
    }

    func decode(_ frame: RemoteDesktopFrame) throws -> CVPixelBuffer {
        if frame.isKeyframe {
            try prepare(for: frame)
        } else if session == nil || (awaitingKeyframe && !frame.flags.contains(.ltrRefresh)) {
            throw RemoteVideoDecodeError.needsKeyframe
        }
        guard let session, let format else { throw RemoteVideoDecodeError.needsKeyframe }
        do {
            let sample = try Self.sampleBuffer(frame.data, format: format)
            let result = DecodeResult()
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                          infoFlagsOut: nil) { status, _, image, _, _ in
                result.status = status
                result.image = image
            }
            // 同步解码时回调在返回前就已执行；保险起见再等一次（不重排的流里这一步立即返回）。
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            guard status == noErr else { throw RemoteVideoDecodeError.decode(status) }
            guard result.status == noErr else { throw RemoteVideoDecodeError.decode(result.status) }
            guard let output = result.image else { throw RemoteVideoDecodeError.noImage }
            awaitingKeyframe = false
            return output
        } catch {
            awaitingKeyframe = true
            if Self.sessionIsGone(error) { dropSession() }
            throw error
        }
    }

    /// iOS 在 App 退到后台时会收走硬解会话，之后每次解码都报 `kVTInvalidSessionErr`。会话对象还在，
    /// `prepare` 见参数集没变就直接复用它——下一个关键帧照样失败，失败确认又让 Mac 补关键帧，循环下去画面
    /// 一直不出、链路上全是关键帧（白耗电）。报这个错就扔掉会话，下一个关键帧重建。
    static func sessionIsGone(_ error: Error) -> Bool {
        guard case RemoteVideoDecodeError.decode(let status) = error else { return false }
        return status == kVTInvalidSessionErr
    }

    private func dropSession() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        parameterSets = []
    }

    /// 关键帧：参数集变了（开流、Mac 换了分辨率）就重建格式描述；会话接不了新格式就重建会话。
    private func prepare(for frame: RemoteDesktopFrame) throws {
        if frame.parameterSets == parameterSets, session != nil { return }
        let description = try Self.formatDescription(codec: frame.codec, parameterSets: frame.parameterSets)
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: description) {
            format = description
            parameterSets = frame.parameterSets
            return
        }
        if let session {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        var attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: outputPixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        #if os(iOS)
        attributes[kCVPixelBufferMetalCompatibilityKey] = true
        #endif
        var specification: [CFString: Any] = [:]
        #if os(macOS)
        specification[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = true
        #endif
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: description,
                                                  decoderSpecification: specification as CFDictionary,
                                                  imageBufferAttributes: attributes as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else { throw RemoteVideoDecodeError.session(status) }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        format = description
        parameterSets = frame.parameterSets
    }

    /// 解码回调的落点（回调的闭包是 `@Sendable` 的，不能直接改局部变量）。
    private final class DecodeResult: @unchecked Sendable {
        var status: OSStatus = noErr
        var image: CVPixelBuffer?
    }

    static func formatDescription(codec: RemoteVideoCodec, parameterSets: [Data]) throws -> CMVideoFormatDescription {
        // 空的一段取不到 baseAddress（下面会强解包）：坏帧当解码失败处理，不能让 App 崩掉。
        guard !parameterSets.isEmpty, !parameterSets.contains(where: \.isEmpty) else {
            throw RemoteVideoDecodeError.formatDescription(-1)
        }
        // 指针只在闭包里有效：先把每段拷进连续内存，再一次性取指针数组。
        let buffers = parameterSets.map { [UInt8]($0) }
        var description: CMFormatDescription?
        let status: OSStatus = withPointers(buffers) { pointers, sizes in
            switch codec {
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: buffers.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: buffers.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { throw RemoteVideoDecodeError.formatDescription(status) }
        return description
    }

    private static func withPointers<R>(_ buffers: [[UInt8]],
                                        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        var pointers: [UnsafePointer<UInt8>] = []
        func recurse(_ index: Int) -> R {
            if index == buffers.count {
                let sizes = buffers.map(\.count)
                return pointers.withUnsafeBufferPointer { p in
                    sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) }
                }
            }
            return buffers[index].withUnsafeBufferPointer { buffer in
                pointers.append(buffer.baseAddress!)
                return recurse(index + 1)
            }
        }
        return recurse(0)
    }

    /// AVCC 码流 → 一个样本（拷进 CMBlockBuffer 自己的内存，`Data` 的生命周期不用操心）。
    static func sampleBuffer(_ data: Data, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
        guard !data.isEmpty else { throw RemoteVideoDecodeError.decode(-1) }
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw RemoteVideoDecodeError.decode(status) }
        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: data.count)
        }
        guard status == noErr else { throw RemoteVideoDecodeError.decode(status) }
        var sample: CMSampleBuffer?
        var size = data.count
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                           sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw RemoteVideoDecodeError.decode(status) }
        return sample
    }

    /// 解好的画面 → 给 `AVSampleBufferDisplayLayer` 的样本：带 `DisplayImmediately`，到了就显示，不排队等时间戳。
    static func displaySample(_ image: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
