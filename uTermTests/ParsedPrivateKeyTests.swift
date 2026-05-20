import XCTest
import Crypto
@preconcurrency import Citadel
@testable import uTerm

final class ParsedPrivateKeyTests: XCTestCase {
    func testEd25519MapsToAuthenticationMethod() {
        let key = Curve25519.Signing.PrivateKey()
        let parsed = ParsedPrivateKey.ed25519(key)
        // 仅验证不崩溃、能产出方法对象。
        _ = parsed.authenticationMethod(username: "root")
    }

    func testP256MapsToAuthenticationMethod() {
        let parsed = ParsedPrivateKey.p256(P256.Signing.PrivateKey())
        _ = parsed.authenticationMethod(username: "root")
    }
}
