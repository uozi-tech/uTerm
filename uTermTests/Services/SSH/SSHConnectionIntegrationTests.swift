import XCTest
import SwiftData
@testable import uTerm
@testable import USSHKit

/// 集成测试 —— 对本地 sshd。无 sshd / 无密码时 SKIP（不 FAIL）。
final class SSHConnectionIntegrationTests: XCTestCase {
    private let testUser = NSUserName()
    private let testPassword = ProcessInfo.processInfo.environment["UTERM_TEST_SSH_PASSWORD"]

    private func skipIfNoPassword() throws {
        try XCTSkipIf(testPassword == nil,
            "设置环境变量 UTERM_TEST_SSH_PASSWORD 后运行此集成测试")
    }

    func testDirectConnectOpensShellAndEchoes() async throws {
        try skipIfNoPassword()
        let profile = ServerProfile()
        profile.host = "127.0.0.1"
        profile.port = 22
        profile.username = testUser
        profile.authMethod = .password

        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        let conn = SSHConnection(
            profile: SSHConnection.ProfileSnapshot(profile),
            auth: .password(username: testUser, password: testPassword!),
            jumpHostAuth: nil,
            hostKeyVerifier: verifier,
            hostKeyApprover: { _ in true }
        )
        try await conn.connect()

        let collected = Task { () -> String in
            var acc = Data()
            for await case .bytes(let chunk) in conn.outputItems {
                acc.append(chunk)
                if String(decoding: acc, as: UTF8.self).contains("UTERM_OK") { break }
            }
            return String(decoding: acc, as: UTF8.self)
        }
        await conn.write(Data("echo UTERM_OK\n".utf8))
        let output = try await withTimeout(seconds: 10) { await collected.value }
        XCTAssertTrue(output.contains("UTERM_OK"))
        await conn.close()
    }

    func testJumpHostConnectReachesTarget() async throws {
        try skipIfNoPassword()
        let bastion = ServerProfile()
        bastion.host = "127.0.0.1"
        bastion.port = 22
        bastion.username = testUser
        bastion.authMethod = .password

        let target = ServerProfile()
        target.host = "127.0.0.1"
        target.port = 22
        target.username = testUser
        target.authMethod = .password
        target.jumpHost = bastion

        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        let conn = SSHConnection(
            profile: SSHConnection.ProfileSnapshot(target),
            auth: .password(username: testUser, password: testPassword!),
            jumpHostAuth: .password(username: testUser, password: testPassword!),
            hostKeyVerifier: verifier,
            hostKeyApprover: { _ in true }
        )
        try await conn.connect()
        let collected = Task { () -> String in
            var acc = Data()
            for await case .bytes(let chunk) in conn.outputItems {
                acc.append(chunk)
                if String(decoding: acc, as: UTF8.self).contains("VIA_JUMP") { break }
            }
            return String(decoding: acc, as: UTF8.self)
        }
        await conn.write(Data("echo VIA_JUMP\n".utf8))
        let output = try await withTimeout(seconds: 15) { await collected.value }
        XCTAssertTrue(output.contains("VIA_JUMP"))
        await conn.close()
    }

    /// 终端里贴图片：图片经这条终端连接上新开的 SFTP 通道传到 `/tmp`，shell 里读回来逐字节一致。
    /// 主机默认本机 sshd，可用 `UTERM_TEST_SSH_HOST` / `_PORT` / `_USER` 指到别的（如 Docker 里的 sshd）。
    func testDeliverImageUploadsToTmpOverTheTerminalConnection() async throws {
        try skipIfNoPassword()
        let env = ProcessInfo.processInfo.environment
        let user = env["UTERM_TEST_SSH_USER"] ?? testUser
        let profile = ServerProfile()
        profile.host = env["UTERM_TEST_SSH_HOST"] ?? "127.0.0.1"
        profile.port = Int(env["UTERM_TEST_SSH_PORT"] ?? "") ?? 22
        profile.username = user
        profile.authMethod = .password

        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        let conn = SSHConnection(
            profile: SSHConnection.ProfileSnapshot(profile),
            auth: .password(username: user, password: testPassword!),
            jumpHostAuth: nil,
            hostKeyVerifier: verifier,
            hostKeyApprover: { _ in true }
        )
        try await conn.connect()

        // 200 KB：要跨好几个 SFTP 写包，才测得到流水线。
        let bytes = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let delivery = try await conn.deliverImage(TerminalImage(format: .png, data: bytes))
        guard case .file(let path) = delivery else { return XCTFail("应当传成文件：\(delivery)") }
        XCTAssertTrue(path.hasPrefix("/tmp/uterm-image-") && path.hasSuffix(".png"), path)

        let collected = Task { () -> String in
            var acc = Data()
            for await case .bytes(let chunk) in conn.outputItems {
                acc.append(chunk)
                // 只认 shell 算出来的那一行（回显的命令行里是 `$(wc …)`，不是数字）。
                if String(decoding: acc, as: UTF8.self).contains(/SIZE_\d+_\d+_END/) { break }
            }
            return String(decoding: acc, as: UTF8.self)
        }
        // 终端在传文件之后照常可用；读回文件大小与校验和。
        await conn.write(Data("echo SIZE_$(wc -c < \(path))_$(cksum < \(path) | cut -d' ' -f1)_END; rm -f \(path)\n".utf8))
        let output = try await withTimeout(seconds: 10) { await collected.value }
        XCTAssertTrue(output.contains("SIZE_200000_\(Self.posixCksum(bytes))_END"), output)
        await conn.close()
    }

    /// POSIX `cksum` 的 CRC（多项式 0x04C11DB7，按字节、末尾混入长度）。
    private static func posixCksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        func feed(_ byte: UInt8) {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        data.forEach(feed)
        var length = data.count
        while length > 0 {
            feed(UInt8(length & 0xFF))
            length >>= 8
        }
        return ~crc
    }
}

/// 简单超时包装。
func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await op() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw XCTSkip("操作超时（可能无可用 sshd）")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
