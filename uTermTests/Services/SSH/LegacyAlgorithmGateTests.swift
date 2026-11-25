import Foundation
import NIOCore
import NIOSSH
import SwiftData
import XCTest
import USSHTestServer
@testable import uTerm
@_spi(uTermIntegration) @testable import USSHKit

/// 自动退到旧算法之前 App 的决定（`LegacyAlgorithmGate`）：第一次连静默放行、连上才记下；信任过的主机先问；
/// 同意过的不再问；不核对主机密钥时不问；跳板机那一跳单独问；同一台同时在问的只问一次；不能问的上下文拒绝。
/// 外加错误归类（不重连）与一条对进程内测试服务端（只给 group14-sha1）的真实握手。
@MainActor
final class LegacyAlgorithmGateTests: XCTestCase {

    private var consent: LegacyAlgorithmConsent!

    override func setUp() async throws {
        try await super.setUp()
        consent = LegacyAlgorithmConsent(suiteName: "uTermTests.legacyAlgorithmConsent.\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        consent.removeAll()
        if let suite = consent.suiteName { UserDefaults().removePersistentDomain(forName: suite) }
        consent = nil
        try await super.tearDown()
    }

    /// 记下被问到的挑战，按设定回答。
    private nonisolated final class Asker: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [HostKeyChallenge] = []
        private let answer: Bool
        private let delay: Duration

        init(_ answer: Bool, delay: Duration = .zero) {
            self.answer = answer
            self.delay = delay
        }

        var challenges: [HostKeyChallenge] { lock.withLock { recorded } }

        var approver: @Sendable (HostKeyChallenge) async -> Bool {
            { [self] challenge in
                lock.withLock { recorded.append(challenge) }
                if delay > .zero { try? await Task.sleep(for: delay) }
                return answer
            }
        }
    }

    private func gate(hasRecord: Bool, verifiesHostKeys: Bool = true, interactive: Bool = true,
                      asker: Asker) -> LegacyAlgorithmGate {
        LegacyAlgorithmGate(consent: consent, verifiesHostKeys: verifiesHostKeys, interactive: interactive,
                            hasTrustRecord: { _, _ in hasRecord }, approver: asker.approver)
    }

    // MARK: - 纯判定

    func testDecisionTable() {
        typealias G = LegacyAlgorithmGate
        XCTAssertEqual(G.decide(consented: true, hasTrustRecord: true, verifiesHostKeys: true), .allow)
        XCTAssertEqual(G.decide(consented: true, hasTrustRecord: false, verifiesHostKeys: true), .allow)
        XCTAssertEqual(G.decide(consented: false, hasTrustRecord: false, verifiesHostKeys: true), .allowAndRemember,
                       "第一次连：照旧静默，之后走新主机的信任确认")
        XCTAssertEqual(G.decide(consented: false, hasTrustRecord: true, verifiesHostKeys: false), .allowAndRemember,
                       "不核对主机密钥：问加密方式没有意义")
        XCTAssertEqual(G.decide(consented: false, hasTrustRecord: true, verifiesHostKeys: true), .ask,
                       "以前连上过、没同意过：问")
    }

    // MARK: - 闸门

    /// 第一次连：不问，连上之后才记下同意；没连上（主机密钥被拒、认证失败）什么也不留。
    func testFirstContactIsSilentAndRememberedOnlyAfterSuccess() async {
        let asker = Asker(false)
        let first = gate(hasRecord: false, asker: asker)
        let approved = await first.approve(host: "old.example", port: 22, isJumpHost: false)
        XCTAssertTrue(approved)
        XCTAssertTrue(asker.challenges.isEmpty)
        XCTAssertFalse(consent.contains(host: "old.example", port: 22), "还没连上，不记")
        first.connectionSucceeded(hops: [(host: "old.example", port: 22)])
        XCTAssertTrue(consent.contains(host: "old.example", port: 22))

        let failed = gate(hasRecord: false, asker: asker)
        _ = await failed.approve(host: "other.example", port: 22, isJumpHost: false)
        XCTAssertFalse(consent.contains(host: "other.example", port: 22), "连接没成功就没调 connectionSucceeded")
    }

