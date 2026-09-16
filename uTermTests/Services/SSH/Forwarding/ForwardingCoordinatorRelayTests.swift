import XCTest
import SwiftData
@testable import uTerm

/// `ForwardingCoordinator` 的 host-key relay 归属：会话按主机缓存，第二次 `start`
/// 会直接复用已有会话 —— 传进来的 relay 从此不能被丢掉。
///
/// 回归的 bug：会话在创建时捕获了当时那个 relay 的 approver，于是挑战永远弹到
/// **最初**那个 sheet 上。CLI 的 `forward-start` 每次都新造一个 relay，
/// 它拿不到挑战就没有指纹可回，`trust --fingerprint` 那条路整条断掉。
@MainActor
final class ForwardingCoordinatorRelayTests: XCTestCase {

    private var container: ModelContainer!
    private var server: ServerProfile!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self, ForwardingRule.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        server = ServerProfile()
        server.name = "prod-db"
        server.host = "192.0.2.30"      // TEST-NET-1：本套用例绝不真正连接
        server.username = "deploy"
        container.mainContext.insert(server)
        try container.mainContext.save()
    }

    private func makeSession() throws -> ForwardingSession {
        let verifier = HostKeyVerifier(modelContainer: container)
        return ForwardingSession(
            profile: SSHConnection.ProfileSnapshot(server),
            auth: .password(username: "deploy", password: "secret"),
            jumpHostAuth: nil,
            hostKeyVerifier: verifier,
            hostKeyApprover: { _ in false },
            onStatus: { _, _ in })
    }

    private func rule(_ name: String) -> ForwardingRuleSnapshot {
        ForwardingRuleSnapshot(
            id: UUID(), serverID: server.id, name: name, kind: .local,
            listenHost: "127.0.0.1", listenPort: 15_432,
            destHost: "10.0.0.1", destPort: 5432, autostart: false)
    }

    private var challenge: HostKeyChallenge {
        HostKeyChallenge(host: "192.0.2.30", port: 22, kind: .unknown,
                         newFingerprint: "SHA256:xyz", oldFingerprint: nil)
    }

    /// 会话已存在（`obtainSession` 走「复用」分支）时再 `start`，挑战必须投递到
    /// **新**的 relay 上，而不是会话创建时那个。
    func testApproverFollowsLatestRelayWhenSessionIsReused() async throws {
        let coordinator = ForwardingCoordinator()
        coordinator.injectSessionForTesting(try makeSession(), serverID: server.id)

        let first = HostKeyChallengeRelay()
        let latest = HostKeyChallengeRelay()
        coordinator.start(rule("pg"), on: server, relay: first, modelContainer: container)
        coordinator.start(rule("pg2"), on: server, relay: latest, modelContainer: container)

        let decision = Task { await coordinator.approveHostKey(serverID: self.server.id,
                                                               challenge: self.challenge) }
        try await waitUntil { latest.pendingChallenge != nil || first.pendingChallenge != nil }

        XCTAssertNotNil(latest.pendingChallenge, "挑战应投递到最新的 relay")
        XCTAssertNil(first.pendingChallenge, "不该弹到会话创建时那个 relay")

        latest.resolve(false)
        let approved = await decision.value
        XCTAssertFalse(approved, "非交互路径的裁决原样透传")
    }

    /// `teardown` 之后没有「当前 relay」，审批一律拒绝 —— 绝不静默 TOFU。
    func testApproverRefusesAfterTeardown() async throws {
        let coordinator = ForwardingCoordinator()
        let relay = HostKeyChallengeRelay()
        coordinator.start(rule("pg"), on: server, relay: relay, modelContainer: container)
        coordinator.teardown(serverID: server.id)

        let approved = await coordinator.approveHostKey(serverID: server.id,
                                                        challenge: challenge)
        XCTAssertFalse(approved)
        XCTAssertNil(relay.pendingChallenge)
    }

    /// 从没 `start` 过的主机同理。
    func testApproverRefusesUnknownServer() async {
        let coordinator = ForwardingCoordinator()
        let approved = await coordinator.approveHostKey(serverID: UUID(),
                                                        challenge: challenge)
        XCTAssertFalse(approved)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待超时")
    }
}
