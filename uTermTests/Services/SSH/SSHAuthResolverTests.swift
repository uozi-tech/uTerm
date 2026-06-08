import Security
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

    // MARK: - 钥匙串读取抛错的端到端路径（Fix #15-residual）

    /// 注入用桩：可配置每种 `SecretKind` 的读取结果（抛错 / 返回值 / not-found=nil）。
    /// 让 `SSHAuthResolver.resolve(profile:keychain:)` 在「钥匙串被锁」场景下被端到端驱动，
    /// 而不必真正锁住用户钥匙串。
    private struct StubKeychain: KeychainReading {
        /// 各 kind 的行为：`.success(nil)` = not-found，`.success(v)` = 命中，`.failure` = 抛错。
        var results: [SecretKind: Result<String?, Error>]

        func load(profileID: UUID, kind: SecretKind) throws -> String? {
            switch results[kind] ?? .success(nil) {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
    }

    /// Fix #15-residual：私钥认证下，私钥读取**抛错**（钥匙串被锁 / `errSecAuthFailed`）时，
    /// resolve 必须包成 `keychainAccessFailed` 上抛，而**不是**误报成 `missingPrivateKey`。
    func testKeychainOverloadPrivateKeyThrowYieldsKeychainAccessFailed() {
        let profile = ServerProfile()
        profile.username = "deploy"
        profile.authMethod = .privateKey
        let stub = StubKeychain(results: [
            .privateKey: .failure(KeychainError.unexpectedStatus(errSecAuthFailed)),
        ])
        XCTAssertThrowsError(try SSHAuthResolver.resolve(profile: profile, keychain: stub)) {
            guard case .keychainAccessFailed = $0 as? SSHAuthError else {
                return XCTFail("应为 .keychainAccessFailed，实际：\(String(describing: $0 as? SSHAuthError))")
            }
        }
    }

    /// Fix #15-residual：keyID 名下私钥读取抛错时同样上抛 `keychainAccessFailed`——
    /// keyID 路径下钥匙串错误不会被静默吞掉当作「条目不存在」而回退。
    func testKeychainOverloadKeyIDPrivateKeyThrowYieldsKeychainAccessFailed() {
        let profile = ServerProfile()
        profile.username = "deploy"
        profile.authMethod = .privateKey
        profile.keyID = UUID()
        let stub = StubKeychain(results: [
            .privateKey: .failure(KeychainError.unexpectedStatus(errSecAuthFailed)),
        ])
        XCTAssertThrowsError(try SSHAuthResolver.resolve(profile: profile, keychain: stub)) {
            guard case .keychainAccessFailed = $0 as? SSHAuthError else {
                return XCTFail("应为 .keychainAccessFailed，实际：\(String(describing: $0 as? SSHAuthError))")
            }
        }
    }

    /// Fix #15-residual：密码认证下，密码读取**抛错**时上抛 `keychainAccessFailed`，
    /// 而非误报 `missingPassword`。
    func testKeychainOverloadPasswordThrowYieldsKeychainAccessFailed() {
        let profile = ServerProfile()
        profile.username = "root"
        profile.authMethod = .password
        let stub = StubKeychain(results: [
            .password: .failure(KeychainError.unexpectedStatus(errSecAuthFailed)),
        ])
        XCTAssertThrowsError(try SSHAuthResolver.resolve(profile: profile, keychain: stub)) {
            guard case .keychainAccessFailed = $0 as? SSHAuthError else {
                return XCTFail("应为 .keychainAccessFailed，实际：\(String(describing: $0 as? SSHAuthError))")
            }
        }
    }

    /// Fix #15-residual（对照组）：所有 kind 都是 not-found（桩返回 nil）时仍走原有
    /// `missingPrivateKey` 路径——确认抛错与 not-found 经同一注入接口被正确区分。
    func testStubKeychainNotFoundPrivateKeyThrowsMissingPrivateKey() {
        let profile = ServerProfile()
        profile.authMethod = .privateKey
        let stub = StubKeychain(results: [:])  // 全部默认 .success(nil) = not-found
        XCTAssertThrowsError(try SSHAuthResolver.resolve(profile: profile, keychain: stub)) {
            XCTAssertEqual($0 as? SSHAuthError, .missingPrivateKey)
        }
    }

    /// Fix #15-residual（对照组）：密码认证下全 not-found 仍走 `missingPassword`。
    func testStubKeychainNotFoundPasswordThrowsMissingPassword() {
        let profile = ServerProfile()
        profile.authMethod = .password
        let stub = StubKeychain(results: [:])
        XCTAssertThrowsError(try SSHAuthResolver.resolve(profile: profile, keychain: stub)) {
            XCTAssertEqual($0 as? SSHAuthError, .missingPassword)
        }
    }
}
