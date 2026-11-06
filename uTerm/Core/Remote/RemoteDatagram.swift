import CryptoKit
import Foundation

// 公网直连的最底层：一条不可靠的数据报通道，每个包单独加密。

/// 一条能收发 UDP 数据报的路径：打洞（`RemoteICEDatagramPath`），或测试里的差网络。
///
/// 回调在任意线程，接收方自己切队列。
nonisolated protocol RemoteDatagramPath: AnyObject, Sendable {
    func start(onDatagram: @escaping @Sendable (Data) -> Void, onFailure: @escaping @Sendable (Error?) -> Void)
    func send(_ datagram: Data)
    func close()
}

/// 数据报的种类。写在明文包头里，也进 AEAD 的附加数据，改了就解不开。
nonisolated enum RemoteDatagramKind: UInt8, Sendable {
    /// KCP 的包：控制消息、终端字节。内容本身已是 `RemoteLink` 的密文，这一层防的是伪造 ACK 和重放。
    case reliable = 1
    /// 接收报告（见 `RemoteLinkEstimator`）。
    case report = 2
    /// 关闭通知。
    case close = 3
    /// 视频分片。
    case media = 4
    /// 视频重传请求。
    case mediaNack = 5
    /// 打洞后确认路径双向可用（见 `RemoteDirectAttempt`）。用单独的密钥，传输层解不开也用不着解。
    case pathCheck = 6

    /// 视频用会话密钥派生的密钥，其余用信令派生的密钥。信令密钥只由两端长期密钥和随机数决定，
    /// 长期密钥日后泄露就能解开录下来的流量；会话密钥有临时密钥参与，所以画面不能用前者加密。
    var usesMediaKey: Bool { self == .media || self == .mediaNack }
}

/// 一个方向一把密钥。
nonisolated struct RemoteDatagramKeys: Sendable {
    let send: SymmetricKey
    let receive: SymmetricKey

    /// 从 `RemoteLink` 的会话密钥派生视频密钥。
    static func media(sessionSend: SymmetricKey, sessionReceive: SymmetricKey) -> RemoteDatagramKeys {
        func derive(_ key: SymmetricKey) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data("uterm-media-v1".utf8),
                                   info: Data("video".utf8), outputByteCount: 32)
        }
        return RemoteDatagramKeys(send: derive(sessionSend), receive: derive(sessionReceive))
    }
}

/// 防重放：记住最近 `size` 个序号收过没有。序号更旧的一律不要。
nonisolated struct RemoteReplayWindow {
    static let size: UInt64 = 4096

    private var highest: UInt64 = 0
    private var bits = [UInt64](repeating: 0, count: Int(RemoteReplayWindow.size / 64))

    /// 只在解密成功之后调用，否则伪造的序号会把窗口顶走。
    mutating func accept(_ sequence: UInt64) -> Bool {
        guard sequence > 0 else { return false }
        if sequence > highest {
            let shift = sequence - highest
            if shift >= Self.size {
                for index in bits.indices { bits[index] = 0 }
            } else {
                var cursor = highest &+ 1
                while cursor <= sequence {
                    clear(cursor)
                    cursor &+= 1
                }
            }
            highest = sequence
            set(sequence)
            return true
        }
        guard highest - sequence < Self.size, !isSet(sequence) else { return false }
        set(sequence)
        return true
    }

    private func slot(_ sequence: UInt64) -> (word: Int, mask: UInt64) {
        let position = sequence % Self.size
        return (Int(position / 64), UInt64(1) << (position % 64))
    }

    private mutating func set(_ sequence: UInt64) {
        let (word, mask) = slot(sequence)
        bits[word] |= mask
    }

    private mutating func clear(_ sequence: UInt64) {
        let (word, mask) = slot(sequence)
        bits[word] &= ~mask
    }

    private func isSet(_ sequence: UInt64) -> Bool {
        let (word, mask) = slot(sequence)
        return bits[word] & mask != 0
    }
}

