import XCTest
@testable import USSHKit

final class PublicAPITests: XCTestCase {
    func testEndpointAndForwardingRequestArePureValues() {
        let jump = SSHJumpHost(
            host: "bastion.example.com",
            username: "jump",
            credential: .password("secret")
        )
        let endpoint = SSHEndpoint(
            host: "db.example.com",
            username: "database",
            jumpHost: jump
        )
        let request = SSHForwardingRequest(
            endpoint: endpoint,
            credential: .agent,
            targetHost: "127.0.0.1",
            targetPort: 5432
        )

        XCTAssertEqual(request.endpoint.host, "db.example.com")
        XCTAssertEqual(request.endpoint.jumpHost?.address.host, "bastion.example.com")
        XCTAssertEqual(request.target.port, 5432)
        XCTAssertEqual(request.localPort, 0)
    }

    func testGeneratedEd25519AndECDSAKeysRoundTripThroughPublicParser() throws {
        let ed25519 = SSHKeyGenerator.generateEd25519(comment: "package-test")
        XCTAssertEqual(
            try SSHPrivateKeyParser.parse(pem: ed25519.privateKeyText).kind,
            .ed25519
        )

        let ecdsa = try SSHKeyGenerator.generateECDSA(
            type: .ecdsaP256,
            comment: "package-test"
        )
        XCTAssertEqual(
            try SSHPrivateKeyParser.parse(pem: ecdsa.privateKeyText).kind,
            .ecdsaP256
        )
    }

    func testGeneratedRSAKeyRoundTripsThroughPublicParser() throws {
        let rsa = try SSHKeyGenerator.generateRSA(bits: 2048, comment: "package-test")
        XCTAssertEqual(
            try SSHPrivateKeyParser.parse(pem: rsa.privateKeyText).kind,
            .rsa
        )
    }
}
