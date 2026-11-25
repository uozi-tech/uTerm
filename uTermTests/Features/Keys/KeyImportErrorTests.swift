import XCTest
@testable import uTerm
@testable import USSHKit

/// 导入私钥失败时，界面显示的是 USSHKit 按错误类型给的文案，不是笼统的「无法识别该私钥」。
@MainActor
final class KeyImportErrorTests: XCTestCase {

    /// `openssl ecparam -name secp256k1 -param_enc explicit -genkey -noout` 生成的一次性测试钥匙：
    /// 显式曲线参数、又不是 P-256 / P-384 / P-521，解析器认得出格式但不支持。
    private let explicitSecp256k1 = """
    -----BEGIN EC PRIVATE KEY-----
    MIIBUQIBAQQgNaxPhs5liOW1jYZ/Xi8cHDpaLuEd49BAK1y85mLQTm+ggeMwgeAC
    AQEwLAYHKoZIzj0BAQIhAP////////////////////////////////////7///wv
    MEQEIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABCAAAAAAAAAAAAAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAAABwRBBHm+Zn753LusVaBilc6HCwcCm/zbLc4o
    2VnygVsW+BeYSDradyajxGVdpPv8DhEIqP0XtEimhVQZnEfQj/sQ1LgCIQD/////
    ///////////////+uq7c5q9IoDu/0l6M0DZBQQIBAaFEA0IABE1dtpuzkevZ3yTv
    mQuy1QB4HD4l4RNeuZ9LN6fwjUMVs2qNaRIpA/j8L6iJ+XZH1Q1nH4abRaoutaTt
    LljhYPM=
    -----END EC PRIVATE KEY-----

    """

    func testUnsupportedExplicitCurveShowsTheParsersOwnMessage() async throws {
        let parserError: Error
        do {
            _ = try SSHPrivateKeyParser.parse(pem: explicitSecp256k1, passphrase: nil)
            return XCTFail("secp256k1 的显式曲线参数不该被接受")
        } catch {
            parserError = error
        }
        guard case PrivateKeyImportError.unsupportedFormat = parserError else {
            return XCTFail("应当是 unsupportedFormat，实际是 \(parserError)")
        }

        let fallback = String(localized: "无法识别该私钥")
        let expected = KeyImportErrorMessage.message(for: parserError, fallback: fallback)
        XCTAssertNotEqual(expected, fallback, "USSHKit 对这种错误应当有专门的文案")

        let result = await KeyImport.run(
            normalizedText: KeyPasteText.normalize(explicitSecp256k1),
            name: "explicit-curve",
            passphrase: "",
            existingKeys: []
        )
        switch result {
        case .success:
            XCTFail("不该导入成功")
        case .failure(.failed(let message)):
            XCTAssertEqual(message, expected)
        case .failure(let other):
            XCTFail("应当是带文案的失败，实际是 \(other)")
        }
    }
}
