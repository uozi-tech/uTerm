import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// 默认中继配置在 iCloud 钥匙串里，读一次是主线程上的 `SecItemCopyMatching`。打开 Mac 面板时
/// sheet 内容每次求值都调 `client(for:)`，改前每次都读两次钥匙串，和弹出动画撞在一起掉帧（iOS 实机报卡）。
@MainActor
final class RemoteMacDirectoryRelayCacheTests: XCTestCase {
    /// 数 `loadAll` 被调了几次（= 读了几次钥匙串）。
    nonisolated private final class CountingStorage: RemoteSyncedStorage, @unchecked Sendable {
        let inner = RemoteMemorySyncedStorage()
        private let lock = NSLock()
        private var count = 0
        var loads: Int { lock.withLock { count } }
        func reset() { lock.withLock { count = 0 } }
        func loadAll() -> [Data] {
            lock.withLock { count += 1 }
            return inner.loadAll()
        }
        func save(_ data: Data, account: String) throws { try inner.save(data, account: account) }
        func delete(account: String) throws { try inner.delete(account: account) }
        func deleteAll() throws { try inner.deleteAll() }
    }

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "RemoteMacDirectoryRelayCacheTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func relay(_ name: String) -> RemoteRelayConfig {
        RemoteRelayConfig(name: name, host: "relay.example.com", port: 47310, relayID: "6f1c00aa",
                          key: P256.Signing.PrivateKey().rawRepresentation.base64EncodedString())
    }

    func testOpeningMacPanelRepeatedlyDoesNotRereadKeychain() throws {
        let storage = CountingStorage()
        let store = RemoteRelayConfigStore(storage: storage)
        try store.save(relay("家里"))
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try identity.trust(RemotePeer(id: UUID(), name: "Mac", publicKey: Data(repeating: 3, count: 32),
                                      pairedAt: .now, platform: RemoteDevicePlatform.mac.rawValue))
        let directory = RemoteMacDirectory(identity: identity, relayStore: store, defaults: defaults,
                                           accountDevices: nil)
        let mac = try XCTUnwrap(directory.macs.first)

        storage.reset()
        // 面板 sheet 的内容闭包随父视图求值反复调用；第一次建客户端，之后拿已有的。
        let client = directory.client(for: mac)
        for _ in 0..<10 { XCTAssertTrue(directory.client(for: mac) === client) }
        directory.refreshPaired()   // 面板收起时
        XCTAssertLessThanOrEqual(storage.loads, 1, "打开 / 收起 Mac 面板不该一遍遍读钥匙串")

        // 本机导入新的默认中继：立刻生效，不用再读。
        let replaced = relay("公司")
        XCTAssertTrue(directory.importRelayConfig(replaced))
        storage.reset()
        XCTAssertEqual(directory.relayServerName(), "公司")
        XCTAssertEqual(storage.loads, 0)

        // 别的设备经 iCloud 钥匙串改了：回到前台时重读。
        try store.save(relay("别处"))
        directory.returnedToForeground()
        XCTAssertEqual(directory.relayServerName(), "别处")
    }
}
