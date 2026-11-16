import XCTest
@testable import uTermMobile

/// 主机卡片按 `HostCardInfo` 判等：没变的卡片不重算，变了的必须重算。
@MainActor
final class HostCardInfoTests: XCTestCase {
    private func host(name: String = "web-01", group: String? = "生产") -> ServerProfile {
        let host = ServerProfile()
        host.name = name
        host.host = "10.0.0.8"
        host.port = 2222
        host.username = "deploy"
        host.group = group
        host.authMethod = .privateKey
        return host
    }

    func testCopiesWhatTheCardShows() {
        let info = HostCardInfo(host())
        XCTAssertEqual(info.name, "web-01")
        XCTAssertEqual(info.endpoint, "deploy@10.0.0.8:2222")
        XCTAssertEqual(info.monogram, "W")
        XCTAssertEqual(info.groupLabel, "生产")
        XCTAssertEqual(info.authLabel, "SSH 密钥")
        XCTAssertEqual(info.reachabilityKey, HostEndpointKey(host: "10.0.0.8", port: 2222))
    }

    /// 主机页被 iCloud 合并叫醒、值没变：两份相等，卡片不重算。
    func testUnchangedHostGivesEqualInfo() {
        let profile = host()
        XCTAssertEqual(HostCardInfo(profile), HostCardInfo(profile))
    }

    /// 卡片上看得到的每一项变了，都不能被判成相等（否则卡片停在旧值）。
    func testEveryVisibleChangeBreaksEquality() {
        let profile = host()
        let before = HostCardInfo(profile)
        let edits: [(String, (ServerProfile) -> Void)] = [
            ("名字", { $0.name = "web-02" }),
            ("地址", { $0.host = "10.0.0.9" }),
            ("端口", { $0.port = 22 }),
            ("用户", { $0.username = "root" }),
            ("分组", { $0.group = nil }),
            ("认证", { $0.authMethod = .password }),
            ("置顶", { $0.isPinned = true }),
            ("仅 SFTP", { $0.sftpOnly = true }),
            ("上次连接", { $0.lastConnectedAt = Date() }),
            ("跳板机", { $0.jumpHost = ServerProfile() }),
        ]
        for (label, edit) in edits {
            let edited = host()
            edit(edited)
            XCTAssertNotEqual(HostCardInfo(edited), before, label)
        }
    }

    /// 走跳板机的主机不探在线状态，也就不画角标。
    func testJumpHostedHostHasNoReachabilityKey() {
        let profile = host()
        profile.jumpHost = ServerProfile()
        XCTAssertNil(HostCardInfo(profile).reachabilityKey)
    }
}
