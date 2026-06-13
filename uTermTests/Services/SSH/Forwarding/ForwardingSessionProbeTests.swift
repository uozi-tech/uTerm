import XCTest
import SwiftData
@testable import uTerm

/// `ForwardingSession.verifyConnectionAlive` 的生命周期守卫（无网络）：
/// 看门狗扫描可能落在会话生命周期的任意时刻，这里钉死三个边界 ——
/// 连接未建立不误杀、关闭后判死、判死/关闭后会话不可复用。
/// 真实 exec 探测与判死级联（隧道翻 `.error`、监听关闭）见
/// `ForwardingSessionIntegrationTests`（需本地 sshd，CI/CLI 下 SKIP）。
@MainActor
final class ForwardingSessionProbeTests: XCTestCase {

    /// 同步收集 `onStatus` 回报。本文件覆盖的路径都在 actor 方法内同步调用
    /// 回调（不经 Task 跳转），await 返回后即可断言，无需轮询。
    private final class StatusLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(UUID, TunnelStatus)] = []
        func append(_ id: UUID, _ status: TunnelStatus) {
            lock.lock(); defer { lock.unlock() }
            entries.append((id, status))
        }
        var all: [(UUID, TunnelStatus)] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }
    }

    private func makeSession(log: StatusLog) throws -> ForwardingSession {
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
            onStatus: { log.append($0, $1) })
    }

    private func makeRule() -> ForwardingRuleSnapshot {
        ForwardingRuleSnapshot(id: UUID(), serverID: UUID(), name: "探测规则", kind: .local,
                               listenHost: "127.0.0.1", listenPort: 50_000,
                               destHost: "127.0.0.1", destPort: 80, autostart: false)
    }

    /// connect 在飞 / 从未连接：无从探测 → 视作存活，不报任何状态。
    /// （唤醒扫描撞上刚发起的连接时，绝不能把它误杀成 error。）
    func testProbeWithoutConnectionIsAliveAndSilent() async throws {
        let log = StatusLog()
        let session = try makeSession(log: log)

        let alive = await session.verifyConnectionAlive(timeout: .seconds(1))

        XCTAssertTrue(alive, "未建立连接的会话不应被判死")
        XCTAssertTrue(log.all.isEmpty, "不应报任何状态，实际：\(log.all)")
    }

    /// 已关闭的会话（teardown / 判死之后再被扫到）→ 判死，且幂等：不再报状态。
    /// 调用方（coordinator）据 false 驱逐缓存，重复驱逐无害。
    func testProbeAfterCloseReportsDeadSilently() async throws {
        let log = StatusLog()
        let session = try makeSession(log: log)
        await session.close()

        let alive = await session.verifyConnectionAlive(timeout: .seconds(1))

        XCTAssertFalse(alive, "已关闭的会话应判死")
        XCTAssertTrue(log.all.isEmpty, "幂等收尾不应再报状态，实际：\(log.all)")
    }

    /// 判死 / 关闭后的会话不可复用：start 立即报 `.error`（UI 行出现恢复入口），
    /// 不在死连接上静默挂死。
    func testStartAfterCloseReportsErrorImmediately() async throws {
        let log = StatusLog()
        let session = try makeSession(log: log)
        let rule = makeRule()
        await session.close()

        await session.start(rule)

        guard case .error = log.all.last(where: { $0.0 == rule.id })?.1 else {
            return XCTFail("close 后 start 应报 .error，实际：\(log.all)")
        }
    }
}
