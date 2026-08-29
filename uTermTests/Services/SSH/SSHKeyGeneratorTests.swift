import XCTest
@testable import uTerm
@testable import USSHKit

final class SSHKeyGeneratorTests: XCTestCase {

    func testGeneratedEd25519RoundTripsThroughImporterAndInspector() throws {
        let comment = "uterm-ed25519"
        let generated = SSHKeyGenerator.generateEd25519(comment: comment)
        try assertGeneratedKey(
            generated,
            comment: comment,
            privateKeyHeader: "-----BEGIN OPENSSH PRIVATE KEY-----",
            expectedParsedCase: "ed25519",
            expectedType: .ed25519,
            expectedBits: 256,
            expectedPublicKeyPrefix: "ssh-ed25519")
    }

    func testGeneratedRSARoundTripsThroughImporterAndInspector() throws {
        for bits in [2048, 3072, 4096] {
            let comment = "uterm-rsa-\(bits)"
            let generated = try SSHKeyGenerator.generateRSA(bits: bits, comment: comment)
            try assertGeneratedKey(
                generated,
                comment: comment,
                privateKeyHeader: "-----BEGIN RSA PRIVATE KEY-----",
                expectedParsedCase: "rsa",
                expectedType: .rsa,
                expectedBits: bits,
                expectedPublicKeyPrefix: "ssh-rsa")
        }
    }

    func testGeneratedECDSARoundTripsThroughImporterAndInspector() throws {
        let cases: [(SSHKeyKind, String, Int, String)] = [
            (.ecdsaP256, "p256", 256, "ecdsa-sha2-nistp256"),
            (.ecdsaP384, "p384", 384, "ecdsa-sha2-nistp384"),
            (.ecdsaP521, "p521", 521, "ecdsa-sha2-nistp521"),
        ]

        for (type, parsedCase, bits, prefix) in cases {
            let comment = "uterm-\(parsedCase)"
            let generated = try SSHKeyGenerator.generateECDSA(type: type, comment: comment)
            try assertGeneratedKey(
                generated,
                comment: comment,
                privateKeyHeader: "-----BEGIN OPENSSH PRIVATE KEY-----",
                expectedParsedCase: parsedCase,
                expectedType: type,
                expectedBits: bits,
                expectedPublicKeyPrefix: prefix)
        }
    }

    private func assertGeneratedKey(_ generated: SSHKeyGenerator.GeneratedKey,
                                    comment: String,
                                    privateKeyHeader: String,
                                    expectedParsedCase: String,
                                    expectedType: SSHKeyKind,
                                    expectedBits: Int,
                                    expectedPublicKeyPrefix: String,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        XCTAssertTrue(generated.privateKeyText.hasPrefix(privateKeyHeader), file: file, line: line)
        XCTAssertTrue(generated.publicKey.hasPrefix("\(expectedPublicKeyPrefix) "), file: file, line: line)
        XCTAssertTrue(generated.publicKey.hasSuffix(" \(comment)"), file: file, line: line)
        XCTAssertTrue(generated.fingerprint.hasPrefix("SHA256:"), file: file, line: line)

        let parsed = try PrivateKeyImporter.resolve(pem: generated.privateKeyText, passphrase: nil)
        XCTAssertEqual(caseName(parsed), expectedParsedCase, file: file, line: line)

        let material = try KeyImportInspector.inspect(
            rawText: generated.privateKeyText, parsed: parsed, comment: comment)
        XCTAssertEqual(material.type, expectedType, file: file, line: line)
        XCTAssertEqual(material.bits, expectedBits, file: file, line: line)
        XCTAssertEqual(material.publicKey, generated.publicKey, file: file, line: line)
        XCTAssertEqual(material.fingerprint, generated.fingerprint, file: file, line: line)
    }

    private func caseName(_ key: ParsedPrivateKey) -> String {
        switch key {
        case .rsa: return "rsa"
        case .legacyOpenSSHRSA: return "rsa"
        case .ed25519: return "ed25519"
        case .p256: return "p256"
        case .p384: return "p384"
        case .p521: return "p521"
        }
    }
}
