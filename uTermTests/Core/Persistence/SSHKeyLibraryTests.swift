import XCTest
import SwiftData
@testable import uTerm

/// `SSHKeyLibrary`：删除密钥连带清钥匙串 + 解绑主机；「在用主机」统计。内存容器、独立测试钥匙串。
@MainActor
final class SSHKeyLibraryTests: XCTestCase {
    private let keychain = KeychainStore(service: "com.uozi.uTerm.tests.sshkeylibrary")
    private var keyStore: KeyStore { KeyStore(keychain: keychain) }
    private var keyIDs: [UUID] = []

    override func tearDown() {
        for id in keyIDs { keyStore.delete(keyID: id) }
        keyIDs = []
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ServerProfile.self, SSHKey.self, configurations: config)
        return ModelContext(container)
    }

    private func makeKey(_ name: String, in context: ModelContext) -> SSHKey {
        let key = SSHKey()
        key.name = name
        context.insert(key)
        keyIDs.append(key.id)
        return key
    }

    private func makeHost(_ name: String, keyID: UUID?, in context: ModelContext) -> ServerProfile {
        let host = ServerProfile()
        host.name = name
        host.host = "\(name).example"
        host.username = "root"
        host.authMethod = .privateKey
        host.keyID = keyID
        context.insert(host)
        return host
    }

    func testDeleteClearsKeychainUnbindsHostsAndRemovesRow() throws {
        let context = try makeContext()
        let doomed = makeKey("doomed", in: context)
        let kept = makeKey("kept", in: context)
        let a = makeHost("a", keyID: doomed.id, in: context)
        let b = makeHost("b", keyID: doomed.id, in: context)
        let c = makeHost("c", keyID: kept.id, in: context)
        try context.save()
        try keyStore.save(keyID: doomed.id, privateKey: "PEM", passphrase: "pp")
        let doomedID = doomed.id

        SSHKeyLibrary(context: context, keyStore: keyStore).delete(doomed)

        XCTAssertNil(a.keyID)
        XCTAssertNil(b.keyID)
        XCTAssertEqual(c.keyID, kept.id)
        let remaining = try context.fetch(FetchDescriptor<SSHKey>())
        XCTAssertEqual(remaining.map(\.name), ["kept"])
        XCTAssertNil(try keyStore.privateKey(keyID: doomedID))
        XCTAssertNil(try keyStore.passphrase(keyID: doomedID))
        XCTAssertFalse(context.hasChanges, "删除后应已 save")
    }

    func testUsageCountsAndUsers() throws {
        let context = try makeContext()
        let k1 = makeKey("k1", in: context)
        let k2 = makeKey("k2", in: context)
        let hosts = [
            makeHost("a", keyID: k1.id, in: context),
            makeHost("b", keyID: k1.id, in: context),
            makeHost("c", keyID: k2.id, in: context),
            makeHost("d", keyID: nil, in: context),
        ]

        let counts = SSHKeyLibrary.usageCounts(hosts)
        XCTAssertEqual(counts[k1.id], 2)
        XCTAssertEqual(counts[k2.id], 1)
        XCTAssertEqual(counts.count, 2)
        XCTAssertEqual(SSHKeyLibrary.users(of: k1, in: hosts).map(\.name), ["a", "b"])
        XCTAssertEqual(SSHKeyLibrary.users(of: k2, in: hosts).map(\.name), ["c"])
    }
}
