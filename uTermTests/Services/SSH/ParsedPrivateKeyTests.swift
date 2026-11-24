import XCTest
import Crypto
@testable import uTerm
@testable import USSHKit

final class ParsedPrivateKeyTests: XCTestCase {
    func testEd25519MapsToAuthenticationMethod() throws {
        let key = Curve25519.Signing.PrivateKey()
        let parsed = ParsedPrivateKey.ed25519(key)
        XCTAssertEqual(parsed.authenticationMethods.count, 1)
        XCTAssertEqual(parsed.kind, .ed25519)
    }

    func testP256MapsToAuthenticationMethod() throws {
        let parsed = ParsedPrivateKey.p256(P256.Signing.PrivateKey())
        XCTAssertEqual(parsed.authenticationMethods.count, 1)
        XCTAssertEqual(parsed.kind, .ecdsaP256)
    }
}
