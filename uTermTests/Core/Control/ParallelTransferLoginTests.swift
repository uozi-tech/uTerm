import XCTest
import SwiftData
import USSHTestServer
@testable import uTerm
@testable import USSHKit

/// 并行传输对着真的（进程内）SSH 服务端：凭据错了，整次传输只多**一次**失败的登录。
///
/// 8 个工作者同时去借会话就是 8 次失败的登录，超过 fail2ban 默认的 5 次，用户的 IP 会被封。这里用的是真的连接池
/// （`ControlConnectionPool`，握手并发 4）和真的 `SFTPSession`，数服务端收到的认证请求。
final class ParallelTransferLoginTests: XCTestCase {

    private var server: SSHTestServer!
    private var container: ModelContainer!
    private var root: SFTPLocalFileSystem!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        root = try SFTPLocalFileSystem.makeTemporary(prefix: "uterm-parallel-login")
        // 40 MiB → 5 段（每段 8 MiB），配 8 个通道时 5 个工作者都有活干。
        try Data(repeating: 0x42, count: 40 << 20).write(to: root.rootURL.appendingPathComponent("big.bin"))
    }

    override func tearDown() async throws {
        await server?.stop()
        try? root?.removeRoot()
        server = nil
        try await super.tearDown()
    }

    /// `acceptFirst` 次登录成功，之后的全拒（服务器上刚改了密码，池里还有一条用旧密码登录的会话）。
    private func startServer(acceptFirst: Int) async throws {
        let accepted = Counter()
        var configuration = SSHTestServer.Configuration(authentication: SSHTestAuthentication(custom: { _ in
            accepted.next() < acceptFirst
        }))
        configuration.serveSFTP(fileSystem: root)
        server = try await SSHTestServer.start(configuration)
    }

    private func makePool() -> ControlConnectionPool {
        let container = container!
        return ControlConnectionPool(connector: ControlConnectionPool.Connector(
            makeExec: { _ in throw ControlConnectError.connectFailed("unused") },
            makeSFTP: { spec in
                let sink = HostKeyChallengeSink()
                do {
                    let connected = try await SSHClientFactory.connect(
                        profile: spec.profile, auth: spec.auth, jumpHostAuth: nil,
                        hostKeyVerifier: HostKeyVerifier(modelContainer: container),
                        hostKeyApprover: { _ in true })
                    return try await SFTPSession(connected: connected, pacesUploads: false)
                } catch {
                    throw ControlConnectionPool.mapConnectError(error, sink: sink)
                }
            },
            trustHostKey: { _, _ in }))
    }

    private func spec() -> HostConnectionSpec {
        HostConnectionSpec(
            id: UUID(), name: "test",
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil),
            auth: .password(username: "tester", password: "whatever"), jumpAuth: nil, container: container)
    }

    private func rejectedLogins() -> Int {
        server.events.authAttempts.filter { !$0.accepted }.count
    }

    private func download(pool: ControlConnectionPool, host: HostConnectionSpec) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uterm-pt-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        _ = try await ParallelTransfer.download(
            host: host, pool: pool, remotePath: "/big.bin", fd: handle.fileDescriptor, ranges: nil,
            tuning: ParallelTransfer.Tuning.download.with(channels: 8), onSegment: { _ in })
    }

    /// 读大小那一次用的是唯一一次能登录成功的会话；之后的工作者第一个去建新连接就被拒，其余的不再去登录。
    func testWrongCredentialCostsOneFailedLoginWithEightWorkers() async throws {
        try await startServer(acceptFirst: 1)
        let pool = makePool()

        do {
            try await download(pool: pool, host: spec())
            XCTFail("凭据错了应当失败")
        } catch {
            guard case ControlConnectError.authFailed = error else { return XCTFail("应是认证失败：\(error)") }
        }

        XCTAssertEqual(rejectedLogins(), 1, "整次传输只该有一次失败的登录")
        await pool.disconnectAll()
    }

    /// 一开始就登不上：读大小那一步就失败，同样只有一次。
    func testWrongCredentialFromTheStartCostsOneFailedLogin() async throws {
        try await startServer(acceptFirst: 0)
        let pool = makePool()

        do {
            try await download(pool: pool, host: spec())
            XCTFail("凭据错了应当失败")
        } catch {}

        XCTAssertEqual(rejectedLogins(), 1)
        await pool.disconnectAll()
    }

    /// 凭据对的时候照常并行：8 个通道都建起来（借会话只是排队，不是只用一条）。
    func testRightCredentialStillOpensSeveralChannels() async throws {
        try await startServer(acceptFirst: .max)
        let pool = makePool()

        try await download(pool: pool, host: spec())

        XCTAssertEqual(rejectedLogins(), 0)
        XCTAssertGreaterThan(server.events.authAttempts.count, 1, "应当并行开了不止一条会话")
        await pool.disconnectAll()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
