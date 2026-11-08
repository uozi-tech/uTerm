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

/// 一条桌面流上的声音发送端（调研 §17）：采集 → 编码 → 静音检测 → 冗余 → 发送。
///
/// - 编码在自己的队列上（Opus 编 1 s 声音约 9 ms），发送回到连接队列（`link.queue`）。
/// - 档位（`RemoteAudioPolicy.profile`）：按链路容量挑码率，声音最多占 3%；宽裕且不丢包时用无损。
///   只改码率直接调编码器；换编码或包长（Opus 20 ms ↔ 10 ms、Opus ↔ 无损）时换一个流号、先发新格式，
///   手机见到新流号重建解码器。降档立刻、升档要连续 5 秒够格（`RemoteAudioTierSelector`）。
/// - 静音：连续 200 ms 静音就停发，之后每秒发一个静音包；有声了立刻接着发，并把停发前最后一包当冗余带上，
///   让手机的解码器先接上状态（不然恢复的第一包可能带一个小咔哒）。
/// - 直连（数据报）：声音包排在控制之后、视频之前；按链路丢包率带上前一两包当冗余，不重传。一包放不进
///   数据报（无损遇到很「满」的声音时）就改走可靠通道。
///   TCP（局域网、中继）：普通消息，`link-flow` 下属于紧急消息，不排在视频后面。
nonisolated final class RemoteAudioStreamer: @unchecked Sendable {
    let link: RemoteLink
    let channel: UInt32
    /// 开流时的流号（换档后会换新的，见 `currentStream`）。
    let stream: UInt16
    /// 手机能解的编码，按偏好排；`start` 挑第一个 Mac 也编得出来的。
    private let codecs: [RemoteAudioCodec]
    /// 换档要新流号时从这里取（与连接上开新声音流共用一个计数，不会撞号）。
    private let nextStream: @Sendable () -> UInt16
    /// 链路眼下的情况，只在 `link.queue` 上调。
    private let linkInfo: () -> RemoteAudioPolicy.Link
    /// `start` 之后才有值。只在 `start` 里写一次，之后只读。
    private(set) var codec: RemoteAudioCodec = .opus
    let stats = Stats()

    private let datagrams: (any RemoteVideoDatagramChannel)?
    private let source: any RemoteAudioSource
    private let onSourceStopped: @Sendable (Error?) -> Void
    private let encodeQueue = DispatchQueue(label: "com.uozi.uTerm.remote.audio.encode", qos: .userInteractive)
    /// 只在 `encodeQueue` 上：编码器和它编出的包属于哪个流。
    private var encoder: RemoteAudioEncoder?
    private var encoderStream: UInt16 = 0

    // 以下只在 link.queue 上。
    private var isStopped = false
    /// 正在发的流（已经给手机发过格式的）。
    private var currentStream: UInt16 = 0
    private var currentFramesPerPacket: UInt32 = 960
    private var nextSequence: UInt32 = 0
    private var silentRun = 0
    private var lastSilenceMarker: UInt64 = 0
    /// 最近编出的两包（冗余用），最新的在后。静音停发期间只留最后一包，恢复时带上。
    private var history: [Data] = []
    /// 按档位走（只有 Opus 编得出来时才分档；退到 AAC-ELD 时固定）。
    private var selector: RemoteAudioTierSelector?
    /// 换编码器途中：新格式还没发，别再动档位。
    private var switching = false
    /// 无损建不出编码器过一次就不再试。
    private var losslessFailed = false
    /// 正处在静音停发里：下一包有声的要带上停发前最后一包。
    private var suppressing = false

    final class Stats: @unchecked Sendable {
        struct Snapshot: Equatable { var sent = 0, bytes = 0, silent = 0, markers = 0, reliable = 0, switches = 0 }
        private let lock = NSLock()
        private var value = Snapshot()
        func record(_ update: (inout Snapshot) -> Void) { lock.lock(); update(&value); lock.unlock() }
        func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    }

    init(link: RemoteLink, channel: UInt32, stream: UInt16, codecs: [RemoteAudioCodec],
         nextStream: @escaping @Sendable () -> UInt16,
         linkInfo: @escaping () -> RemoteAudioPolicy.Link,
         datagrams: (any RemoteVideoDatagramChannel)?, source: any RemoteAudioSource,
         onSourceStopped: @escaping @Sendable (Error?) -> Void) {
        self.link = link
        self.channel = channel
        self.stream = stream
        self.codecs = codecs
        self.nextStream = nextStream
        self.linkInfo = linkInfo
        self.datagrams = datagrams
        self.source = source
        self.onSourceStopped = onSourceStopped
        currentStream = stream
    }

    /// 眼下的档位（测试与日志用）。只在 `link.queue` 上读。
    var currentProfile: RemoteAudioProfile? { selector?.current }

    /// 建编码器、开采集，返回要先发给手机的格式。手机能解的编码 Mac 一个都编不了（`RemoteAudioStreamerError.noCodec`）
    /// 或采集开不了就抛错。
    func start() async throws -> RemoteDesktopAudioFormat {
        var built: (RemoteAudioCodec, RemoteAudioEncoder, RemoteAudioTierSelector?)?
        if codecs.contains(.opus) {
            let info = link.queue.sync { linkInfo() }
            let selector = RemoteAudioTierSelector(initial: RemoteAudioPolicy.profile(for: info))
            if case .opus(let bitrate, _) = selector.current,
               let encoder = try? RemoteAudioEncoder(codec: .opus, bitrate: bitrate,
                                                     framesPerPacket: selector.current.framesPerPacket) {
                built = (.opus, encoder, selector)
            }
        }
        if built == nil {
            for candidate in codecs where candidate != .opus && candidate != .alac {
                if let encoder = try? RemoteAudioEncoder(codec: candidate, bitrate: RemoteAudioPolicy.relayBitrate) {
                    built = (candidate, encoder, nil)
                    break
                }
            }
        }
        guard let (codec, encoder, selector) = built else { throw RemoteAudioStreamerError.noCodec }
        self.codec = codec
        let format = Self.format(stream: stream, encoder: encoder)
        encodeQueue.sync {
            self.encoder = encoder
            self.encoderStream = stream
        }
        link.queue.sync {
            self.selector = selector
            self.currentFramesPerPacket = encoder.framesPerPacket
        }
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

    private static func format(stream: UInt16, encoder: RemoteAudioEncoder) -> RemoteDesktopAudioFormat {
        RemoteDesktopAudioFormat(stream: stream, codec: encoder.codec, framesPerPacket: encoder.framesPerPacket,
                                 magicCookie: encoder.magicCookie)
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
            let stream = self.encoderStream
            self.link.queue.async { self.send(packets, stream: stream) }
        }
    }

    // MARK: - 档位

    /// 按链路情况调档。只改码率就地调；要换编码器时去编码队列换，换好再回来发新格式。
    private func adjustProfile() {
        guard var selector, !switching else { return }
        let before = selector
        var info = linkInfo()
        if losslessFailed { info.peerDecodesLossless = false }
        info.peerDecodesLossless = info.peerDecodesLossless && codecs.contains(.alac)
        let previous = selector.current
        guard selector.update(RemoteAudioPolicy.profile(for: info), now: DispatchTime.now().uptimeNanoseconds) else {
            self.selector = selector
            return
        }
        let next = selector.current
        self.selector = selector
        stats.record { $0.switches += 1 }
        guard next.needsNewEncoder(from: previous) else {
            if let bitrate = next.bitrate { encodeQueue.async { [weak self] in self?.encoder?.setBitrate(bitrate) } }
            return
        }
        switching = true
        let stream = nextStream()
        encodeQueue.async { [weak self] in
            guard let self, self.encoder != nil else { return }
            let built = try? RemoteAudioEncoder(codec: next.codec, bitrate: next.bitrate ?? RemoteAudioPolicy.opusMax,
                                                framesPerPacket: next.framesPerPacket)
            if let built {
                self.encoder = built
                self.encoderStream = stream
            }
            let format = built.map { (Self.format(stream: stream, encoder: $0), $0.framesPerPacket) }
            self.link.queue.async { self.finishSwitch(to: format, profile: next, restoring: before) }
        }
    }

    private func finishSwitch(to built: (RemoteDesktopAudioFormat, UInt32)?, profile: RemoteAudioProfile,
                              restoring before: RemoteAudioTierSelector) {
        switching = false
        guard !isStopped else { return }
        guard let (format, framesPerPacket) = built else {
            // 建不出来（这台 Mac 编不了无损之类）：留在原来那档，无损以后不再试。
            if profile == .lossless { losslessFailed = true }
            selector = before
            return
        }
        link.sendOnQueue(RemoteMessage(.desktopAudioFormat, channel: channel, payload: RemoteJSON.encode(format)))
        AppLogger.info("远程桌面声音：换档到 \(Self.describe(profile))", category: RemoteLog.category)
        currentStream = format.stream
        currentFramesPerPacket = framesPerPacket
        nextSequence = 0
        silentRun = 0
        lastSilenceMarker = 0
        suppressing = false
        history.removeAll()
    }

    static func describe(_ profile: RemoteAudioProfile) -> String {
        switch profile {
        case .opus(let bitrate, let frameMillis): return "Opus \(bitrate / 1000) kbps（\(frameMillis) ms 一包）"
        case .lossless: return "无损（ALAC）"
        }
    }

    // MARK: - 发送

    private func send(_ packets: [RemoteAudioPacket], stream: UInt16) {
        guard !isStopped else { return }
        // 换档后旧编码器剩下的包：手机已经按新格式收了，旧流号的包它也不认，丢掉。
        guard stream == currentStream else { return }
        adjustProfile()
        let lossRate = datagrams != nil ? (link.datagramLinkState?.lossRate ?? 0) : 0
        let redundancy = datagrams != nil ? RemoteAudioPolicy.redundancy(lossRate: lossRate) : 0
        let packetNanos = UInt64(Double(currentFramesPerPacket) / RemoteAudioPolicy.sampleRate * 1e9)
        let holdPackets = Int(RemoteAudioPolicy.silenceHoldNanos / max(1, packetNanos))
        for packet in packets {
            let sequence = nextSequence
            nextSequence &+= 1
            silentRun = packet.isSilent ? silentRun + 1 : 0
            if silentRun > holdPackets {
                // 已经静了一阵：不发声音，只每秒报一次「到这里都是静音」。冗余只留最后这一包：
                // 有声了把它带上，手机的解码器先接上状态。
                history = [packet.data]
                suppressing = true
                stats.record { $0.silent += 1 }
                if packet.captureNanos &- lastSilenceMarker >= RemoteAudioPolicy.silenceHeartbeatNanos {
                    lastSilenceMarker = packet.captureNanos
                    transmit(RemoteDesktopAudioFrame(flags: .silence, stream: currentStream, sequence: sequence,
                                                     captureNanos: packet.captureNanos, data: Data()))
                    stats.record { $0.markers += 1 }
                }
                continue
            }
            // 刚从停发里恢复：至少带上停发前最后一包（history 里只剩它）。
            let count = suppressing ? max(1, redundancy) : redundancy
            suppressing = false
            let frame = RemoteDesktopAudioFrame(stream: currentStream, sequence: sequence, captureNanos: packet.captureNanos,
                                                data: packet.data, redundant: Array(history.reversed().prefix(count)))
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
        guard let datagrams else {
            link.sendOnQueue(RemoteMessage(.desktopAudioFrame, channel: channel, payload: frame.encoded()))
            return
        }
        // 数据报放不下：先少带冗余，还放不下（无损遇到很「满」的声音）这一包走可靠通道。
        var fitted = frame
        var payload = fitted.encoded()
        while payload.count > RemoteAudioPolicy.datagramPayloadLimit, !fitted.redundant.isEmpty {
            fitted = RemoteDesktopAudioFrame(flags: frame.flags, stream: frame.stream, sequence: frame.sequence,
                                             captureNanos: frame.captureNanos, data: frame.data,
                                             redundant: Array(fitted.redundant.dropLast()))
            payload = fitted.encoded()
        }
        if payload.count <= RemoteAudioPolicy.datagramPayloadLimit {
            datagrams.sendAudio(payload, channel: channel)
        } else {
            stats.record { $0.reliable += 1 }
            link.sendOnQueue(RemoteMessage(.desktopAudioFrame, channel: channel, payload: payload))
        }
    }
}
