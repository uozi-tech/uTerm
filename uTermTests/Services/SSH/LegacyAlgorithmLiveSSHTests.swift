import Foundation
import SwiftData
import XCTest
@testable import uTerm
@_spi(uTermIntegration) import USSHKit

/// 「加密方式变弱了」对着**真 OpenSSH**：只给 `ssh-rsa`（SHA-1）主机签名的 sshd。第一次连静默退到旧算法、照常问主机密钥；
/// 信任过、本机没记过同意时问用户（拒绝 → 类型化失败；同意 → 连上、之后不再问）；命令行的连接池不能问，回 `weak_algorithms`。
///
/// 默认跳过。跑法（用完 `docker rm -f uterm-legacy-ssh`）：
///
/// ```
/// # 与 make test-holder-e2e 同一个镜像（它的 Dockerfile 要一份 authorized_keys，这里用不着公钥，放个空的）
/// ctx=$(mktemp -d) && cp holder/e2e/sshd/Dockerfile "$ctx" && touch "$ctx/authorized_keys"
/// docker build -t uterm-holder-e2e-sshd "$ctx"
/// docker run -d --name uterm-legacy-ssh -p 127.0.0.1:2298:22 uterm-holder-e2e-sshd \
///   /usr/sbin/sshd -D -e -o HostKeyAlgorithms=ssh-rsa -o PasswordAuthentication=yes
/// TEST_RUNNER_UTERM_LEGACY_SSH_PORT=2298 xcodebuild test-without-building … \
///   -only-testing:uTermTests/LegacyAlgorithmLiveSSHTests
/// ```
///
/// 账号 `dev` / `UTERM_LEGACY_SSH_PASSWORD`（缺省 `dev`，镜像里就是这个）。信任库是内存库，同意记在测试宿主自己那份偏好里。
@MainActor
final class LegacyAlgorithmLiveSSHTests: XCTestCase {

    private var port = 0
    private var password = ""
    private var container: ModelContainer!

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_LEGACY_SSH_PORT"], let port = Int(raw) else {
            throw XCTSkip("没设 UTERM_LEGACY_SSH_PORT，跳过只给 SHA-1 的真 sshd 测试")
        }
        guard SSHClientFactory.packageHostKeyPolicy() != .insecureAcceptAll else {
            throw XCTSkip("本机设置关了主机密钥核对，闸门本来就不问")
        }
        self.port = port
        password = env["UTERM_LEGACY_SSH_PASSWORD"] ?? "dev"
        container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        LegacyAlgorithmConsent.shared.remove(host: "127.0.0.1", port: port)
    }

    override func tearDown() async throws {
        if port != 0 { LegacyAlgorithmConsent.shared.remove(host: "127.0.0.1", port: port) }
        try await super.tearDown()
    }

    private nonisolated final class Asker: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [HostKeyChallenge] = []
        private let answer: Bool
        init(_ answer: Bool) { self.answer = answer }
        var weakAsks: Int { lock.withLock { recorded.filter(\.isWeakAlgorithms).count } }
        var hostKeyAsks: Int { lock.withLock { recorded.filter { !$0.isWeakAlgorithms }.count } }
        var approver: @Sendable (HostKeyChallenge) async -> Bool {
            { [self] challenge in
                lock.withLock { recorded.append(challenge) }
                return answer
            }
        }
    }

    private var profile: SSHConnection.ProfileSnapshot {
        SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port, jumpHost: nil)
    }

    private func connect(_ asker: Asker, verifier: HostKeyVerifier) async throws -> uTerm.ConnectedClient {
        try await SSHClientFactory.connect(
            profile: profile, auth: .password(username: "dev", password: password), jumpHostAuth: nil,
            hostKeyVerifier: verifier, hostKeyApprover: asker.approver)
    }

    func testDowngradeOnTrustedHostAsksAndCLIIsRefused() async throws {
        let consent = LegacyAlgorithmConsent.shared
        let verifier = HostKeyVerifier(modelContainer: container)

        // 第一次：静默退到旧算法，只问主机密钥；连上之后记下同意。
        let first = Asker(true)
        let client = try await connect(first, verifier: verifier)
        let echoed = try await client.exec("echo legacy-ok")
        XCTAssertEqual(echoed, "legacy-ok\n")
        XCTAssertTrue(client.shared.legacyAlgorithmsInUse.contains(SSHLegacyAlgorithm(role: .hostKey, name: "ssh-rsa")))
        await client.close()
        XCTAssertEqual(first.weakAsks, 0)
        XCTAssertEqual(first.hostKeyAsks, 1)
        XCTAssertTrue(consent.contains(host: "127.0.0.1", port: port))

        // 假装本机没记过（信任记录是别的设备同步来的、或以前用现代算法连的）：问；拒绝 → 不连、不重试。
        consent.remove(host: "127.0.0.1", port: port)
        let refusing = Asker(false)
        do {
            _ = try await connect(refusing, verifier: verifier)
            XCTFail("应当失败")
        } catch let error as SSHConnection.SSHConnectionError {
            guard case .weakAlgorithmsDeclined(let refusal) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(refusal, LegacyAlgorithmRefusal(host: "127.0.0.1", port: port, isJumpHost: false))
            XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(error))
        }
        XCTAssertEqual(refusing.weakAsks, 1)
        XCTAssertEqual(refusing.hostKeyAsks, 0, "没走到主机密钥")

        // 命令行的连接池：不能问，回 weak_algorithms。
        let spec = HostConnectionSpec(id: UUID(), name: "legacy", profile: profile,
                                      auth: .password(username: "dev", password: password), jumpAuth: nil,
                                      container: container)
        let sink = HostKeyChallengeSink()
        do {
            _ = try await ControlConnectionPool.liveConnect(spec, sink: sink)()
            XCTFail("应当失败")
        } catch {
            let mapped = ControlConnectionPool.mapConnectError(error, sink: sink)
            guard case .weakAlgorithms = mapped else { return XCTFail("\(mapped)") }
            XCTAssertEqual(mapped.code, .weak_algorithms)
        }

        // 同意 → 连上；之后不再问。
        let approving = Asker(true)
        let again = try await connect(approving, verifier: verifier)
        await again.close()
        XCTAssertEqual(approving.weakAsks, 1)
        XCTAssertTrue(consent.contains(host: "127.0.0.1", port: port))
        let quiet = Asker(false)
        let third = try await connect(quiet, verifier: verifier)
        await third.close()
        XCTAssertEqual(quiet.weakAsks, 0)
    }
}
