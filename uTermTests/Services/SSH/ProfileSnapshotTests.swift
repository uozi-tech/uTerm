import XCTest
@testable import uTerm
@testable import USSHKit

/// `SSHConnection.ProfileSnapshot` 两个 init 的单测。
///
/// 成员级 init（`init(host:port:jumpHost:)`）是「编辑表单测试连接」的依赖 ——
/// 用户尚未保存、没有 `ServerProfile` 可摘时，用表单当前输入的标量字段直接建快照。
/// 这里固定其语义，避免日后改动悄悄破坏测试连接的取值。
final class ProfileSnapshotTests: XCTestCase {

    func testMemberwiseInitDirect() {
        let snap = SSHConnection.ProfileSnapshot(host: "host.example.com", port: 2222, jumpHost: nil)
        XCTAssertEqual(snap.host, "host.example.com")
        XCTAssertEqual(snap.port, 2222)
        XCTAssertNil(snap.jumpHost)
    }

    func testMemberwiseInitWithJumpHost() {
        let jump = SSHConnection.ProfileSnapshot.JumpHostSnapshot(host: "bastion.internal", port: 22)
        let snap = SSHConnection.ProfileSnapshot(host: "10.0.0.5", port: 22, jumpHost: jump)
        XCTAssertEqual(snap.host, "10.0.0.5")
        XCTAssertEqual(snap.jumpHost?.host, "bastion.internal")
        XCTAssertEqual(snap.jumpHost?.port, 22)
    }

    func testModelInitMirrorsProfileFields() {
        let profile = ServerProfile()
        profile.host = "api.example.com"
        profile.port = 22

        let bastion = ServerProfile()
        bastion.host = "jump.example.com"
        bastion.port = 2200
        profile.jumpHost = bastion

        let snap = SSHConnection.ProfileSnapshot(profile)
        XCTAssertEqual(snap.host, "api.example.com")
        XCTAssertEqual(snap.port, 22)
        XCTAssertEqual(snap.jumpHost?.host, "jump.example.com")
        XCTAssertEqual(snap.jumpHost?.port, 2200)
    }

    func testModelInitWithoutJumpHostYieldsNil() {
        let profile = ServerProfile()
        profile.host = "solo.example.com"
        profile.port = 22
        let snap = SSHConnection.ProfileSnapshot(profile)
        XCTAssertNil(snap.jumpHost)
    }
}
