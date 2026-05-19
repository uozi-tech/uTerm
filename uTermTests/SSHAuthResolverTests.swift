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
}
