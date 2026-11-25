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

    /// 握手还没完窗口就关了（teardown 取消建连）：被取消的建连不是失败，规则不能在拆完之后又被写成 `.error`。
    func testTeardownDuringConnectLeavesNoErrorBehind() async throws {
        let coordinator = ForwardingCoordinator()
        coordinator.injectSessionForTesting(try makeSession(), serverID: server.id)
        coordinator.injectConnectTaskForTesting(Task { try await Task.sleep(for: .seconds(30)) }, serverID: server.id)
        let pg = rule("pg")

        coordinator.start(pg, on: server, relay: HostKeyChallengeRelay(), modelContainer: container)
        XCTAssertEqual(coordinator.status(pg.id), .starting)
        coordinator.teardown(serverID: server.id)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(coordinator.status(pg.id), .inactive, "拆掉之后又被写成了错误")
    }

    /// 等建连期间会话被换掉了（拆了又开）：旧的那次建连失败不能把新会话下的规则写成错误。
    func testFailureOfAReplacedSessionDoesNotTouchTheNewOne() async throws {
        let coordinator = ForwardingCoordinator()
        coordinator.injectSessionForTesting(try makeSession(), serverID: server.id)
        let failing = Task<Void, Error> {
            try await Task.sleep(for: .milliseconds(200))
            throw SSHConnection.SSHConnectionError.connectFailed("old")
        }
        coordinator.injectConnectTaskForTesting(failing, serverID: server.id)
        let pg = rule("pg")
        coordinator.start(pg, on: server, relay: HostKeyChallengeRelay(), modelContainer: container)

        // 换上一个新会话（还在握手）。
        coordinator.injectSessionForTesting(try makeSession(), serverID: server.id)
        coordinator.injectConnectTaskForTesting(Task { try await Task.sleep(for: .seconds(30)) }, serverID: server.id)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(coordinator.status(pg.id), .starting, "旧会话的失败写到了新会话的规则上")
        XCTAssertTrue(coordinator.hasSessionForTesting(serverID: server.id), "旧会话的失败把新会话驱逐了")
        coordinator.teardown(serverID: server.id)
    }

    /// 命令行 `forward-start` 的一次性 relay 请求结束后就没人轮询：放掉之后，后来的问题（看门狗重连、复用会话）
    /// 不能投进去挂住，没有界面的 relay 就当场拒绝。
    func testReleasedCLIRelayNoLongerReceivesAsks() async throws {
        let coordinator = ForwardingCoordinator()
        coordinator.injectSessionForTesting(try makeSession(), serverID: server.id)
        let cli = HostKeyChallengeRelay(interactive: false)
        coordinator.start(rule("pg"), on: server, relay: cli, modelContainer: container)
        coordinator.releaseRelay(cli, serverID: server.id)

        let decision = Task { await coordinator.approveHostKey(serverID: self.server.id, challenge: self.challenge) }
        let approved = await decision.value
        XCTAssertFalse(approved)
        XCTAssertNil(cli.pendingChallenge, "问题投进了没人看的命令行 relay")
        coordinator.teardown(serverID: server.id)
    }

    /// 界面开过这台主机的转发窗口：命令行 relay 放掉后，问题回到界面那个 relay（有人能回答）。
    func testReleasingCLIRelayFallsBackToTheInteractiveOne() async throws {
        let coordinator = ForwardingCoordinator()
        coordinator.injectSessionForTesting(try makeSession(), serverID: server.id)
        let ui = HostKeyChallengeRelay()
        let cli = HostKeyChallengeRelay(interactive: false)
        coordinator.start(rule("pg"), on: server, relay: ui, modelContainer: container)
        coordinator.start(rule("pg2"), on: server, relay: cli, modelContainer: container)
        coordinator.releaseRelay(cli, serverID: server.id)

        let decision = Task { await coordinator.approveHostKey(serverID: self.server.id, challenge: self.challenge) }
        try await waitUntil { ui.pendingChallenge != nil }
        XCTAssertNil(cli.pendingChallenge)
        ui.resolve(true)
        let approved = await decision.value
        XCTAssertTrue(approved)
        coordinator.teardown(serverID: server.id)
    }

    /// 放掉的不是当前那个（界面后来又开了一次）：别把界面的 relay 换掉。
    func testReleasingAStaleRelayKeepsTheCurrentOne() async throws {
        let coordinator = ForwardingCoordinator()
        coordinator.injectSessionForTesting(try makeSession(), serverID: server.id)
        let cli = HostKeyChallengeRelay(interactive: false)
        let ui = HostKeyChallengeRelay()
        coordinator.start(rule("pg"), on: server, relay: cli, modelContainer: container)
        coordinator.start(rule("pg2"), on: server, relay: ui, modelContainer: container)
        coordinator.releaseRelay(cli, serverID: server.id)

        let decision = Task { await coordinator.approveHostKey(serverID: self.server.id, challenge: self.challenge) }
        try await waitUntil { ui.pendingChallenge != nil }
        ui.resolve(false)
        _ = await decision.value
        coordinator.teardown(serverID: server.id)
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
