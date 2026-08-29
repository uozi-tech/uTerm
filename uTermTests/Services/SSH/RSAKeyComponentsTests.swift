import XCTest
@testable import uTerm
@testable import USSHKit

final class RSAKeyComponentsTests: XCTestCase {
    /// 从 PEM 文本取 DER 的小助手。
    private func der(of pem: String) throws -> [UInt8] {
        try PEMDocument.parse(pem).der
    }

    func testExtractsFromPKCS1() throws {
        let comps = try RSAKeyComponents.fromPKCS1DER(der(of: KeyImportFixtures.rsaPKCS1))
        // RSA-2048：模数约 256 字节，e 通常为 65537（3 字节），d 与模数同量级。
        XCTAssertGreaterThan(comps.modulus.count, 200)
        XCTAssertFalse(comps.publicExponent.isEmpty)
        XCTAssertGreaterThan(comps.privateExponent.count, 200)
        XCTAssertGreaterThan(comps.prime1.count, 100)
        XCTAssertGreaterThan(comps.prime2.count, 100)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try RSAKeyComponents.fromPKCS1DER([0x00, 0x01, 0x02]))
    }
}
