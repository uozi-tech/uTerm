import CryptoKit
import XCTest
@testable import uTermMobile

/// Mac 长时间离线时，没人看的远控标签退避可达一分钟；目录看到 Mac 回来（中继报它上线）要立刻叫醒重连。
@MainActor
final class RemoteReconnectWakeTests: XCTestCase {
    private final class HostsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Set<UUID> = []
        var hosts: Set<UUID> {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private let relay = RemoteRelayConfig(name: "测试中继", host: "relay.invalid", port: 47310, relayID: "test",
                                          key: Data(count: 32).base64EncodedString())

    func testMacComingOnlineOnRelayWakesItsBackingOffTabs() async throws {
        let suite = "RemoteReconnectWakeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        // 直接写「已启用」，不调 activate()：那会开始 Bonjour 浏览。
        defaults.set(true, forKey: DefaultsKey.remoteBrowseActivated)
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let macID = UUID()
        try identity.trust(RemotePeer(id: macID, name: "MacBook Pro",
                                      publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                      pairedAt: .now))
        let box = HostsBox()
        let directory = RemoteMacDirectory(identity: identity, defaults: defaults,
                                           relayPollInterval: .milliseconds(50)) { _ in box.hosts }
        XCTAssertTrue(directory.importRelayConfig(relay))
        let mac = try XCTUnwrap(directory.macs.first { $0.deviceID == macID })
        XCTAssertFalse(mac.isOnline)
        let client = directory.client(for: mac)
        // 让建网络监视器时的第一次路径回调（它也会叫醒）先过去，免得混进下面的判断。
        try await Task.sleep(for: .milliseconds(300))

        let quiet = await client.retryGate.wait(.milliseconds(300))
        XCTAssertFalse(quiet, "Mac 还不在线时没有理由叫醒")

        box.hosts = [macID]
        let waiting = Task { await client.retryGate.wait(.seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        // 主机页出现：马上问一次中继，看到 Mac 上线。
        let watcher = Task { await directory.keepLiveStatusFresh() }
        defer { watcher.cancel() }
        let woke = await waiting.value
        XCTAssertTrue(woke, "中继报 Mac 上线：正在退避的标签不等退避走完就重试")
        XCTAssertTrue(directory.macs.first { $0.deviceID == macID }?.isOnRelay == true)
    }
}
