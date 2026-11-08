import Foundation

/// 声音来源：生产是 ScreenCaptureKit 的系统声音，测试是合成音。
nonisolated protocol RemoteAudioSource: AnyObject, Sendable {
    /// 开始采集。`onSamples` 在来源自己的队列上调用：48 kHz 立体声交错 Float32，带第一个采样的采集时刻
    ///（单调时钟纳秒，与视频同一个钟）。
    func start(onSamples: @escaping @Sendable ([Float], UInt64) -> Void,
               onStop: @escaping @Sendable (Error?) -> Void) async throws
    func stop()
}

nonisolated enum RemoteAudioStreamerError: Error {
    /// 手机列出的编码 Mac 一个都建不出编码器。
    case noCodec
}

/// 一条桌面流上的声音发送端（调研 §16）：采集 → 编码 → 静音检测 → 冗余 → 发送。
///
/// - 编码在自己的队列上（Opus 编 1 s 声音约 9 ms），发送回到连接队列（`link.queue`）。
/// - 静音：连续 200 ms 静音就停发，之后每秒发一个静音包；有声了立刻接着发。看代码、打字时没有声音，
///   带宽和手机电量都基本为零。
/// - 直连（数据报）：声音包排在控制之后、视频之前；按链路丢包率带上前一两包当冗余，不重传。
///   TCP（局域网、中继）：普通消息，`link-flow` 下属于紧急消息，不排在视频后面。
nonisolated final class RemoteAudioStreamer: @unchecked Sendable {
    let link: RemoteLink
    let channel: UInt32
    let stream: UInt16
    /// 手机能解的编码，按偏好排；`start` 挑第一个 Mac 也编得出来的。
    private let codecs: [RemoteAudioCodec]
    /// `start` 之后才有值。只在 `start` 里写一次，之后只读。
    private(set) var codec: RemoteAudioCodec = .opus
    let stats = Stats()

    private let datagrams: (any RemoteVideoDatagramChannel)?
    private let source: any RemoteAudioSource
    private let onSourceStopped: @Sendable (Error?) -> Void
    private let encodeQueue = DispatchQueue(label: "com.uozi.uTerm.remote.audio.encode", qos: .userInteractive)
    /// 只在 `encodeQueue` 上。
    private var encoder: RemoteAudioEncoder?

    // 以下只在 link.queue 上。
    private var isStopped = false
    private var nextSequence: UInt32 = 0
    private var silentRun = 0
    private var lastSilenceMarker: UInt64 = 0
    /// 最近发出的两包（冗余用），最新的在后。
    private var history: [Data] = []
    private var bitrate = RemoteAudioPolicy.normalBitrate

    final class Stats: @unchecked Sendable {
        struct Snapshot: Equatable { var sent = 0, bytes = 0, silent = 0, markers = 0 }
        private let lock = NSLock()
        private var value = Snapshot()
        func record(_ update: (inout Snapshot) -> Void) { lock.lock(); update(&value); lock.unlock() }
        func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    }

    init(link: RemoteLink, channel: UInt32, stream: UInt16, codecs: [RemoteAudioCodec],
         datagrams: (any RemoteVideoDatagramChannel)?, source: any RemoteAudioSource,
         onSourceStopped: @escaping @Sendable (Error?) -> Void) {
        self.link = link
        self.channel = channel
        self.stream = stream
        self.codecs = codecs
        self.datagrams = datagrams
        self.source = source
        self.onSourceStopped = onSourceStopped
    }

    /// 建编码器、开采集，返回要先发给手机的格式。手机能解的编码 Mac 一个都编不了（`RemoteAudioStreamerError.noCodec`）
    /// 或采集开不了就抛错。
    func start() async throws -> RemoteDesktopAudioFormat {
        var built: (RemoteAudioCodec, RemoteAudioEncoder)?
        for candidate in codecs {
            if let encoder = try? RemoteAudioEncoder(codec: candidate, bitrate: RemoteAudioPolicy.normalBitrate) {
                built = (candidate, encoder)
                break
            }
        }
        guard let (codec, encoder) = built else { throw RemoteAudioStreamerError.noCodec }
        self.codec = codec
        let format = RemoteDesktopAudioFormat(stream: stream, codec: codec, framesPerPacket: encoder.framesPerPacket,
                                              magicCookie: encoder.magicCookie)
        encodeQueue.sync { self.encoder = encoder }
        try await source.start(
            onSamples: { [weak self] samples, nanos in self?.captured(samples, nanos) },
            onStop: { [weak self] error in
                guard let self else { return }
                self.link.queue.async {
                    guard !self.isStopped else { return }
                    self.onSourceStopped(error)
                }
            })
        return format
    }

    func stop() {
        link.queue.async { self.isStopped = true }
        encodeQueue.async { self.encoder = nil }
        source.stop()
    }

    /// 来源队列上。
    private func captured(_ samples: [Float], _ nanos: UInt64) {
        encodeQueue.async { [weak self] in
            guard let self, let encoder = self.encoder else { return }
            guard let packets = try? encoder.encode(samples, captureNanos: nanos), !packets.isEmpty else { return }
            self.link.queue.async { self.send(packets) }
        }
    }

    private func send(_ packets: [RemoteAudioPacket]) {
        guard !isStopped else { return }
        let state = link.datagramLinkState
        let wanted = RemoteAudioPolicy.bitrate(pacingRate: datagrams != nil ? state?.pacingRate : nil)
        if wanted != bitrate {
            bitrate = wanted
            encodeQueue.async { [weak self] in self?.encoder?.setBitrate(wanted) }
        }
        let redundancy = datagrams != nil ? RemoteAudioPolicy.redundancy(lossRate: state?.lossRate ?? 0) : 0
        let holdPackets = Int(RemoteAudioPolicy.silenceHoldNanos / UInt64(Double(codec.framesPerPacket) / 48_000 * 1e9))
        for packet in packets {
            let sequence = nextSequence
            nextSequence &+= 1
            silentRun = packet.isSilent ? silentRun + 1 : 0
            if silentRun > holdPackets {
                // 已经静了一阵：不发声音，只每秒报一次「到这里都是静音」。冗余也断开，免得把静音前的包又带一遍。
                history.removeAll()
                stats.record { $0.silent += 1 }
                if packet.captureNanos &- lastSilenceMarker >= RemoteAudioPolicy.silenceHeartbeatNanos {
                    lastSilenceMarker = packet.captureNanos
                    transmit(RemoteDesktopAudioFrame(flags: .silence, stream: stream, sequence: sequence,
                                                     captureNanos: packet.captureNanos, data: Data()))
                    stats.record { $0.markers += 1 }
                }
                continue
            }
            let frame = RemoteDesktopAudioFrame(stream: stream, sequence: sequence, captureNanos: packet.captureNanos,
                                                data: packet.data, redundant: Array(history.reversed().prefix(redundancy)))
            history.append(packet.data)
            if history.count > 2 { history.removeFirst(history.count - 2) }
            transmit(frame)
            stats.record {
                $0.sent += 1
                $0.bytes += packet.data.count
            }
        }
    }

    private func transmit(_ frame: RemoteDesktopAudioFrame) {
        let payload = frame.encoded()
        if let datagrams {
            datagrams.sendAudio(payload, channel: channel)
        } else {
            link.sendOnQueue(RemoteMessage(.desktopAudioFrame, channel: channel, payload: payload))
        }
    }
}
