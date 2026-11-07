import AudioToolbox
import Foundation

/// 声音编码与解码，两端都用 AudioToolbox 的 `AudioConverter`（调研 §16.2：Mac 与 iOS 上 Opus 都能编能解，
/// Mac 编的包 iOS 逐样解得一样）。PCM 一律是 48 kHz、立体声、交错的 Float32。
///
/// 不是线程安全的：每个实例只在一条队列上用。
nonisolated enum RemoteAudioPCM {
    static func format(sampleRate: Double = RemoteAudioPolicy.sampleRate,
                       channels: UInt32 = RemoteAudioPolicy.channels) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }
}

nonisolated enum RemoteAudioCodecError: LocalizedError {
    case converter(OSStatus)

    var errorDescription: String? {
        switch self {
        case .converter(let status): return "声音编解码器出错（\(status)）"
        }
    }
}

/// 编出来的一包。
nonisolated struct RemoteAudioPacket: Equatable, Sendable {
    var data: Data
    /// 这一包第一个采样的 Mac 采集时刻（单调时钟纳秒）。
    var captureNanos: UInt64
    /// 这一包是不是整段静音（编码前判定，见 `RemoteAudioPolicy.silenceThreshold`）。
    var isSilent: Bool
}

/// PCM → 压缩包。输入块大小随意，攒够一包就出一包。
nonisolated final class RemoteAudioEncoder {
    let codec: RemoteAudioCodec
    let channels: UInt32
    let sampleRate: Double
    private(set) var framesPerPacket: UInt32
    private let converter: AudioConverterRef
    private let maxPacketBytes: Int

    /// 等着进编码器的交错采样。
    private var pending: [Float] = []
    /// 已交给编码器的采样数（每声道）。
    private var consumedFrames: Int64 = 0
    /// 收到过的采样数（每声道）。
    private var receivedFrames: Int64 = 0
    /// 输入块的起点：第几个采样对应哪个采集时刻。用来给每一包标时刻（采集可能停过一阵，不能只按采样数推）。
    private var anchors: [(frame: Int64, nanos: UInt64)] = []
    /// 已出的包数。
    private var producedPackets: Int64 = 0

    init(codec: RemoteAudioCodec, bitrate: Int, sampleRate: Double = RemoteAudioPolicy.sampleRate,
         channels: UInt32 = RemoteAudioPolicy.channels) throws {
        self.codec = codec
        self.channels = channels
        self.sampleRate = sampleRate
        var input = RemoteAudioPCM.format(sampleRate: sampleRate, channels: channels)
        var output = AudioStreamBasicDescription()
        output.mFormatID = codec.formatID
        output.mSampleRate = sampleRate
        output.mChannelsPerFrame = channels
        if codec == .opus { output.mFramesPerPacket = codec.framesPerPacket }
        var converter: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &converter)
        guard status == noErr, let converter else { throw RemoteAudioCodecError.converter(status) }
        self.converter = converter
        var actual = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioConverterGetProperty(converter, kAudioConverterCurrentOutputStreamDescription, &size, &actual)
        framesPerPacket = actual.mFramesPerPacket > 0 ? actual.mFramesPerPacket : codec.framesPerPacket
        var maxPacket: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacket)
        maxPacketBytes = max(Int(maxPacket), 1500)
        setBitrate(bitrate)
    }

    deinit {
        AudioConverterDispose(converter)
    }

    /// 解码端要的 magic cookie（AAC 有，Opus 通常没有）。
    var magicCookie: Data? {
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie, &size, nil) == noErr,
              size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        guard AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie, &size, &bytes) == noErr else {
            return nil
        }
        return Data(bytes.prefix(Int(size)))
    }

    func setBitrate(_ bitrate: Int) {
        var value = UInt32(bitrate)
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// 交一段交错采样（`captureNanos` = 这段第一个采样的采集时刻），返回这次攒够的包。
    func encode(_ samples: [Float], captureNanos: UInt64) throws -> [RemoteAudioPacket] {
        let frames = Int64(samples.count / Int(channels))
        guard frames > 0 else { return [] }
        anchors.append((receivedFrames, captureNanos))
        recordPeaks(samples, startFrame: receivedFrames)
        receivedFrames += frames
        pending.append(contentsOf: samples)
        var packets: [RemoteAudioPacket] = []
        // 编码器自己也攒采样（开头要多吃一些），所以不按手里剩多少判断，一直要到它说「不够了」为止。
        while let data = try encodeOne() {
            let block = producedPackets
            producedPackets += 1
            let silent = (blockPeaks.removeValue(forKey: block) ?? 0) < RemoteAudioPolicy.silenceThreshold
            packets.append(RemoteAudioPacket(data: data, captureNanos: nanos(forFrame: block * Int64(framesPerPacket)),
                                             isSilent: silent))
        }
        pruneAnchors()
        return packets
    }

    /// 每包（按采样序号切成 `framesPerPacket` 一段）的峰值，出包时据此判静音。
    private var blockPeaks: [Int64: Float] = [:]

    private func recordPeaks(_ samples: [Float], startFrame: Int64) {
        let perPacket = Int64(framesPerPacket)
        let channelCount = Int(channels)
        var index = 0
        var frame = startFrame
        while index < samples.count {
            let block = frame / perPacket
            let framesInBlock = Int(min(perPacket - frame % perPacket, Int64((samples.count - index) / channelCount)))
            guard framesInBlock > 0 else { break }
            var peak = blockPeaks[block] ?? 0
            for sample in samples[index..<(index + framesInBlock * channelCount)] { peak = max(peak, abs(sample)) }
            blockPeaks[block] = peak
            index += framesInBlock * channelCount
            frame += Int64(framesInBlock)
        }
    }

    private func nanos(forFrame frame: Int64) -> UInt64 {
        guard let anchor = anchors.last(where: { $0.frame <= frame }) ?? anchors.first else { return 0 }
        let offset = Double(frame - anchor.frame) / sampleRate * 1e9
        return offset >= 0 ? anchor.nanos &+ UInt64(offset) : anchor.nanos &- UInt64(-offset)
    }

    private func pruneAnchors() {
        let oldest = producedPackets * Int64(framesPerPacket)
        while anchors.count > 1, anchors[1].frame <= oldest { anchors.removeFirst() }
        // 编码器内部最多压着一两包：更早的峰值不会再用到。
        for block in blockPeaks.keys where block < producedPackets - 4 { blockPeaks[block] = nil }
    }

    /// 让编码器出一包。输入不够时返回 nil（编码器还要更多采样，留到下次）。
    private func encodeOne() throws -> Data? {
        var output = [UInt8](repeating: 0, count: maxPacketBytes)
        var packetCount: UInt32 = 1
        var description = AudioStreamPacketDescription()
        let feeder = RemoteAudioFeeder(samples: pending, channels: channels)
        let status = output.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: channels, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, RemoteAudioFeeder.pcmInput,
                                                   Unmanaged.passUnretained(feeder).toOpaque(),
                                                   &packetCount, &list, &description)
        }
        // 已经被编码器取走的采样从队列里去掉（不管有没有出包）。
        let used = feeder.consumedFrames * Int(channels)
        if used > 0 {
            pending.removeFirst(min(used, pending.count))
            consumedFrames += Int64(feeder.consumedFrames)
        }
        guard status == noErr || status == RemoteAudioFeeder.needMore else { throw RemoteAudioCodecError.converter(status) }
        guard packetCount > 0, description.mDataByteSize > 0 else { return nil }
        let start = Int(description.mStartOffset)
        return Data(output[start..<(start + Int(description.mDataByteSize))])
    }
}

