import Foundation
import SwiftData
import XCTest
@testable import uTerm

/// `SupervisedExec` 对着**真 sshd** 端到端跑：生产连接池 → `ReusableSSHConnection` →
/// Citadel `executeCommandStream` → 远端 shell → 杀进程组。
///
/// 进程内的 Citadel 测试服务端没有 shell，这几条只能靠外部 sshd，所以**默认跳过**。
/// 跑法（用完 `docker rm -f uterm-live-ssh`）：
///
/// ```
/// docker run -d --name uterm-live-ssh -p 127.0.0.1:2299:22 alpine:3.20 sh -c \
///   "apk add --no-cache openssh >/dev/null && ssh-keygen -A >/dev/null && echo root:PASS | chpasswd \
///    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && exec /usr/sbin/sshd -D -e"
/// TEST_RUNNER_UTERM_LIVE_SSH_PORT=2299 xcodebuild test-without-building … \
///   -only-testing:uTermTests/SupervisedExecLiveSSHTests
/// ```
///
/// 账号固定 root / `UTERM_LIVE_SSH_PASSWORD`（缺省 `PASS`）；主机密钥按首连挑战的指纹
/// 走 `trustHostKey` 钉住（内存库，不碰用户的信任库）。
final class SupervisedExecLiveSSHTests: XCTestCase {

    private var pool: ControlConnectionPool!
    private var spec: HostConnectionSpec!

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_LIVE_SSH_PORT"], let port = Int(raw) else {
            throw XCTSkip("没设 UTERM_LIVE_SSH_PORT，跳过真 sshd 集成测试")
        }
        let container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        spec = HostConnectionSpec(
            id: UUID(),
            name: "live",
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: port, jumpHost: nil),
            auth: .password(username: "root", password: env["UTERM_LIVE_SSH_PASSWORD"] ?? "PASS"),
            jumpAuth: nil,
            container: container
        )
        pool = ControlConnectionPool()
    }

    override func tearDown() async throws {
        await pool?.disconnectAll()
        try await super.tearDown()
    }

    /// 首连会因主机密钥未知被拒：按挑战里的指纹 trust 一次再拿执行器。
    private func executor() async throws -> SSHCommandExecutor {
        do {
            return try await pool.executor(for: spec, maxLines: 1_000, maxBytes: 64_000)
        } catch let error as ControlConnectError {
            guard let fingerprint = error.fingerprint else { throw error }
            try await pool.trustHostKey(host: spec, fingerprint: fingerprint)
            return try await pool.executor(for: spec, maxLines: 1_000, maxBytes: 64_000)
        }
    }

    private func run(_ command: String, idle: Duration, maxDuration: Duration = .seconds(60)) async throws
        -> SupervisedExec.Outcome
    {
        let executor = try await executor()
        return await SupervisedExec.run(
            command, on: executor,
            limits: SupervisedExec.Limits(idle: idle, maxDuration: maxDuration, maxLines: 1_000, maxBytes: 64_000))
    }

    func testCompletesWithExitCodeAndLargeOutput() async throws {
        // 20 万字节输出：旧路径 `executeCommand(maxResponseSize: 64_000)` 会整条抛错。
        let outcome = try await run("head -c 200000 /dev/zero | tr '\\0' x; echo; exit 3", idle: .seconds(10))
        guard case .completed(let result) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(result.output.contains(SSHCommandExecutor.pidMarker))
    }

    func testSilentCommandIsKilledTogetherWithItsBackgroundChildren() async throws {
        let started = ContinuousClock.now
        let outcome = try await run("echo begin; sleep 1001 & sleep 1002", idle: .seconds(2))
        guard case .stalled(let stalled) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(stalled.reason, .idle)
        XCTAssertEqual(stalled.kill, .signalled)
        XCTAssertEqual(stalled.partial.output, "begin")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(15))

        // 另开一条确认两个 sleep 都没了（包括 & 放到后台的那个）。
        let check = try await run("ps -o args | grep -c '[s]leep 100' || true", idle: .seconds(10))
        guard case .completed(let result) = check else { return XCTFail("\(check)") }
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "0", "进程组没被收干净")
    }

    func testChattyCommandSurvivesPastTheIdleBudget() async throws {
        let outcome = try await run(
            "for i in 1 2 3 4 5 6; do echo $i; sleep 0.5; done", idle: .seconds(1))
        guard case .completed(let result) = outcome else { return XCTFail("一直有输出却被判卡死：\(outcome)") }
        XCTAssertEqual(result.output, "1\n2\n3\n4\n5\n6")
        XCTAssertEqual(result.exitCode, 0)
    }
}
