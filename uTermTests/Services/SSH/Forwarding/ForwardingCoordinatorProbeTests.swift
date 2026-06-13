import XCTest
import SwiftData
@testable import uTerm

/// `ForwardingCoordinator.probeConnectionHealth`（看门狗入口）：并发探测所有
/// 缓存会话 —— 判死的驱逐（使「重试」重建连接），存活 / 未连接的保留。
/// 会话经测试 seam 注入，绕过认证解析与网络。
@MainActor
final class ForwardingCoordinatorProbeTests: XCTestCase {

    private func makeSession() throws -> ForwardingSession {
        let profile = ServerProfile()
        profile.host = "192.0.2.1"   // TEST-NET-1：本套测试绝不真正连接
        profile.username = "probe"
        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        return ForwardingSession(
            profile: SSHConnection.ProfileSnapshot(profile),
            auth: .password(username: "probe", password: "secret"),
            jumpHostAuth: nil,
            hostKeyVerifier: verifier,
            hostKeyApprover: { _ in true },
            onStatus: { _, _ in })
    }

    /// 未连接的会话（探测视作存活）保留；已关闭的会话（判死）被驱逐 ——
    /// 驱逐后「重试」走 `obtainSession` 重建会话与连接屏障，真正重连。
    func testProbeKeepsUnconnectedSessionAndEvictsClosedOne() async throws {
        let coordinator = ForwardingCoordinator()
        let healthyID = UUID()
        let deadID = UUID()
        let healthy = try makeSession()
        let dead = try makeSession()
        await dead.close()

        coordinator.injectSessionForTesting(healthy, serverID: healthyID)
        coordinator.injectSessionForTesting(dead, serverID: deadID)

        await coordinator.probeConnectionHealth()

        XCTAssertTrue(coordinator.hasSessionForTesting(serverID: healthyID),
                      "存活（未连接）会话不应被驱逐")
        XCTAssertFalse(coordinator.hasSessionForTesting(serverID: deadID),
                       "判死会话应被驱逐，使重试重建连接")
    }

    /// 没有任何会话时的扫描是无害 no-op（看门狗对所有注册对象无差别扫描）。
    func testProbeWithNoSessionsIsNoOp() async {
        let coordinator = ForwardingCoordinator()
        await coordinator.probeConnectionHealth()
    }
}
