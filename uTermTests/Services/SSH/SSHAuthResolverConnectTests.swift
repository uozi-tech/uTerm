import Security
import XCTest
@testable import uTerm
@testable import USSHKit

/// `SSHAuthResolver.resolveForConnect` / `resolveJump`：由已保存主机新建连接时的唯一凭据规则。
/// 终端、端口转发、CLI 控制通道、Agent 执行器、并行执行、表单「测试连接」的跳板机都经这里，
/// 所以这里钉住的是它们共同的行为：跳板机配了就必须读到凭据，绝不悄悄直连。
final class SSHAuthResolverConnectTests: XCTestCase {

    /// 按 (profileID, kind) 应答的钥匙串桩：没登记的条目当作「不存在」，`failing` 里的 id 一律抛错。
    private struct StubKeychain: KeychainReading {
        var entries: [UUID: [SecretKind: String]] = [:]
        var failing: Set<UUID> = []

        func load(profileID: UUID, kind: SecretKind) throws -> String? {
            if failing.contains(profileID) { throw KeychainError.unexpectedStatus(errSecAuthFailed) }
            return entries[profileID]?[kind]
        }
    }

    private func passwordHost(_ username: String) -> ServerProfile {
        let profile = ServerProfile()
        profile.username = username
        profile.authMethod = .password
        return profile
    }

    func testWithoutJumpHostResolvesTargetOnly() throws {
        let target = passwordHost("root")
        let keychain = StubKeychain(entries: [target.id: [.password: "pw"]])

        let resolved = try SSHAuthResolver.resolveForConnect(
            SSHAuthResolver.Lookup(target), jump: nil, keychain: keychain)

        XCTAssertEqual(resolved.auth, .password(username: "root", password: "pw"))
        XCTAssertNil(resolved.jump)
    }

    func testJumpHostCredentialsAreResolvedFromTheirOwnEntries() throws {
        let target = passwordHost("app")
        let bastion = passwordHost("ops")
        let keychain = StubKeychain(entries: [
            target.id: [.password: "target-pw"],
            bastion.id: [.password: "bastion-pw"],
        ])

        let resolved = try SSHAuthResolver.resolveForConnect(
            SSHAuthResolver.Lookup(target), jump: SSHAuthResolver.Lookup(bastion), keychain: keychain)

        XCTAssertEqual(resolved.auth, .password(username: "app", password: "target-pw"))
        XCTAssertEqual(resolved.jump, .password(username: "ops", password: "bastion-pw"))
    }

    /// 跳板机凭据缺了必须报错，而不是返回 `jump == nil` 让连接直连目标。
    func testMissingJumpHostCredentialThrowsInsteadOfConnectingDirectly() {
        let target = passwordHost("app")
        let bastion = passwordHost("ops")
        let keychain = StubKeychain(entries: [target.id: [.password: "target-pw"]])

        XCTAssertThrowsError(try SSHAuthResolver.resolveForConnect(
            SSHAuthResolver.Lookup(target), jump: SSHAuthResolver.Lookup(bastion), keychain: keychain)
        ) { XCTAssertEqual($0 as? SSHAuthError, .missingPassword) }
    }

    func testJumpHostKeychainFailureSurfacesAsKeychainAccessFailed() {
        let target = passwordHost("app")
        let bastion = passwordHost("ops")
        let keychain = StubKeychain(entries: [target.id: [.password: "target-pw"]], failing: [bastion.id])

        XCTAssertThrowsError(try SSHAuthResolver.resolveForConnect(
            SSHAuthResolver.Lookup(target), jump: SSHAuthResolver.Lookup(bastion), keychain: keychain)
        ) {
            guard case .keychainAccessFailed = $0 as? SSHAuthError else {
                return XCTFail("应为 .keychainAccessFailed，实际：\($0)")
            }
        }
    }

    func testMissingTargetCredentialThrowsEvenWhenJumpHostIsFine() {
        let target = passwordHost("app")
        let bastion = passwordHost("ops")
        let keychain = StubKeychain(entries: [bastion.id: [.password: "bastion-pw"]])

        XCTAssertThrowsError(try SSHAuthResolver.resolveForConnect(
            SSHAuthResolver.Lookup(target), jump: SSHAuthResolver.Lookup(bastion), keychain: keychain)
        ) { XCTAssertEqual($0 as? SSHAuthError, .missingPassword) }
    }

    /// `ServerProfile` 重载读的是 `profile.jumpHost`，与显式传 Lookup 等价。
    func testProfileOverloadFollowsJumpHostRelationship() throws {
        let target = passwordHost("app")
        let bastion = passwordHost("ops")
        target.jumpHost = bastion
        let keychain = StubKeychain(entries: [target.id: [.password: "target-pw"]])

        XCTAssertThrowsError(try SSHAuthResolver.resolveForConnect(profile: target, keychain: keychain)) {
            XCTAssertEqual($0 as? SSHAuthError, .missingPassword)
        }

        let complete = StubKeychain(entries: [
            target.id: [.password: "target-pw"],
            bastion.id: [.password: "bastion-pw"],
        ])
        let resolved = try SSHAuthResolver.resolveForConnect(profile: target, keychain: complete)
        XCTAssertEqual(resolved.jump, .password(username: "ops", password: "bastion-pw"))
    }

    func testResolveJumpWithoutJumpHostIsNil() throws {
        XCTAssertNil(try SSHAuthResolver.resolveJump(nil, keychain: StubKeychain()))
    }

    func testResolveJumpRequiresCredentials() {
        let bastion = passwordHost("ops")
        XCTAssertThrowsError(try SSHAuthResolver.resolveJump(
            SSHAuthResolver.Lookup(bastion), keychain: StubKeychain())
        ) { XCTAssertEqual($0 as? SSHAuthError, .missingPassword) }
    }

    /// 跳板机走私钥时同样按密钥库条目取，规则与目标主机一致。
    func testResolveJumpUsesKeyLibraryEntry() throws {
        let bastion = ServerProfile()
        bastion.username = "ops"
        bastion.authMethod = .privateKey
        let keyID = UUID()
        bastion.keyID = keyID
        let keychain = StubKeychain(entries: [keyID: [.privateKey: "PEM", .passphrase: "pp"]])

        let jump = try SSHAuthResolver.resolveJump(SSHAuthResolver.Lookup(bastion), keychain: keychain)

        XCTAssertEqual(jump, .privateKey(username: "ops", pem: "PEM", passphrase: "pp"))
    }
}
