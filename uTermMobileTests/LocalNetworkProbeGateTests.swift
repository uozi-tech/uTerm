import XCTest
@testable import uTermMobile

/// 首启（还没用过本地网络）时，主机卡片的在线探测不能碰局域网地址：那会弹「本地网络」授权（7df5a09a 的初衷）。
@MainActor
final class LocalNetworkProbeGateTests: XCTestCase {

    func test_background_probe_skips_lan_hosts_until_local_network_was_used() throws {
        let suite = "LocalNetworkProbeGateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(LocalNetworkUse.allowsBackgroundProbe(host: "192.168.1.10", defaults: defaults))
        XCTAssertFalse(LocalNetworkUse.allowsBackgroundProbe(host: "nas.local", defaults: defaults))
        XCTAssertTrue(LocalNetworkUse.allowsBackgroundProbe(host: "github.com", defaults: defaults))

        defaults.set(true, forKey: DefaultsKey.lanSyncReceiverActivated)
        XCTAssertTrue(LocalNetworkUse.allowsBackgroundProbe(host: "192.168.1.10", defaults: defaults))
    }

    func test_monitor_does_not_probe_disallowed_hosts() async {
        let probed = ProbeLog()
        let monitor = HostReachabilityMonitor(probe: { await probed.add($0.host); return true },
                                              allowsProbe: { !LocalNetworkUse.mayBeLocal($0.host) })
        let lan = Task { await monitor.watch(HostEndpointKey(host: "192.168.1.10", port: 22)) }
        let wan = Task { await monitor.watch(HostEndpointKey(host: "example.com", port: 22)) }
        try? await Task.sleep(for: .milliseconds(300))
        lan.cancel()
        wan.cancel()
        let hosts = await probed.hosts
        XCTAssertEqual(hosts, ["example.com"])
    }
}

private actor ProbeLog {
    private(set) var hosts: [String] = []
    func add(_ host: String) { hosts.append(host) }
}
