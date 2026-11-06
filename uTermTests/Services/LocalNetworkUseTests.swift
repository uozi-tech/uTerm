import XCTest
@testable import uTerm

/// iOS 首启不该因为在线探测弹「本地网络」授权：哪些地址算「可能在局域网里」。
final class LocalNetworkUseTests: XCTestCase {

    func test_private_and_link_local_literals_may_be_local() {
        for host in ["10.0.0.1", "172.16.6.43", "172.31.255.1", "192.168.1.10", "169.254.3.4", "127.0.0.1",
                     "100.64.0.1", "fe80::1", "[fe80::1%en0]", "fd12:3456::1", "::1"] {
            XCTAssertTrue(LocalNetworkUse.mayBeLocal(host), host)
        }
    }

    func test_local_suffixes_and_single_label_names_may_be_local() {
        for host in ["nas.local", "router.lan", "box.home", "db.internal", "srv.home.arpa", "nas", "  NAS.LOCAL. ", ""] {
            XCTAssertTrue(LocalNetworkUse.mayBeLocal(host), host)
        }
    }

    func test_public_addresses_and_names_are_not_local() {
        for host in ["8.8.8.8", "172.32.0.1", "100.128.0.1", "2001:db8::1", "github.com", "sh-3.prod.example.net"] {
            XCTAssertFalse(LocalNetworkUse.mayBeLocal(host), host)
        }
    }

    func test_any_local_network_activity_counts_as_used() throws {
        let suite = "LocalNetworkUseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(LocalNetworkUse.hasBeenUsed(defaults: defaults))
        defaults.set(true, forKey: DefaultsKey.remoteBrowseActivated)
        XCTAssertTrue(LocalNetworkUse.hasBeenUsed(defaults: defaults))
    }
}