/// 压缩包 → PCM。
nonisolated final class RemoteAudioDecoder {
    let format: RemoteDesktopAudioFormat
    private let converter: AudioConverterRef
    private let outputFrames: Int

    init(format: RemoteDesktopAudioFormat) throws {
        guard let codec = format.codec else { throw RemoteAudioCodecError.converter(-1) }
        self.format = format
        var input = AudioStreamBasicDescription()
        input.mFormatID = codec.formatID
        input.mSampleRate = format.sampleRate
        input.mChannelsPerFrame = format.channels
        input.mFramesPerPacket = format.framesPerPacket
        var output = RemoteAudioPCM.format(sampleRate: format.sampleRate, channels: format.channels)
        var converter: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &converter)
        guard status == noErr, let converter else { throw RemoteAudioCodecError.converter(status) }
        self.converter = converter
        if let cookie = format.magicCookie, !cookie.isEmpty {
            var bytes = [UInt8](cookie)
            AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(bytes.count), &bytes)
        }
        outputFrames = Int(format.framesPerPacket) * 2
    }

    deinit {
        AudioConverterDispose(converter)
    }

    /// 解一包，返回交错采样。
    func decode(_ packet: Data) throws -> [Float] {
        guard !packet.isEmpty else { return [] }
        let channels = Int(format.channels)
        var output = [Float](repeating: 0, count: outputFrames * channels)
        var frames = UInt32(outputFrames)
        let feeder = RemoteAudioPacketFeeder(packet: packet)
        let status = output.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(converter, RemoteAudioPacketFeeder.packetInput,
                                                   Unmanaged.passUnretained(feeder).toOpaque(), &frames, &list, nil)
        }
        guard status == noErr || status == RemoteAudioFeeder.needMore else { throw RemoteAudioCodecError.converter(status) }
        return Array(output.prefix(Int(frames) * channels))
    }
}

