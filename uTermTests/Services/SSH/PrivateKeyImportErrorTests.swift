import XCTest
@testable import uTerm
@testable import USSHKit

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
            XCTAssertFalse((c.failureReason ?? "").isEmpty, "\(c) 缺少原因")
            XCTAssertFalse((c.recoverySuggestion ?? "").isEmpty, "\(c) 缺少建议")
        }
    }

    func testImportErrorSuggestionsPointToActionableFixes() {
        XCTAssertTrue(
            PrivateKeyImportError.malformedPEM(reason: "x").recoverySuggestion?.contains(".pub") == true
        )
        XCTAssertTrue(
            PrivateKeyImportError.malformedPEM(reason: "x")
                .recoverySuggestion?.contains("一次只导入一把私钥") == true
        )
        XCTAssertTrue(
            PrivateKeyImportError.encryptedKeyNeedsPassphrase
                .recoverySuggestion?.contains("不是服务器登录密码") == true
        )
        XCTAssertTrue(
            PrivateKeyImportError.incorrectPassphrase
                .recoverySuggestion?.contains("ssh-keygen") == true
        )
    }

    func testFormattedMessageIncludesReasonAndSuggestion() {
        let message = KeyImportErrorMessage.message(
            for: PrivateKeyImportError.unsupportedFormat(label: "OPENSSH sk-ecdsa-sha2-nistp256@openssh.com"),
            fallback: "无法识别该私钥"
        )

        XCTAssertTrue(message.contains("不支持的私钥格式"))
        XCTAssertTrue(message.contains("原因：检测到 OPENSSH sk-ecdsa-sha2-nistp256@openssh.com"))
        XCTAssertTrue(message.contains("建议：如果这是公钥或证书"))
    }

    func testFormattedNSErrorIncludesReasonAndSuggestion() {
        let message = KeyImportErrorMessage.message(
            for: NSError(domain: "uTerm.keys", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "无法读取私钥文件",
                NSLocalizedFailureReasonErrorKey: "没有读取权限",
                NSLocalizedRecoverySuggestionErrorKey: "请检查文件权限",
            ]),
            fallback: "导入失败"
        )

        XCTAssertTrue(message.contains("无法读取私钥文件"))
        XCTAssertTrue(message.contains("原因：没有读取权限"))
        XCTAssertTrue(message.contains("建议：请检查文件权限"))
    }

    func testEquatableIgnoresAssociatedText() {
        XCTAssertEqual(PrivateKeyImportError.malformedPEM(reason: "a"),
                       PrivateKeyImportError.malformedPEM(reason: "b"))
        XCTAssertNotEqual(PrivateKeyImportError.dsaUnsupported,
                          PrivateKeyImportError.incorrectPassphrase)
    }
}
