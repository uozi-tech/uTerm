import XCTest
@testable import uTerm

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

        let conn = SSHConnection(
            profile: profile,
            auth: .password(username: testUser, password: testPassword!),
            jumpHostAuth: nil
        )
        try await conn.connect()

        let collected = Task { () -> String in
            var acc = Data()
            for await chunk in conn.outputStream {
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

        let conn = SSHConnection(
            profile: target,
            auth: .password(username: testUser, password: testPassword!),
            jumpHostAuth: .password(username: testUser, password: testPassword!)
        )
        try await conn.connect()
        let collected = Task { () -> String in
            var acc = Data()
            for await chunk in conn.outputStream {
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
