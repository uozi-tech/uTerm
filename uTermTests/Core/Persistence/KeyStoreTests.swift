import XCTest
@testable import uTerm

/// `KeyStore` 的私钥 / 口令存取层测试。复用 KeychainStoreTests 的约定：用独立测试
/// service 的钥匙串，tearDown 清理，避免污染用户真实钥匙串。
final class KeyStoreTests: XCTestCase {
    private let keychain = KeychainStore(service: "com.uozi.uTerm.tests.keystore")
    private let keyID = UUID()
    private var store: KeyStore { KeyStore(keychain: keychain) }

    override func tearDown() {
        try? keychain.delete(profileID: keyID, kind: .privateKey)
        try? keychain.delete(profileID: keyID, kind: .passphrase)
        super.tearDown()
    }

    func testSaveAndReadPrivateKey() throws {
        try store.save(keyID: keyID, privateKey: "PEM-BODY", passphrase: nil)
        XCTAssertEqual(try store.privateKey(keyID: keyID), "PEM-BODY")
    }

    func testSaveAndReadPassphrase() throws {
        try store.save(keyID: keyID, privateKey: "PEM-BODY", passphrase: "kp")
        XCTAssertEqual(try store.passphrase(keyID: keyID), "kp")
    }

    /// Fix #15：找不到条目返回 nil（沿用 `KeychainStore.load` 的 not-found→nil 语义），
    /// 而不是把 not-found 与真实钥匙串错误混为一谈。
    func testPrivateKeyNotFoundReturnsNil() throws {
        XCTAssertNil(try store.privateKey(keyID: keyID))
    }

    func testPassphraseNotFoundReturnsNil() throws {
        // 存了私钥但没存口令：口令应为 nil（not-found），不抛错。
        try store.save(keyID: keyID, privateKey: "PEM-BODY", passphrase: nil)
        XCTAssertNil(try store.passphrase(keyID: keyID))
    }

    func testDeleteRemovesBoth() throws {
        try store.save(keyID: keyID, privateKey: "PEM-BODY", passphrase: "kp")
        store.delete(keyID: keyID)
        XCTAssertNil(try store.privateKey(keyID: keyID))
        XCTAssertNil(try store.passphrase(keyID: keyID))
    }

    func testKeyManagerRowsDoNotDeclareKeyboardFocusRing() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Keys/Views/KeyManagerView.swift"
        ), encoding: .utf8)

        XCTAssertFalse(source.contains(".focusable("))
        XCTAssertFalse(source.contains(".focusEffectDisabled("))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
