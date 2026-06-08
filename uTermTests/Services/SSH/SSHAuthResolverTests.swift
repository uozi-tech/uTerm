import XCTest
@testable import uTerm

final class SSHAuthResolverTests: XCTestCase {
    func testPasswordAuthUsesKeychainPassword() throws {
        let profile = ServerProfile()
        profile.username = "root"
        profile.authMethod = .password
        let resolved = try SSHAuthResolver.resolve(
            profile: profile,
            password: "s3cret",
            privateKey: nil,
            passphrase: nil
        )
        guard case .password(let user, let pw) = resolved else {
            return XCTFail("应为 .password")
        }
        XCTAssertEqual(user, "root")
        XCTAssertEqual(pw, "s3cret")
    }

    func testPasswordAuthMissingPasswordThrows() {
        let profile = ServerProfile()
        profile.authMethod = .password
        XCTAssertThrowsError(try SSHAuthResolver.resolve(
            profile: profile, password: nil, privateKey: nil, passphrase: nil
        )) { XCTAssertEqual($0 as? SSHAuthError, .missingPassword) }
    }

    func testPrivateKeyAuthMissingKeyThrows() {
        let profile = ServerProfile()
        profile.authMethod = .privateKey
        XCTAssertThrowsError(try SSHAuthResolver.resolve(
            profile: profile, password: nil, privateKey: nil, passphrase: nil
        )) { XCTAssertEqual($0 as? SSHAuthError, .missingPrivateKey) }
    }

    func testPrivateKeyAuthCarriesKeyAndPassphrase() throws {
        let profile = ServerProfile()
        profile.username = "deploy"
        profile.authMethod = .privateKey
        let resolved = try SSHAuthResolver.resolve(
            profile: profile,
            password: nil,
            privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END...",
            passphrase: "kp"
        )
        guard case .privateKey(let user, let key, let pass) = resolved else {
            return XCTFail("应为 .privateKey")
        }
        XCTAssertEqual(user, "deploy")
        XCTAssertTrue(key.contains("BEGIN OPENSSH"))
        XCTAssertEqual(pass, "kp")
    }

    func testPrivateKeyAuthEmptyPassphraseNormalizesToNil() throws {
        let profile = ServerProfile()
        profile.username = "deploy"
        profile.authMethod = .privateKey
        let resolved = try SSHAuthResolver.resolve(
            profile: profile,
            password: nil,
            privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END...",
            passphrase: ""
        )
        guard case .privateKey(_, _, let pass) = resolved else {
            return XCTFail("应为 .privateKey")
        }
        XCTAssertNil(pass)
    }

    // MARK: - keychain 取钥重载（Fix #15）

    /// 独立测试 service，tearDown 清理，避免污染用户真实钥匙串。
    private let keychain = KeychainStore(service: "com.uozi.uTerm.tests.sshauth")

    /// 把密码存进测试钥匙串后，keychain 重载应取到它（沿用 profile.id 取密码）。
    func testKeychainOverloadResolvesStoredPassword() throws {
        let profile = ServerProfile()
        profile.username = "root"
        profile.authMethod = .password
        defer { try? keychain.delete(profileID: profile.id, kind: .password) }

        try keychain.save("s3cret", profileID: profile.id, kind: .password)
        let resolved = try SSHAuthResolver.resolve(profile: profile, keychain: keychain)
        guard case .password(let user, let pw) = resolved else {
            return XCTFail("应为 .password")
        }
        XCTAssertEqual(user, "root")
        XCTAssertEqual(pw, "s3cret")
    }

    /// Fix #15：钥匙串里没有密码（not-found）时，重载把 not-found 当作「无密码」，
    /// 仍走原有 `missingPassword` 路径——而不是把 not-found 误报成钥匙串访问错误。
    func testKeychainOverloadNotFoundPasswordThrowsMissingPassword() {
        let profile = ServerProfile()
        profile.authMethod = .password
        // 不写入任何条目 → load 返回 nil（not-found）。
        XCTAssertThrowsError(try SSHAuthResolver.resolve(profile: profile, keychain: keychain)) {
            XCTAssertEqual($0 as? SSHAuthError, .missingPassword)
        }
    }

    /// Fix #15：私钥认证下，钥匙串里没有私钥（not-found）时走原有 `missingPrivateKey`
    /// 路径——not-found 不会被错当成钥匙串访问错误。
    func testKeychainOverloadNotFoundPrivateKeyThrowsMissingPrivateKey() {
        let profile = ServerProfile()
        profile.authMethod = .privateKey
        XCTAssertThrowsError(try SSHAuthResolver.resolve(profile: profile, keychain: keychain)) {
            XCTAssertEqual($0 as? SSHAuthError, .missingPrivateKey)
        }
    }

    /// keyID 指向的私钥存在时优先取它，并连带取其口令。
    func testKeychainOverloadUsesKeyIDPrivateKeyAndPassphrase() throws {
        let profile = ServerProfile()
        profile.username = "deploy"
        profile.authMethod = .privateKey
        let keyID = UUID()
        profile.keyID = keyID
        defer {
            try? keychain.delete(profileID: keyID, kind: .privateKey)
            try? keychain.delete(profileID: keyID, kind: .passphrase)
        }

        try keychain.save("-----BEGIN OPENSSH PRIVATE KEY-----\nkid\n-----END...",
                          profileID: keyID, kind: .privateKey)
        try keychain.save("kp", profileID: keyID, kind: .passphrase)

        let resolved = try SSHAuthResolver.resolve(profile: profile, keychain: keychain)
        guard case .privateKey(let user, let key, let pass) = resolved else {
            return XCTFail("应为 .privateKey")
        }
        XCTAssertEqual(user, "deploy")
        XCTAssertTrue(key.contains("kid"))
        XCTAssertEqual(pass, "kp")
    }

    /// keyID 名下无私钥（not-found）时回退到 profile.id 名下的旧私钥。
    func testKeychainOverloadFallsBackToProfileIDWhenKeyIDMissing() throws {
        let profile = ServerProfile()
        profile.username = "deploy"
        profile.authMethod = .privateKey
        profile.keyID = UUID()  // 该 keyID 名下不写任何条目
        defer { try? keychain.delete(profileID: profile.id, kind: .privateKey) }

        try keychain.save("-----BEGIN OPENSSH PRIVATE KEY-----\nlegacy\n-----END...",
                          profileID: profile.id, kind: .privateKey)

        let resolved = try SSHAuthResolver.resolve(profile: profile, keychain: keychain)
        guard case .privateKey(_, let key, _) = resolved else {
            return XCTFail("应为 .privateKey")
        }
        XCTAssertTrue(key.contains("legacy"))
    }

    /// `keychainAccessFailed` 与 not-found 路径（`missingPrivateKey` / `missingPassword`）
    /// 在 `Equatable` 上互不相等——确认真实钥匙串错误与「无密钥」被区分开（Fix #15）。
    func testKeychainAccessFailedIsDistinctFromMissingCases() {
        XCTAssertNotEqual(SSHAuthError.keychainAccessFailed("locked"), .missingPrivateKey)
        XCTAssertNotEqual(SSHAuthError.keychainAccessFailed("locked"), .missingPassword)
        XCTAssertEqual(SSHAuthError.keychainAccessFailed("locked"),
                       .keychainAccessFailed("locked"))
    }
}