    /// 某一跳连上了、这次 USSHKit 没为它调过钩子（协商到的是现代算法）：清掉它的同意，之后再退回旧算法会再问。
    /// 调过钩子的那一跳（这次仍要旧算法）不动；跳板机与目标各按自己那一跳判断。
    func testModernConnectionClearsConsentPerHop() async {
        consent.insert(host: "bastion", port: 22)
        consent.insert(host: "web", port: 22)
        let gate = gate(hasRecord: true, asker: Asker(false))
        // 跳板机这次还要旧算法（同意过，照常连），目标这次用的是现代算法（钩子没为它调）。
        let approved = await gate.approve(host: "bastion", port: 22, isJumpHost: true)
        XCTAssertTrue(approved)
        gate.connectionSucceeded(hops: [(host: "bastion", port: 22), (host: "web", port: 22)])
        XCTAssertTrue(consent.contains(host: "bastion", port: 22), "这次仍用旧算法的那一跳不清")
        XCTAssertFalse(consent.contains(host: "web", port: 22), "现代算法连上的那一跳清掉")

        // 之后它又退回旧算法：再问。
        let asker = Asker(false)
        let again = await self.gate(hasRecord: true, asker: asker).approve(host: "web", port: 22, isJumpHost: false)
        XCTAssertFalse(again)
        XCTAssertEqual(asker.challenges.count, 1)
    }

    /// 连接没成功（没调 `connectionSucceeded`）就什么也不清。
    func testFailedConnectionClearsNothing() async {
        consent.insert(host: "web", port: 22)
        _ = gate(hasRecord: true, asker: Asker(false))
        XCTAssertTrue(consent.contains(host: "web", port: 22))
    }

    /// 信任过的主机：问一次，拒绝不记、返回 false；同意记下，之后不再问。
    func testTrustedHostAsksAndRemembersApproval() async {
        let refusing = Asker(false)
        let declined = await gate(hasRecord: true, asker: refusing).approve(host: "web", port: 2222, isJumpHost: false)
        XCTAssertFalse(declined)
        XCTAssertEqual(refusing.challenges.count, 1)
        let challenge = try? XCTUnwrap(refusing.challenges.first)
        XCTAssertEqual(challenge?.isWeakAlgorithms, true)
        XCTAssertEqual(challenge?.host, "web")
        XCTAssertEqual(challenge?.port, 2222)
        XCTAssertEqual(challenge?.isJumpHost, false)
        XCTAssertEqual(challenge?.newFingerprint, "")
        XCTAssertFalse(consent.contains(host: "web", port: 2222))

        let approving = Asker(true)
        let approved = await gate(hasRecord: true, asker: approving).approve(host: "web", port: 2222, isJumpHost: false)
        XCTAssertTrue(approved)
        XCTAssertTrue(consent.contains(host: "web", port: 2222), "同意当场记下，不等连上")

        let later = Asker(false)
        let again = await gate(hasRecord: true, asker: later).approve(host: "web", port: 2222, isJumpHost: false)
        XCTAssertTrue(again)
        XCTAssertTrue(later.challenges.isEmpty, "同意过就不再问")
    }

    /// 设置里关了主机密钥核对：不问。
    func testInsecureHostKeyPolicyDoesNotAsk() async {
        let asker = Asker(false)
        let gate = gate(hasRecord: true, verifiesHostKeys: false, asker: asker)
        let approved = await gate.approve(host: "lab", port: 22, isJumpHost: false)
        XCTAssertTrue(approved)
        XCTAssertTrue(asker.challenges.isEmpty)
    }

    /// 跳板机那一跳：问的是跳板机自己的地址，挑战标着是跳板机。
    func testJumpHostHopIsAskedSeparately() async {
        let asker = Asker(false)
        let approval = gate(hasRecord: true, asker: asker).approval
        let request = SSHLegacyFallbackRequest(hop: .jumpHost, host: "bastion", port: 22,
                                               trigger: .noCommonAlgorithm, failure: nil)
        let approved = await approval(request)
        XCTAssertFalse(approved)
        let challenge = asker.challenges.first
        XCTAssertEqual(challenge?.host, "bastion")
        XCTAssertEqual(challenge?.isJumpHost, true)
    }

