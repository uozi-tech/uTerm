import XCTest
@testable import uTerm
@testable import USSHKit

/// `KeyGeneration`（两端共用的「生成新密钥」核心）的测试。钥匙串用独立测试 service，tearDown 清理。
@MainActor
final class KeyGenerationTests: XCTestCase {
    private let keychain = KeychainStore(service: "com.uozi.uTerm.tests.keygeneration")
    private var createdIDs: [UUID] = []
    private var keyStore: KeyStore { KeyStore(keychain: keychain) }

    override func tearDown() {
        for id in createdIDs {
            try? keychain.delete(profileID: id, kind: .privateKey)
            try? keychain.delete(profileID: id, kind: .passphrase)
        }
        createdIDs = []
        super.tearDown()
    }

    private func generate(_ kind: SSHKeyKind, bits: Int = 2048,
                          name: String = "k", comment: String = "c") async -> Result<SSHKey, KeyGeneration.Failure> {
        let result = await KeyGeneration.run(kind: kind, bits: bits, name: name, comment: comment, keyStore: keyStore)
        if case .success(let key) = result { createdIDs.append(key.id) }
        return result
    }

    func testEd25519FillsMetadataAndStoresPrivateKey() async throws {
        let result = await generate(.ed25519, name: "  default \n", comment: " me@mac ")
        let key = try result.get()
        XCTAssertEqual(key.name, "default")
        XCTAssertEqual(key.comment, "me@mac")
        XCTAssertEqual(key.type, .ed25519)
        XCTAssertEqual(key.bits, 256)
        XCTAssertFalse(key.hasPassphrase)
        XCTAssertFalse(key.fingerprint.isEmpty)
        XCTAssertTrue(key.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(key.publicKey.hasSuffix(" me@mac"))
        let stored = try keyStore.privateKey(keyID: key.id)
        XCTAssertNotNil(stored)
        XCTAssertTrue(stored?.contains("PRIVATE KEY") ?? false)
        XCTAssertNil(try keyStore.passphrase(keyID: key.id))
    }

    func testRSAUsesChosenBits() async throws {
        let key = try await generate(.rsa, bits: 2048).get()
        XCTAssertEqual(key.type, .rsa)
        XCTAssertEqual(key.bits, 2048)
        XCTAssertTrue(key.publicKey.hasPrefix("ssh-rsa "))
    }

    func testECDSAP384BitsComeFromCurve() async throws {
        let key = try await generate(.ecdsaP384, bits: 4096).get()
        XCTAssertEqual(key.type, .ecdsaP384)
        XCTAssertEqual(key.bits, 384)
        XCTAssertTrue(key.publicKey.hasPrefix("ecdsa-sha2-nistp384 "))
    }

    func testKeyBitsMapping() {
        XCTAssertEqual(KeyGeneration.keyBits(kind: .ed25519, rsaBits: 4096), 256)
        XCTAssertEqual(KeyGeneration.keyBits(kind: .rsa, rsaBits: 3072), 3072)
        XCTAssertEqual(KeyGeneration.keyBits(kind: .ecdsaP256, rsaBits: 4096), 256)
        XCTAssertEqual(KeyGeneration.keyBits(kind: .ecdsaP384, rsaBits: 4096), 384)
        XCTAssertEqual(KeyGeneration.keyBits(kind: .ecdsaP521, rsaBits: 4096), 521)
    }

    func testEmptyNameFails() async {
        let result = await generate(.ed25519, name: "  \n ")
        guard case .failure(.failed) = result else {
            return XCTFail("空名称应失败，实际 \(result)")
        }
    }

    /// 生成期间任务被取消：返回 `.cancelled`，钥匙串里不留私钥。
    func testCancelledTaskDoesNotStoreKey() async throws {
        let store = keyStore
        // `SSHKey` 不是 Sendable，任务只交回可跨隔离的摘要。
        let task = Task { @MainActor () -> (failure: KeyGeneration.Failure?, keyID: UUID?) in
            switch await KeyGeneration.run(kind: .ed25519, bits: 0, name: "k", comment: "", keyStore: store) {
            case .success(let key): return (nil, key.id)
            case .failure(let failure): return (failure, nil)
            }
        }
        task.cancel()
        let outcome = await task.value
        if let id = outcome.keyID {
            createdIDs.append(id)
            XCTFail("取消后不应交回密钥")
        }
        XCTAssertEqual(outcome.failure, .cancelled)
    }

    func testMessagePrefersLocalizedErrorDescription() {
        struct Described: LocalizedError { var errorDescription: String? { "钥匙串被锁" } }
        XCTAssertEqual(KeyGeneration.message(for: Described()), "生成失败：钥匙串被锁")
    }
}
