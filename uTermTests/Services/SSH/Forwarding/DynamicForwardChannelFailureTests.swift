import XCTest
import SwiftData
import USSHTestServer
@testable import uTerm
@testable import USSHKit

/// `-D`（SOCKS5）开通道失败也要像 `-L` 一样交给会话判断：目标侧的拒绝记成「近期连接问题」（规则照常服务），
/// 传输层错误 / 开通道超时拆掉整条会话重建。以前 `-D` 只记一行日志，转发平面死了监听还亮着绿灯。
final class DynamicForwardChannelFailureTests: XCTestCase {

    /// 一个最简单的 SOCKS5 客户端：greeting → CONNECT 127.0.0.1:80，返回应答码（0 = 成功）。
    private nonisolated static func socksConnect(port: Int) throws -> UInt8 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        // 收不到应答时 read 最多等 5 秒，不让一个卡住的转发把线程永远占着。
        var limit = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        func send(_ bytes: [UInt8]) { _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } }
        func receive(_ count: Int) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: count)
            var got = 0
            while got < count {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
                if n <= 0 { break }
                got += n
            }
            return Array(buffer.prefix(got))
        }
        send([5, 1, 0])
        _ = receive(2)
        send([5, 1, 0, 1, 127, 0, 0, 1, 0, 80])
        let reply = receive(10)
        return reply.count > 1 ? reply[1] : 0xFF
    }

    private final class Issues: @unchecked Sendable {
        private let lock = NSLock()
        private var reasons: [String] = []
        func add(_ reason: String) { lock.withLock { reasons.append(reason) } }
        var count: Int { lock.withLock { reasons.count } }
    }

    func testRejectedChannelIsReportedAsAConnectionIssue() async throws {
        let server = try await SSHTestServer.start(SSHTestServer.Configuration(
            authentication: .acceptAnyone, allowsDirectTCPIP: false))
        defer { Task { await server.stop() } }
        let container = try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let issues = Issues()
        let session = ForwardingSession(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil),
            auth: .password(username: "tester", password: "x"), jumpHostAuth: nil,
            hostKeyVerifier: HostKeyVerifier(modelContainer: container), hostKeyApprover: { _ in true },
            onStatus: { _, _ in },
            onConnectionIssue: { _, reason in issues.add(reason) })
        try await bounded("connect() 返回", within: 20) { try await session.connect() }
        let port = Int.random(in: 41_000...49_000)
        let rule = ForwardingRuleSnapshot(
            id: UUID(), serverID: UUID(), name: "socks", kind: .dynamic,
            listenHost: "127.0.0.1", listenPort: port, destHost: nil, destPort: 0, autostart: false)
        try await bounded("start(rule) 返回") { await session.start(rule) }
        try await Task.sleep(for: .milliseconds(300))

        let reply = try await bounded("SOCKS 应答") { try await Task.detached { try Self.socksConnect(port: port) }.value }
        XCTAssertNotEqual(reply, 0, "服务器拒绝了开通道，SOCKS 应答应当是失败")

        let deadline = ContinuousClock.now + .seconds(5)
        while issues.count == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(issues.count, 1, "开通道失败要交给会话（以前 -D 只记日志）")
        _ = try? await bounded("close() 返回") { await session.close() }
    }
}