/// 给编码器喂 PCM 的回调上下文。采样拷进自己分配的内存：编码器在回调返回之后才读，指针必须一直有效。
private nonisolated final class RemoteAudioFeeder {
    /// 「这次没有更多输入了」：返回非零让 `AudioConverterFillComplexBuffer` 带着已出的包回来，
    /// 编码器状态保留（返回 0 帧 + noErr 会被当成流结束）。
    static let needMore: OSStatus = 0x6D6F7265 // 'more'

    private let storage: UnsafeMutableBufferPointer<Float>
    let channels: UInt32
    var consumedFrames = 0

    init(samples: [Float], channels: UInt32) {
        storage = .allocate(capacity: max(1, samples.count))
        _ = storage.initialize(from: samples)
        self.channels = channels
        totalFrames = samples.count / Int(channels)
    }

    private let totalFrames: Int

    deinit {
        storage.deallocate()
    }

    static let pcmInput: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, _, context in
        let feeder = Unmanaged<RemoteAudioFeeder>.fromOpaque(context!).takeUnretainedValue()
        let available = feeder.totalFrames - feeder.consumedFrames
        guard available > 0 else {
            ioPackets.pointee = 0
            return needMore
        }
        let frames = min(Int(ioPackets.pointee), available)
        ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(
            feeder.storage.baseAddress! + feeder.consumedFrames * Int(feeder.channels))
        ioData.pointee.mBuffers.mDataByteSize = UInt32(frames * Int(feeder.channels) * 4)
        ioData.pointee.mBuffers.mNumberChannels = feeder.channels
        ioPackets.pointee = UInt32(frames)
        feeder.consumedFrames += frames
        return noErr
    }
}

/// 给解码器喂一包的回调上下文。同上，字节和包描述都放在自己分配的内存里。
private nonisolated final class RemoteAudioPacketFeeder {
    private let bytes: UnsafeMutableRawBufferPointer
    private let description: UnsafeMutablePointer<AudioStreamPacketDescription>
    private var delivered = false

    init(packet: Data) {
        bytes = .allocate(byteCount: packet.count, alignment: 16)
        packet.copyBytes(to: bytes)
        description = .allocate(capacity: 1)
        description.initialize(to: AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                mDataByteSize: UInt32(packet.count)))
    }

    deinit {
        bytes.deallocate()
        description.deallocate()
    }

    static let packetInput: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDescription, context in
        let feeder = Unmanaged<RemoteAudioPacketFeeder>.fromOpaque(context!).takeUnretainedValue()
        guard !feeder.delivered else {
            ioPackets.pointee = 0
            return RemoteAudioFeeder.needMore
        }
        feeder.delivered = true
        ioData.pointee.mBuffers.mData = feeder.bytes.baseAddress
        ioData.pointee.mBuffers.mDataByteSize = UInt32(feeder.bytes.count)
        ioData.pointee.mBuffers.mNumberChannels = 0
        outDescription?.pointee = feeder.description
        ioPackets.pointee = 1
        return noErr
    }
}
