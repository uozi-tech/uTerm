import XCTest
@testable import uTerm
@testable import USSHKit

final class PEMDocumentTests: XCTestCase {

    func testParsesLabelAndDER() throws {
        let pem = """
        -----BEGIN TEST KEY-----
        AQID
        -----END TEST KEY-----
        """
        let doc = try PEMDocument.parse(pem)
        XCTAssertEqual(doc.label, "TEST KEY")
        XCTAssertEqual(doc.der, [0x01, 0x02, 0x03])
        XCTAssertTrue(doc.headers.isEmpty)
    }

    func testParsesRFC1421Headers() throws {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        Proc-Type: 4,ENCRYPTED
        DEK-Info: AES-128-CBC,0123456789ABCDEF0123456789ABCDEF

        AQID
        -----END RSA PRIVATE KEY-----
        """
        let doc = try PEMDocument.parse(pem)
        XCTAssertEqual(doc.label, "RSA PRIVATE KEY")
        XCTAssertEqual(doc.headers["Proc-Type"], "4,ENCRYPTED")
        XCTAssertEqual(doc.headers["DEK-Info"], "AES-128-CBC,0123456789ABCDEF0123456789ABCDEF")
        XCTAssertEqual(doc.der, [0x01, 0x02, 0x03])
    }

    func testToleratesCRLFAndSurroundingWhitespace() throws {
        let pem = "\r\n  -----BEGIN X-----\r\nAQID\r\n-----END X-----  \r\n"
        let doc = try PEMDocument.parse(pem)
        XCTAssertEqual(doc.der, [0x01, 0x02, 0x03])
    }

    func testMissingBeginThrows() {
        XCTAssertThrowsError(try PEMDocument.parse("garbage")) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedPEM(reason: ""))
        }
    }

    func testBadBase64Throws() {
        let pem = "-----BEGIN X-----\n!!!!\n-----END X-----"
        XCTAssertThrowsError(try PEMDocument.parse(pem)) {
            XCTAssertEqual($0 as? PrivateKeyImportError, .malformedPEM(reason: ""))
        }
    }
}
