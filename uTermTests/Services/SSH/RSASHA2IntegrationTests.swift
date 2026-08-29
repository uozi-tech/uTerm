import XCTest
import SwiftData
@testable import uTerm
@testable import USSHKit

/// RSA rsa-sha2-512 公钥认证集成测试 —— 需要真实服务器，默认 SKIP。
///
/// 启用方式：在 Xcode scheme 或 xcodebuild 的 "Arguments Passed On Launch" 中设置：
///   UTERM_TEST_RSA_HOST   — 目标主机（e.g. 203.0.113.10）
///   UTERM_TEST_RSA_USER   — SSH 用户名（e.g. root）
///   UTERM_TEST_RSA_KEY_PATH — PEM 私钥文件路径（e.g. /Users/me/.ssh/id_rsa.pem）
///   UTERM_TEST_RSA_PORT   — （可选）端口，默认 22
///
/// 三个必填变量任意缺失时，测试 SKIP，不 FAIL —— 不影响常规 CI。
final class RSASHA2IntegrationTests: XCTestCase {

    private let env = ProcessInfo.processInfo.environment

    private func skipIfEnvAbsent() throws {
        guard env["UTERM_TEST_RSA_HOST"] != nil,
              env["UTERM_TEST_RSA_USER"] != nil,
              env["UTERM_TEST_RSA_KEY_PATH"] != nil else {
            throw XCTSkip(
                "设置环境变量 UTERM_TEST_RSA_HOST / UTERM_TEST_RSA_USER / UTERM_TEST_RSA_KEY_PATH 后运行此集成测试")
        }
    }

    func testRSASHA2512AuthConnectsAndEchoes() async throws {
        try skipIfEnvAbsent()

        let host    = env["UTERM_TEST_RSA_HOST"]!
        let user    = env["UTERM_TEST_RSA_USER"]!
        let keyPath = env["UTERM_TEST_RSA_KEY_PATH"]!
        let port    = env["UTERM_TEST_RSA_PORT"].flatMap(Int.init) ?? 22

        // 读取 PEM 私钥文件。
        let pemText: String
        do {
            pemText = try String(contentsOfFile: keyPath, encoding: .utf8)
        } catch {
            XCTFail("无法读取私钥文件 \(keyPath)：\(error)")
            return
        }

        // 建立 SSHConnection，与 SSHConnectionIntegrationTests 结构对齐。
        let profile = ServerProfile()
        profile.host = host
        profile.port = port
        profile.username = user
        profile.authMethod = .privateKey

        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))

        let conn = SSHConnection(
            profile: SSHConnection.ProfileSnapshot(profile),
            auth: .privateKey(username: user, pem: pemText, passphrase: nil),
            jumpHostAuth: nil,
            hostKeyVerifier: verifier,
            hostKeyApprover: { _ in true }
        )
        try await conn.connect()

        let collected = Task { () -> String in
            var acc = Data()
            for await chunk in conn.outputStream {
                acc.append(chunk)
                if String(decoding: acc, as: UTF8.self).contains("RSA_OK") { break }
            }
            return String(decoding: acc, as: UTF8.self)
        }
        await conn.write(Data("echo RSA_OK\n".utf8))
        let output = try await withTimeout(seconds: 15) { await collected.value }
        XCTAssertTrue(output.contains("RSA_OK"),
                      "rsa-sha2-512 认证后 echo 未收到预期输出，实际输出：\(output)")
        await conn.close()
    }
}