/// 数据报的加解密：`[u8 种类][u64 序号（大端）][密文][16 字节 tag]`。
///
/// 序号一个方向一个计数器，所有种类共用，接收报告靠它算丢包。nonce = 4 字节 0 + 序号；两种密钥共用一个
/// 计数器也不会重复 nonce。
nonisolated struct RemoteDatagramCipher {
    static let overhead = 1 + 8 + 16

    private let control: RemoteDatagramKeys
    private var media: RemoteDatagramKeys?
    private var replay = RemoteReplayWindow()
    private(set) var lastSequence: UInt64 = 0

    init(control: RemoteDatagramKeys) {
        self.control = control
    }

    mutating func installMedia(_ keys: RemoteDatagramKeys) {
        media = keys
    }

    /// 视频密钥还没装好时发不了视频，返回 nil。
    mutating func seal(_ kind: RemoteDatagramKind, _ payload: Data) -> Data? {
        guard let key = kind.usesMediaKey ? media?.send : control.send else { return nil }
        lastSequence &+= 1
        let sequence = lastSequence
        var header = Data(capacity: 9)
        header.append(kind.rawValue)
        Self.append(sequence, to: &header)
        guard let nonce = Self.nonce(sequence),
              let box = try? ChaChaPoly.seal(payload, using: key, nonce: nonce, authenticating: header) else { return nil }
        var datagram = Data(capacity: Self.overhead + payload.count)
        datagram.append(header)
        datagram.append(box.ciphertext)
        datagram.append(box.tag)
        return datagram
    }

    /// 解不开、重放、密钥没装好都返回 nil，不报错：UDP 上谁都能往这个端口发东西。
    mutating func open(_ datagram: Data) -> (kind: RemoteDatagramKind, sequence: UInt64, payload: Data)? {
        guard datagram.count >= Self.overhead else { return nil }
        let start = datagram.startIndex
        guard let kind = RemoteDatagramKind(rawValue: datagram[start]),
              let key = kind.usesMediaKey ? media?.receive : control.receive else { return nil }
        var sequence: UInt64 = 0
        for byte in datagram[(start + 1)..<(start + 9)] { sequence = sequence << 8 | UInt64(byte) }
        let split = datagram.endIndex - 16
        guard let nonce = Self.nonce(sequence),
              let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: datagram[(start + 9)..<split],
                                                  tag: datagram[split...]),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: datagram[start..<(start + 9)]),
              replay.accept(sequence) else { return nil }
        return (kind, sequence, plain)
    }

    private static func nonce(_ sequence: UInt64) -> ChaChaPoly.Nonce? {
        var bytes = Data(repeating: 0, count: 4)
        append(sequence, to: &bytes)
        return try? ChaChaPoly.Nonce(data: bytes)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}

/// 发送节奏：令牌桶加两级队列。控制消息和终端总在视频前面，手机和基站的缓冲才不会被一帧视频撑满。
nonisolated struct RemoteDatagramPacer {
    enum Priority {
        /// KCP、报告、视频重传请求。
        case control
        /// 视频分片。
        case media
    }

    /// 字节 / 秒。
    var rate: Double
    private var tokens: Double
    private var lastRefill: UInt64
    private var control: [(RemoteDatagramKind, Data)] = []
    private var controlHead = 0
    private var media: [(RemoteDatagramKind, Data)] = []
    private var mediaHead = 0
    private(set) var queuedMediaBytes = 0

    init(rate: Double, now: UInt64) {
        self.rate = rate
        tokens = Self.burst(rate)
        lastRefill = now
    }

    /// 最多一次突发多少：够发 5 ms，至少两个包。
    private static func burst(_ rate: Double) -> Double {
        max(2400, rate * 0.005)
    }

    var isEmpty: Bool { controlHead == control.count && mediaHead == media.count }

    mutating func enqueue(_ kind: RemoteDatagramKind, _ payload: Data, priority: Priority) {
        switch priority {
        case .control: control.append((kind, payload))
        case .media:
            media.append((kind, payload))
            queuedMediaBytes += payload.count
        }
    }

    /// 现在能发的下一个；队列空或令牌不够时返回 nil。
    mutating func next(now: UInt64) -> (RemoteDatagramKind, Data)? {
        refill(now: now)
        guard tokens > 0 else { return nil }
        if controlHead < control.count {
            let item = control[controlHead]
            controlHead += 1
            if controlHead == control.count {
                control.removeAll(keepingCapacity: true)
                controlHead = 0
            }
            tokens -= Double(item.1.count + RemoteDatagramCipher.overhead)
            return item
        }
        if mediaHead < media.count {
            let item = media[mediaHead]
            mediaHead += 1
            queuedMediaBytes -= item.1.count
            if mediaHead == media.count {
                media.removeAll(keepingCapacity: true)
                mediaHead = 0
            } else if mediaHead > 4096 {
                media.removeFirst(mediaHead)
                mediaHead = 0
            }
            tokens -= Double(item.1.count + RemoteDatagramCipher.overhead)
            return item
        }
        return nil
    }

    /// 还要等多久才有令牌（纳秒）。队列空时 nil。
    func waitNanos(now: UInt64) -> UInt64? {
        guard !isEmpty else { return nil }
        let elapsed = Double(now &- lastRefill) / 1e9
        let available = min(Self.burst(rate), tokens + elapsed * rate)
        if available > 0 { return 0 }
        return UInt64((1 - available) / max(1, rate) * 1e9)
    }

    private mutating func refill(now: UInt64) {
        let elapsed = Double(now &- lastRefill) / 1e9
        lastRefill = now
        tokens = min(Self.burst(rate), tokens + elapsed * rate)
    }
}
