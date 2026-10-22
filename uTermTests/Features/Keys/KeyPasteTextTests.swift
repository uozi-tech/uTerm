import XCTest
@testable import uTerm
@testable import USSHKit

final class KeyPasteTextTests: XCTestCase {

    private func generatedEd25519() -> String {
        SSHKeyGenerator.generateEd25519(comment: "paste-test").privateKeyText
    }

    // MARK: - normalize

    func testNormalizeEmptyAndWhitespaceOnly() {
        XCTAssertEqual(KeyPasteText.normalize(""), "")
        XCTAssertEqual(KeyPasteText.normalize("  \n\t\r\n "), "")
    }

    func testNormalizeKeepsCleanKeyAndEndsWithSingleNewline() {
        let key = generatedEd25519()
        let normalized = KeyPasteText.normalize(key)
        XCTAssertEqual(normalized, key.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        XCTAssertFalse(normalized.hasSuffix("\n\n"))
    }

    func testNormalizeStripsCRLFAndIndentation() {
        let key = generatedEd25519()
        let messy = "\n\n" + key
            .split(separator: "\n")
            .map { "    " + $0 + "  " }
            .joined(separator: "\r\n") + "\r\n\r\n"
        XCTAssertEqual(KeyPasteText.normalize(messy), KeyPasteText.normalize(key))
    }

    func testNormalizeRepairsSmartDashesAroundMarkers() {
        let key = generatedEd25519()
        let smart = key
            .replacingOccurrences(of: "-----BEGIN", with: "\u{2014}\u{2013}BEGIN")
            .replacingOccurrences(of: "KEY-----", with: "KEY\u{2014}\u{2014}")
        XCTAssertNotEqual(smart, key)
        XCTAssertEqual(KeyPasteText.normalize(smart), KeyPasteText.normalize(key))
    }

    func testNormalizeReflowsSingleLinePEMSoItParses() throws {
        let key = generatedEd25519()
        let flattened = key.split(separator: "\n").joined(separator: " ")
        XCTAssertFalse(flattened.contains("\n"))

        let normalized = KeyPasteText.normalize(flattened)
        let lines = normalized.split(separator: "\n")
        XCTAssertEqual(lines.first, "-----BEGIN OPENSSH PRIVATE KEY-----")
        XCTAssertEqual(lines.last, "-----END OPENSSH PRIVATE KEY-----")
        XCTAssertTrue(lines.dropFirst().dropLast().allSatisfy { $0.count <= 70 })

        let original = try SSHPrivateKeyParser.parse(pem: key)
        let reparsed = try SSHPrivateKeyParser.parse(pem: normalized)
        let a = try KeyImportInspector.inspect(rawText: key, parsed: original, comment: "")
        let b = try KeyImportInspector.inspect(rawText: normalized, parsed: reparsed, comment: "")
        XCTAssertEqual(a.fingerprint, b.fingerprint)
    }

    func testNormalizeReflowsSingleLineRSAPEMAt64Columns() throws {
        let key = try SSHKeyGenerator.generateRSA(bits: 2048, comment: "").privateKeyText
        let flattened = key.split(separator: "\n").joined(separator: " ")
        let normalized = KeyPasteText.normalize(flattened)
        let body = normalized.split(separator: "\n").dropFirst().dropLast()
        XCTAssertTrue(body.dropLast().allSatisfy { $0.count == 64 })
        XCTAssertNoThrow(try SSHPrivateKeyParser.parse(pem: normalized))
    }

    func testNormalizeLeavesSingleLineLegacyEncryptedPEMAlone() {
        let line = "-----BEGIN RSA PRIVATE KEY----- Proc-Type: 4,ENCRYPTED AAAA -----END RSA PRIVATE KEY-----"
        XCTAssertEqual(KeyPasteText.normalize(line), line + "\n")
    }

    // MARK: - isPublicKeyLine

    func testDetectsPublicKeysAndCertificates() {
        XCTAssertTrue(KeyPasteText.isPublicKeyLine("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI user@host"))
        XCTAssertTrue(KeyPasteText.isPublicKeyLine("  ssh-rsa AAAAB3NzaC1yc2E= \n"))
        XCTAssertTrue(KeyPasteText.isPublicKeyLine("ecdsa-sha2-nistp256 AAAAE2VjZHNh"))
        XCTAssertTrue(KeyPasteText.isPublicKeyLine("ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5"))
        XCTAssertFalse(KeyPasteText.isPublicKeyLine(generatedEd25519()))
        XCTAssertFalse(KeyPasteText.isPublicKeyLine(""))
    }

    // MARK: - looksEncrypted

    func testPlainKeysDoNotLookEncrypted() throws {
        XCTAssertFalse(KeyPasteText.looksEncrypted(generatedEd25519()))
        XCTAssertFalse(KeyPasteText.looksEncrypted(try SSHKeyGenerator.generateRSA(bits: 2048, comment: "").privateKeyText))
        XCTAssertFalse(KeyPasteText.looksEncrypted("random text"))
    }

    func testLegacyAndPKCS8EncryptedMarkersLookEncrypted() {
        XCTAssertTrue(KeyPasteText.looksEncrypted(
            "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,00\n\nAAAA\n-----END RSA PRIVATE KEY-----"))
        XCTAssertTrue(KeyPasteText.looksEncrypted(
            "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----"))
    }

    func testOpenSSHContainerCipherNameDecidesEncryption() {
        func container(cipher: String) -> String {
            var data = Data("openssh-key-v1\0".utf8)
            let name = Data(cipher.utf8)
            withUnsafeBytes(of: UInt32(name.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(name)
            data.append(Data(repeating: 0, count: 16))
            return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(data.base64EncodedString())\n-----END OPENSSH PRIVATE KEY-----"
        }
        XCTAssertTrue(KeyPasteText.looksEncrypted(container(cipher: "aes256-ctr")))
        XCTAssertFalse(KeyPasteText.looksEncrypted(container(cipher: "none")))
    }
}
