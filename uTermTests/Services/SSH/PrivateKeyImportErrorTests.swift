import XCTest
@testable import uTerm

final class PrivateKeyImportErrorTests: XCTestCase {
    func testEveryCaseHasNonEmptyChineseDescription() {
        let cases: [PrivateKeyImportError] = [
            .malformedPEM(reason: "x"), .unsupportedFormat(label: "DSA PRIVATE KEY"),
            .dsaUnsupported, .encryptedKeyNeedsPassphrase, .incorrectPassphrase,
            .unsupportedCipher(name: "RC2"), .unsupportedKDF(name: "PBES1"),
            .malformedKey(reason: "x"),
        ]
        for c in cases {
            XCTAssertFalse((c.errorDescription ?? "").isEmpty, "\(c) 缺少文案")
        }
    }

    func testEquatableIgnoresAssociatedText() {
        XCTAssertEqual(PrivateKeyImportError.malformedPEM(reason: "a"),
                       PrivateKeyImportError.malformedPEM(reason: "b"))
        XCTAssertNotEqual(PrivateKeyImportError.dsaUnsupported,
                          PrivateKeyImportError.incorrectPassphrase)
    }
}