    /// 同一台主机同时在问的几条连接只问一次（都同意）。
    func testConcurrentInteractiveAsksAreCoalesced() async {
        let asker = Asker(true, delay: .milliseconds(200))
        let host = "coalesce-\(UUID().uuidString)"
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                let gate = gate(hasRecord: true, asker: asker)
                group.addTask { await gate.approve(host: host, port: 22, isJumpHost: false) }
            }
            var all: [Bool] = []
            for await result in group { all.append(result) }
            return all
        }
        XCTAssertEqual(results, [true, true, true, true])
        XCTAssertEqual(asker.challenges.count, 1, "四条连接只问了一次")
    }

    /// 不会问人的上下文（命令行、Agent）不合并：它的「不」不能替正在弹框的标签答掉。
    func testNonInteractiveRefusalDoesNotAnswerForInteractiveAsk() async {
        let host = "mixed-\(UUID().uuidString)"
        let slowUser = Asker(true, delay: .milliseconds(300))
        let robot = Asker(false)
        let userGate = gate(hasRecord: true, asker: slowUser)
        let user = Task { await userGate.approve(host: host, port: 22, isJumpHost: false) }
        try? await Task.sleep(for: .milliseconds(50))
        let cli = await gate(hasRecord: true, interactive: false, asker: robot)
            .approve(host: host, port: 22, isJumpHost: false)
        XCTAssertFalse(cli)
        let userAnswer = await user.value
        XCTAssertTrue(userAnswer)
        XCTAssertEqual(slowUser.challenges.count, 1)
        XCTAssertEqual(robot.challenges.count, 1)
    }

    // MARK: - 同意记录

    func testConsentKeysAndRemoval() {
        consent.insert(host: "fe80::1", port: 22)
        consent.insert(host: "fe80::1", port: 22)
        consent.insert(host: "a.example", port: 2200)
        XCTAssertTrue(consent.contains(host: "fe80::1", port: 22))
        XCTAssertFalse(consent.contains(host: "fe80::1", port: 2200))
        XCTAssertEqual(UserDefaults(suiteName: consent.suiteName)?.stringArray(forKey: DefaultsKey.sshLegacyAlgorithmHosts),
                       ["[fe80::1]:22", "a.example:2200"], "IPv6 加方括号；重复插入不重复记")
        consent.remove(host: "fe80::1", port: 22)
        XCTAssertFalse(consent.contains(host: "fe80::1", port: 22))
        XCTAssertTrue(consent.contains(host: "a.example", port: 2200))
    }

    /// 在信任库里删掉一台主机，本机记着的同意一起忘掉：下次连接就是第一次。
    func testDeletingKnownHostForgetsConsent() throws {
        let container = try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let known = KnownHost()
        known.host = "gone.example"
        known.port = 22
        container.mainContext.insert(known)
        consent.insert(host: "gone.example", port: 22)
        KnownHostLibrary.delete(known, in: container.mainContext, legacyConsent: consent)
        XCTAssertFalse(consent.contains(host: "gone.example", port: 22))
    }

    // MARK: - 挑战本身

    func testWeakChallengeShape() {
        let request = SSHLegacyFallbackRequest(hop: .target, host: "h", port: 22, trigger: .remembered, failure: nil)
        let challenge = HostKeyChallenge.weakAlgorithms(request)
        XCTAssertTrue(challenge.isWeakAlgorithms)
        XCTAssertEqual(challenge.coalescingKey, "h:22 weak-algorithms")
        let hostKey = HostKeyChallenge(host: "h", port: 22, kind: .unknown, newFingerprint: "SHA256:x", oldFingerprint: nil)
        XCTAssertFalse(hostKey.isWeakAlgorithms)
        XCTAssertEqual(hostKey.coalescingKey, "h:22 SHA256:x", "主机密钥的合并键和以前一样")
    }

    // MARK: - 错误归类：不可重试、不自动重连

    func testDeclinedIsPermanentEverywhere() {
        let request = SSHLegacyFallbackRequest(hop: .target, host: "h", port: 22, trigger: .noCommonAlgorithm, failure: nil)
        let jump = SSHLegacyFallbackRequest(hop: .jumpHost, host: "b", port: 22, trigger: .noCommonAlgorithm, failure: nil)
        let kitDeclined = USSHKit.SSHConnectionError.legacyFallbackDeclined(request)
        let kitJump = USSHKit.SSHConnectionError.jumpHostFailed("x", cause: .legacyFallbackDeclined(jump))

        XCTAssertEqual(JumpHostFailureCause(.legacyFallbackDeclined(jump)), .weakAlgorithms)
        XCTAssertEqual(JumpHostFailureCause(kitJump), .weakAlgorithms)
        XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(kitDeclined))
        XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(kitJump))

        let app = SSHClientFactory.appError(kitDeclined)
        guard case .weakAlgorithmsDeclined(let refusal) = app else { return XCTFail("\(app)") }
        XCTAssertEqual(refusal, LegacyAlgorithmRefusal(host: "h", port: 22, isJumpHost: false))
        guard case .weakAlgorithmsDeclined(let jumpRefusal) = SSHClientFactory.appError(kitJump) else {
            return XCTFail("跳板机那一跳也归成 weakAlgorithmsDeclined")
        }
        XCTAssertEqual(jumpRefusal, LegacyAlgorithmRefusal(host: "b", port: 22, isJumpHost: true))

        XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(app))
        XCTAssertFalse(SSHTransportFailure.isTransportFailure(app), "服务器在应答，不是网络断了")
        XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(
            SSHConnection.SSHConnectionError.jumpHostFailed("x", cause: .weakAlgorithms)))
        XCTAssertEqual(app.errorDescription, refusal.message)
        XCTAssertTrue(refusal.message.contains("h:22"))
        XCTAssertTrue(jumpRefusal.message.contains("b:22"))
    }

    /// 线上按字符串收：新值认得出，不认识的值照旧按网络问题算。
    func testJumpHostFailureCauseWireValue() throws {
        XCTAssertEqual(JumpHostFailureCause.weakAlgorithms.rawValue, "weakAlgorithms")
        let failure = SSHBridgeFailure(kind: .jumpHost, message: "m", jumpHostCause: .weakAlgorithms,
                                       legacyDeclined: SSHBridgeLegacyRequest(host: "b", port: 22, isJumpHost: true))
        let decoded = try JSONDecoder().decode(SSHBridgeFailure.self, from: JSONEncoder().encode(failure))
        XCTAssertEqual(decoded.jumpHostCause, .weakAlgorithms)
        XCTAssertEqual(decoded.legacyDeclined, SSHBridgeLegacyRequest(host: "b", port: 22, isJumpHost: true))

        let old = try JSONDecoder().decode(SSHBridgeFailure.self,
                                           from: Data(#"{"kind":"connect","message":"m"}"#.utf8))
        XCTAssertNil(old.legacyDeclined, "旧辅助进程不带这个字段")

        let message = SSHBridgeMessage.approveLegacyAlgorithms(id: 7, SSHBridgeLegacyRequest(host: "h", port: 2, isJumpHost: false))
        guard case .approveLegacyAlgorithms(let id, let legacy)? = try HolderFrame(bridge: message).bridgeMessage else {
            return XCTFail("帧解不回来")
        }
        XCTAssertEqual(id, 7)
        XCTAssertEqual(legacy, SSHBridgeLegacyRequest(host: "h", port: 2, isJumpHost: false))
    }

    // MARK: - 真实握手：进程内测试服务端只给 group14-sha1

    private func legacyServer() async throws -> SSHTestServer {
        var configuration = SSHTestServer.Configuration(
            authentication: .acceptAnyone,
            exec: .routes(["true": .scripted()]))
        configuration.keyExchangeAlgorithms = [SSHDiffieHellmanAlgorithm.group14SHA1.name]
        let server = try await SSHTestServer.start(configuration)
        addTeardownBlock { await server.stop() }
        return server
    }

    private func connect(_ server: SSHTestServer, verifier: HostKeyVerifier,
                         approver: @escaping @Sendable (HostKeyChallenge) async -> Bool) async throws -> uTerm.ConnectedClient {
        try await SSHClientFactory.connect(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil),
            auth: .password(username: "tester", password: "unused"), jumpHostAuth: nil,
            hostKeyVerifier: verifier, hostKeyApprover: approver)
    }

    /// 第一次连：不问加密方式、照常问主机密钥、连上记下同意；之后假装「本机没记过」（别的设备同步来的信任记录），
    /// 再连就问加密方式：拒绝 → 类型化失败、不重连；同意 → 连上，之后不再问。
    func testAgainstInProcessServerOfferingOnlySHA1KeyExchange() async throws {
        guard SSHClientFactory.packageHostKeyPolicy() != .insecureAcceptAll else {
            throw XCTSkip("本机设置关了主机密钥核对，闸门本来就不问")
        }
        let server = try await legacyServer()
        let shared = LegacyAlgorithmConsent.shared
        shared.remove(host: "127.0.0.1", port: server.port)
        addTeardownBlock { shared.remove(host: "127.0.0.1", port: server.port) }
        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))

        let first = Asker(true)
        let client = try await connect(server, verifier: verifier, approver: first.approver)
        XCTAssertEqual(client.shared.legacyAlgorithmsInUse.map(\.role), [.keyExchange])
        await client.close()
        XCTAssertEqual(first.challenges.map(\.kind), [.unknown], "第一次只问主机密钥")
        XCTAssertTrue(shared.contains(host: "127.0.0.1", port: server.port))

        shared.remove(host: "127.0.0.1", port: server.port)
        let refusing = Asker(false)
        do {
            _ = try await connect(server, verifier: verifier, approver: refusing.approver)
            XCTFail("应当失败")
        } catch SSHConnection.SSHConnectionError.weakAlgorithmsDeclined(let refusal) {
            XCTAssertEqual(refusal, LegacyAlgorithmRefusal(host: "127.0.0.1", port: server.port, isJumpHost: false))
        }
        XCTAssertEqual(refusing.challenges.map(\.isWeakAlgorithms), [true], "只问了加密方式一次")
        XCTAssertFalse(shared.contains(host: "127.0.0.1", port: server.port))

        let approving = Asker(true)
        let again = try await connect(server, verifier: verifier, approver: approving.approver)
        await again.close()
        XCTAssertEqual(approving.challenges.map(\.isWeakAlgorithms), [true])
        XCTAssertTrue(shared.contains(host: "127.0.0.1", port: server.port))

        let silent = Asker(false)
        let third = try await connect(server, verifier: verifier, approver: silent.approver)
        await third.close()
        XCTAssertTrue(silent.challenges.isEmpty, "同意过就不再问")
    }

    /// 服务器升级成现代算法、连上了：清掉同意；之后同一个地址又只给旧算法：再问。两台服务端先后占同一个端口、
    /// 用同一把主机密钥（只是加密方式变了）。
    func testUpgradeThenDowngradeAsksAgainAgainstInProcessServers() async throws {
        guard SSHClientFactory.packageHostKeyPolicy() != .insecureAcceptAll else {
            throw XCTSkip("本机设置关了主机密钥核对，闸门本来就不问")
        }
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        var modernConfiguration = SSHTestServer.Configuration(
            authentication: .acceptAnyone, exec: .routes(["true": .scripted()]))
        modernConfiguration.hostKey = hostKey
        let modern = try await SSHTestServer.start(modernConfiguration)
        let port = modern.port
        let shared = LegacyAlgorithmConsent.shared
        addTeardownBlock { shared.remove(host: "127.0.0.1", port: port) }
        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))

        // 以前同意过旧算法，这次服务器只给现代算法：连上、钩子没调 → 同意清掉。
        shared.insert(host: "127.0.0.1", port: port)
        let first = Asker(true)
        let client = try await connect(modern, verifier: verifier, approver: first.approver)
        await client.close()
        XCTAssertEqual(first.challenges.filter(\.isWeakAlgorithms).count, 0)
        XCTAssertFalse(shared.contains(host: "127.0.0.1", port: port), "现代算法连上了，同意清掉")
        await modern.stop()

        // 同一个地址退回只给 group14-sha1：再问；拒绝就不连。
        var legacyConfiguration = SSHTestServer.Configuration(
            authentication: .acceptAnyone, exec: .routes(["true": .scripted()]))
        legacyConfiguration.hostKey = hostKey
        legacyConfiguration.keyExchangeAlgorithms = [SSHDiffieHellmanAlgorithm.group14SHA1.name]
        let legacy = try await SSHTestServer.start(legacyConfiguration, port: port)
        addTeardownBlock { await legacy.stop() }
        let asker = Asker(false)
        do {
            _ = try await connect(legacy, verifier: verifier, approver: asker.approver)
            XCTFail("应当失败")
        } catch SSHConnection.SSHConnectionError.weakAlgorithmsDeclined(let refusal) {
            XCTAssertEqual(refusal.port, port)
        }
        XCTAssertEqual(asker.challenges.map(\.isWeakAlgorithms), [true])
    }

    /// 加密是 AES-GCM、服务器的 MAC 只报 `hmac-sha1` 名字的那类服务器：连上之后 `legacyAlgorithmsInUse` 是空的
    /// （MAC 不用），但每次都要旧算法才协商得成、都会调钩子——同意不会被误清，也不会反复问。
    func testAESGCMWithSHA1MACNameIsNotMistakenForModern() async throws {
        var configuration = SSHTestServer.Configuration(
            authentication: .acceptAnyone, exec: .routes(["true": .scripted()]))
        configuration.transportProtectionSchemes = NIOSSH.Constants.bundledTransportProtectionSchemes
            + [SSHAESCTRTransportProtection<SSHAES128CTR, SSHHMACSHA1>.self]
        let server = try await SSHTestServer.start(configuration)
        addTeardownBlock { await server.stop() }
        let shared = LegacyAlgorithmConsent.shared
        shared.remove(host: "127.0.0.1", port: server.port)
        addTeardownBlock { shared.remove(host: "127.0.0.1", port: server.port) }
        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))

        let first = try await connect(server, verifier: verifier, approver: Asker(true).approver)
        XCTAssertEqual(first.shared.legacyAlgorithmsInUse, [], "夹具对不对：加密是 GCM，MAC 名字不算在用")
        await first.close()
        XCTAssertTrue(shared.contains(host: "127.0.0.1", port: server.port), "第一次静默放行、连上记下")

        for round in 0..<2 {
            let asker = Asker(false)
            let client = try await connect(server, verifier: verifier, approver: asker.approver)
            await client.close()
            XCTAssertTrue(asker.challenges.isEmpty, "第 \(round + 2) 次不问")
            XCTAssertTrue(shared.contains(host: "127.0.0.1", port: server.port), "第 \(round + 2) 次连上也没被误清")
        }
    }

    /// 经跳板机：跳板机只给旧算法、信任过、本机没同意过 → 问的是跳板机，拒绝后归成跳板机那一跳的失败。
    func testJumpHostDeclinedAgainstInProcessServers() async throws {
        guard SSHClientFactory.packageHostKeyPolicy() != .insecureAcceptAll else {
            throw XCTSkip("本机设置关了主机密钥核对，闸门本来就不问")
        }
        let bastion = try await legacyServer()
        let target = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: .acceptAnyone, exec: .routes(["true": .scripted()])))
        addTeardownBlock { await target.stop() }
        let shared = LegacyAlgorithmConsent.shared
        addTeardownBlock { shared.remove(host: "127.0.0.1", port: bastion.port) }
        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        // 先直连一次跳板机，让信任库里有它。
        let direct = try await connect(bastion, verifier: verifier, approver: Asker(true).approver)
        await direct.close()
        shared.remove(host: "127.0.0.1", port: bastion.port)

        let asker = Asker(false)
        do {
            _ = try await SSHClientFactory.connect(
                profile: SSHConnection.ProfileSnapshot(
                    host: "127.0.0.1", port: target.port,
                    jumpHost: .init(host: "127.0.0.1", port: bastion.port)),
                auth: .password(username: "tester", password: "unused"),
                jumpHostAuth: .password(username: "tester", password: "unused"),
                hostKeyVerifier: verifier, hostKeyApprover: asker.approver)
            XCTFail("应当失败")
        } catch let error as SSHConnection.SSHConnectionError {
            guard case .weakAlgorithmsDeclined(let refusal) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(refusal, LegacyAlgorithmRefusal(host: "127.0.0.1", port: bastion.port, isJumpHost: true))
            XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(error))
        }
        XCTAssertEqual(asker.challenges.first?.isJumpHost, true)
        XCTAssertEqual(asker.challenges.count, 1)
    }
}
