import XCTest
import SwiftData
import NIOSSH
import USSHTestServer
@testable import uTerm
@testable import USSHKit

/// RSA 用户私钥登录（迁移前 USSHKit 自带 `RSASHA512AuthDelegate`，现在由 USSHCore 的认证挑签名算法）：
/// 对着进程内测试服务端走真实握手，钉住 app 看得到的三件事。
final class RSASHA512AuthDelegateTests: XCTestCase {
    private func key() throws -> SSHRSAPrivateKey {
        try RSAKeyMaterial.makeKey(RSAKeyMaterial.componentsFromPKCS1DER(
            PEMDocument.parse(KeyImportFixtures.rsaPKCS1).der))
    }

    private func connect(_ server: SSHTestServer) async throws -> ConnectedClient {
        let verifier = HostKeyVerifier(modelContainer: try ModelContainer(
            for: KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        return try await SSHClientFactory.connect(
            profile: SSHConnection.ProfileSnapshot(host: "127.0.0.1", port: server.port, jumpHost: nil),
            auth: .privateKey(username: "root", pem: KeyImportFixtures.rsaPKCS1, passphrase: nil),
            jumpHostAuth: nil, hostKeyVerifier: verifier, hostKeyApprover: { _ in true })
    }

    private func start(authorizing publicKey: NIOSSHPublicKey?,
                       methods: NIOSSHAvailableUserAuthenticationMethods = [.password, .publicKey]) async throws -> SSHTestServer {
        var authentication = SSHTestAuthentication(
            authorizedKeys: publicKey.map { ["root": [$0]] } ?? [:], supportedMethods: methods)
        authentication.acceptedRSASignatureAlgorithms = [.rsaSHA2_512, .rsaSHA2_256]
        return try await SSHTestServer.start(SSHTestServer.Configuration(authentication: authentication))
    }

    /// 服务器认这把钥匙：用 SHA-2 签名登录成功（不会退到 SHA-1 的 ssh-rsa）。
    func testOffersPublicKeyAndLogsInWithSHA2() async throws {
        let server = try await start(authorizing: NIOSSHPublicKey(rsaPublicKey: try key().publicKey))
        defer { Task { await server.stop() } }
        let client = try await connect(server)
        await client.close()
        let algorithms = server.events.authAttempts.compactMap(\.rsaSignatureAlgorithm)
        XCTAssertFalse(algorithms.isEmpty)
        XCTAssertFalse(algorithms.contains(.sshRSA), "不应退到 SHA-1：\(algorithms)")
    }

    /// 服务器拒绝这把钥匙：报认证失败（重连逻辑据此停下），试过的次数有限，不会一直重试。
    func testStopsAfterRejection() async throws {
        let server = try await start(authorizing: nil)
        defer { Task { await server.stop() } }
        do {
            let client = try await connect(server)
            await client.close()
            XCTFail("服务器不认这把钥匙，不该连上")
        } catch {
            guard case SSHConnection.SSHConnectionError.authenticationFailed = error else {
                return XCTFail("应为认证失败，实际 \(error)")
            }
            XCTAssertTrue(SSHTransportFailure.isPermanentConnectFailure(error))
        }
        // 服务器没宣告 server-sig-algs：rsa-sha2-512、rsa-sha2-256，最后在同一条连接上试一次 SHA-1 的 ssh-rsa。
        XCTAssertLessThanOrEqual(server.events.authAttempts.count, 3, "每种签名算法最多一次")
    }

    /// 服务器只收密码：不发公钥，报认证失败。
    func testFailsWhenPublicKeyNotAvailable() async throws {
        let server = try await start(authorizing: NIOSSHPublicKey(rsaPublicKey: try key().publicKey),
                                     methods: .password)
        defer { Task { await server.stop() } }
        do {
            let client = try await connect(server)
            await client.close()
            XCTFail("服务器不收公钥，不该连上")
        } catch {
            guard case SSHConnection.SSHConnectionError.authenticationFailed = error else {
                return XCTFail("应为认证失败，实际 \(error)")
            }
        }
        XCTAssertFalse(server.events.authAttempts.contains { $0.accepted })
    }
}
