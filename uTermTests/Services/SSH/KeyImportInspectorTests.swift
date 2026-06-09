import XCTest
@testable import uTerm

final class KeyImportInspectorTests: XCTestCase {

    func testInspectsRSAFormatsShownByImportReports() throws {
        try assertMaterial(
            KeyImportFixtures.rsaOpenSSH,
            type: .rsa,
            bits: 2048,
            publicKeyPrefix: "ssh-rsa"
        )
        try assertMaterial(
            KeyImportFixtures.rsaPKCS1,
            type: .rsa,
            bits: 2048,
            publicKeyPrefix: "ssh-rsa"
        )
    }

    func testInspectsOpenSSHECDSAKeys() throws {
        try assertMaterial(
            KeyImportFixtures.ecP256OpenSSH,
            type: .ecdsaP256,
            bits: 256,
            publicKeyPrefix: "ecdsa-sha2-nistp256"
        )
        try assertMaterial(
            KeyImportFixtures.ecP384OpenSSH,
            type: .ecdsaP384,
            bits: 384,
            publicKeyPrefix: "ecdsa-sha2-nistp384"
        )
        try assertMaterial(
            KeyImportFixtures.ecP521OpenSSH,
            type: .ecdsaP521,
            bits: 521,
            publicKeyPrefix: "ecdsa-sha2-nistp521"
        )
    }

    func testInspectsPEMECDSAKeys() throws {
        try assertMaterial(
            KeyImportFixtures.ecP256SEC1,
            type: .ecdsaP256,
            bits: 256,
            publicKeyPrefix: "ecdsa-sha2-nistp256"
        )
        try assertMaterial(
            KeyImportFixtures.ecP384SEC1,
            type: .ecdsaP384,
            bits: 384,
            publicKeyPrefix: "ecdsa-sha2-nistp384"
        )
        try assertMaterial(
            KeyImportFixtures.ecP521SEC1,
            type: .ecdsaP521,
            bits: 521,
            publicKeyPrefix: "ecdsa-sha2-nistp521"
        )
    }

    private func assertMaterial(_ pem: String, type: SSHKeyKind, bits: Int,
                                publicKeyPrefix: String,
                                file: StaticString = #filePath,
                                line: UInt = #line) throws {
        let parsed = try PrivateKeyImporter.resolve(pem: pem, passphrase: nil)
        let material = try KeyImportInspector.inspect(rawText: pem, parsed: parsed, comment: "uterm-test")
        XCTAssertEqual(material.type, type, file: file, line: line)
        XCTAssertEqual(material.bits, bits, file: file, line: line)
        XCTAssertTrue(material.publicKey.hasPrefix("\(publicKeyPrefix) "), file: file, line: line)
        XCTAssertTrue(material.publicKey.hasSuffix(" uterm-test"), file: file, line: line)
        XCTAssertTrue(material.fingerprint.hasPrefix("SHA256:"), file: file, line: line)
    }
}
