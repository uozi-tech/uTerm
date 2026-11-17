import CryptoKit
import Foundation
import XCTest
@testable import uTerm

// 快通道用例共用的夹具：可拨的钟、内存线路、会「慢半拍」的钥匙串、造记录。

/// 可拨的钟（叠加层在别的线程上读它）。
final class FastSyncClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = date
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    var closure: @Sendable () -> Date { { [self] in now } }
}

/// 观察者收到的变化（回调在别的线程上）。
final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RemoteGroupOverlayStorage.Change] = []
    func append(_ change: RemoteGroupOverlayStorage.Change) { lock.withLock { items.append(change) } }
    var changes: [RemoteGroupOverlayStorage.Change] { lock.withLock { items } }
}

/// 一对内存线路：一头发的帧按序交给另一头，异步（模拟网络），断开时两头都收到。记下每一头发了什么。
final class MemoryGroupLink: RemoteGroupPeerLink, @unchecked Sendable {
    let peer: RemoteGroupDevice
    let kind: RemoteGroupLinkKind
    weak var other: MemoryGroupLink?
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var onFrame: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var pending: [Data] = []
    private var closed = false
    private(set) var sentFrames: [Data] = []

    private init(peer: RemoteGroupDevice, kind: RemoteGroupLinkKind, queue: DispatchQueue) {
        self.peer = peer
        self.kind = kind
        self.queue = queue
    }

    /// 返回（A 手里的那头 —— 对端是 B，B 手里的那头 —— 对端是 A）。
    static func pair(_ a: RemoteGroupDevice, _ b: RemoteGroupDevice,
                     kind: RemoteGroupLinkKind = .localNetwork) -> (atA: MemoryGroupLink, atB: MemoryGroupLink) {
        let queue = DispatchQueue(label: "test.memory-link.\(UUID().uuidString)")
        let atA = MemoryGroupLink(peer: b, kind: kind, queue: queue)
        let atB = MemoryGroupLink(peer: a, kind: kind, queue: queue)
        atA.other = atB
        atB.other = atA
        return (atA, atB)
    }

    var sentMessages: [RemoteGroupSyncMessage] {
        lock.withLock { sentFrames }.compactMap(RemoteGroupSyncMessage.decode)
    }

    func activate(onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        let (frames, isClosed): ([Data], Bool) = lock.withLock {
            self.onFrame = onFrame
            self.onClose = onClose
            defer { pending = [] }
            return (pending, closed)
        }
        if isClosed { return onClose() }
        for frame in frames { onFrame(frame) }
    }

    func send(_ frame: Data) {
        let isClosed = lock.withLock {
            if !closed { sentFrames.append(frame) }
            return closed
        }
        guard !isClosed, let other else { return }
        queue.async { other.deliver(frame) }
    }

    private func deliver(_ frame: Data) {
        let handler: (@Sendable (Data) -> Void)? = lock.withLock {
            guard !closed else { return nil }
            if onFrame == nil { pending.append(frame) }
            return onFrame
        }
        handler?(frame)
    }

    func close() {
        shut()
        other?.shut()
    }

    private func shut() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            defer { onClose = nil; onFrame = nil }
            return onClose
        }
        handler?()
    }
}

/// 「钥匙串」：每台设备一份，彼此不同步，除非测试调 `deliver` 把一台设备写过的操作（按顺序）补到另一台上。
final class LaggingKeychain: RemoteSyncedStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    /// 本机写过的操作（账号, 内容；nil = 删除），按顺序。
    private(set) var log: [(account: String, data: Data?)] = []

    func loadAll() -> [Data] {
        lock.withLock { items.keys.sorted().compactMap { items[$0] } }
    }

    func save(_ data: Data, account: String) throws {
        lock.withLock {
            items[account] = data
            log.append((account, data))
        }
    }

    func delete(account: String) throws {
        lock.withLock {
            items[account] = nil
            log.append((account, nil))
        }
    }

    func deleteAll() throws {
        lock.withLock { items.removeAll() }
    }

    var operationCount: Int { lock.withLock { log.count } }

    /// 把 `source` 写过的第 `range` 条操作原样落到本机（iCloud 钥匙串同步过来了）。不记进本机的 `log`。
    func deliver(from source: LaggingKeychain, _ range: Range<Int>) {
        let ops = source.lock.withLock { Array(source.log[range]) }
        lock.withLock {
            for op in ops { items[op.account] = op.data }
        }
    }

    /// 直接放一条（预先放好的 `device` 记录、冒充者写的）。
    func put(_ record: RemoteGroupRecord, account: String? = nil) throws {
        put(try record.encoded(), account: account ?? record.account)
    }

    /// 原样放这几个字节（钥匙串同步过来的是写入那一份的原字节；JSON 每次编码的键序不一定相同）。
    func put(_ data: Data, account: String) {
        lock.withLock { items[account] = data }
    }
}

enum FastSyncFixtures {
    static func device(_ name: String, id: UUID = UUID(), identity: Curve25519.KeyAgreement.PrivateKey = .init(),
                       updatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> RemoteGroupDevice {
        RemoteGroupDevice(id: id, name: name, model: nil, platform: RemoteDevicePlatform.mobile.rawValue,
                          publicKey: identity.publicKey.rawRepresentation,
                          signingKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, updatedAt: updatedAt)
    }

    /// 一条 `join`：只看长度不验密码学，造起来最省事；`createdAt` 决定写入时间。
    static func join(_ device: RemoteGroupDevice, at date: Date) -> RemoteGroupRecord {
        .join(RemoteGroupJoin(device: device, sid: RemoteGroupJoinCrypto.newSessionID(),
                              share: Data((0..<RemoteGroupFormat.shareLength).map { _ in UInt8.random(in: 1...255) }),
                              createdAt: date))
    }

    static func data(_ record: RemoteGroupRecord) -> Data {
        try! record.encoded()
    }
}

extension XCTestCase {
    /// 一边转主线程的 runloop 一边等条件成立（快通道的活都在后台队列上）。
    @MainActor
    func awaitFast(_ message: @autoclosure () -> String = "", timeout: TimeInterval = 5,
                   file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("等不到：\(message())", file: file, line: line)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// 等一小会儿，让在路上的帧都到（断言「不会发生」时用）。
    @MainActor
    func idleFast(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
