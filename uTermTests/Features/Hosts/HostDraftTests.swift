import XCTest
import SwiftData
@testable import uTerm

/// `HostDraft`（两端共用的主机表单草稿）：新建、编辑只写改动字段、复制、切换认证方式、
/// 跳板机不变、空密码不写钥匙串。内存容器（`cloudKitDatabase: .none`）+ 独立测试钥匙串。
@MainActor
final class HostDraftTests: XCTestCase {
    private let keychain = KeychainStore(service: "com.uozi.uTerm.tests.hostdraft")
    private var touchedIDs: [UUID] = []

    override func tearDown() async throws {
        for id in touchedIDs {
            for kind in [SecretKind.password, .passphrase, .privateKey] {
                try? keychain.delete(profileID: id, kind: kind)
            }
        }
        touchedIDs = []
        try await super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ServerProfile.self, ServerGroup.self, configurations: config)
        return ModelContext(container)
    }

    private func insertHost(_ name: String, in context: ModelContext) -> ServerProfile {
        let p = ServerProfile()
        p.name = name
        p.host = "\(name).example"
        p.username = "root"
        context.insert(p)
        touchedIDs.append(p.id)
        return p
    }

    private func validDraft() -> HostDraft {
        var d = HostDraft()
        d.name = "  web  "
        d.host = " web.example "
        d.port = "2222"
        d.username = "deploy"
        d.group = " prod "
        d.password = "pw"
        return d
    }

    // MARK: 新建

    func testCreateInsertsNormalizedProfileGroupRowAndPassword() throws {
        let context = try makeContext()
        insertHost("existing", in: context).sortOrder = 4
        try context.save()

        let saved = try XCTUnwrap(validDraft().save(original: nil, to: nil, context: context, keychain: keychain))
        touchedIDs.append(saved.id)

        XCTAssertEqual(saved.name, "web")
        XCTAssertEqual(saved.host, "web.example")
        XCTAssertEqual(saved.port, 2222)
        XCTAssertEqual(saved.username, "deploy")
        XCTAssertEqual(saved.group, "prod")
        XCTAssertEqual(saved.authMethod, .password)
        XCTAssertNil(saved.keyID)
        XCTAssertEqual(saved.sortOrder, 5)
        XCTAssertNotNil(saved.modelContext)
        let groups = try context.fetch(FetchDescriptor<ServerGroup>()).map(\.name)
        XCTAssertEqual(groups, ["prod"], "新分组名要补建 ServerGroup 行")
        XCTAssertEqual(try keychain.load(profileID: saved.id, kind: .password), "pw")
    }

    func testEmptyPasswordIsNotWrittenToKeychain() throws {
        let context = try makeContext()
        var d = validDraft()
        d.password = ""
        let saved = try XCTUnwrap(d.save(original: nil, to: nil, context: context, keychain: keychain))
        touchedIDs.append(saved.id)
        XCTAssertNil(try keychain.load(profileID: saved.id, kind: .password))
    }

    // MARK: 编辑

    func testEditWritesOnlyChangedFields() throws {
        let context = try makeContext()
        let host = insertHost("api", in: context)
        host.group = "prod"
        try context.save()
        try keychain.save("old-pw", profileID: host.id, kind: .password)

        let original = HostDraft(from: host, keychain: keychain)
        XCTAssertEqual(original.password, "old-pw")
        var edited = original
        edited.name = "api-2"

        // 表单开着期间同步改了分组与端口：没改过的字段不能被写回旧值。
        host.group = "staging"
        host.port = 2200

        edited.save(original: original, to: host, context: context, keychain: keychain)

        XCTAssertEqual(host.name, "api-2")
        XCTAssertEqual(host.group, "staging")
        XCTAssertEqual(host.port, 2200)
        XCTAssertEqual(try keychain.load(profileID: host.id, kind: .password), "old-pw")
    }

    func testEditChangedPasswordIsWritten() throws {
        let context = try makeContext()
        let host = insertHost("api", in: context)
        try context.save()
        let original = HostDraft(from: host, keychain: keychain)
        var edited = original
        edited.password = "new-pw"
        edited.save(original: original, to: host, context: context, keychain: keychain)
        XCTAssertEqual(try keychain.load(profileID: host.id, kind: .password), "new-pw")
    }

    func testEditOfDeletedHostWritesNothing() throws {
        let context = try makeContext()
        let host = insertHost("gone", in: context)
        try context.save()
        let original = HostDraft(from: host, keychain: keychain)
        var edited = original
        edited.password = "pw"
        context.delete(host)
        try context.save()

        XCTAssertNil(edited.save(original: original, to: host, context: context, keychain: keychain))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ServerProfile>()), 0)
        XCTAssertNil(try keychain.load(profileID: host.id, kind: .password))
    }

    // MARK: 认证方式

    func testSwitchToPrivateKeyDeletesPasswordAndSetsKey() throws {
        let context = try makeContext()
        let host = insertHost("api", in: context)
        try context.save()
        try keychain.save("old-pw", profileID: host.id, kind: .password)
        let original = HostDraft(from: host, keychain: keychain)
        var edited = original
        let keyID = UUID()
        edited.auth = .privateKey
        edited.keyID = keyID

        edited.save(original: original, to: host, context: context, keychain: keychain)

        XCTAssertEqual(host.authMethod, .privateKey)
        XCTAssertEqual(host.keyID, keyID)
        XCTAssertNil(try keychain.load(profileID: host.id, kind: .password))
    }

    func testSwitchBackToPasswordClearsKeyID() throws {
        let context = try makeContext()
        let host = insertHost("api", in: context)
        host.authMethod = .privateKey
        host.keyID = UUID()
        try context.save()
        let original = HostDraft(from: host, keychain: keychain)
        var edited = original
        edited.auth = .password
        edited.password = "pw"

        edited.save(original: original, to: host, context: context, keychain: keychain)

        XCTAssertEqual(host.authMethod, .password)
        XCTAssertNil(host.keyID)
        XCTAssertEqual(try keychain.load(profileID: host.id, kind: .password), "pw")
    }

    // MARK: 跳板机

    func testJumpHostUntouchedWhenDraftDoesNotChangeIt() throws {
        let context = try makeContext()
        let bastion = insertHost("bastion", in: context)
        let host = insertHost("inner", in: context)
        host.jumpHost = bastion
        try context.save()
        let original = HostDraft(from: host, keychain: keychain)
        XCTAssertTrue(original.useJumpHost)
        XCTAssertEqual(original.jumpHostID, bastion.id)
        var edited = original
        edited.name = "inner-2"

        edited.save(original: original, to: host, context: context, keychain: keychain)

        XCTAssertEqual(host.jumpHost?.id, bastion.id)
    }

    func testJumpHostSetAndCleared() throws {
        let context = try makeContext()
        let bastion = insertHost("bastion", in: context)
        let host = insertHost("inner", in: context)
        try context.save()
        let original = HostDraft(from: host, keychain: keychain)
        var edited = original
        edited.useJumpHost = true
        edited.jumpHostID = bastion.id
        edited.save(original: original, to: host, context: context, keychain: keychain)
        XCTAssertEqual(host.jumpHost?.id, bastion.id)

        let second = HostDraft(from: host, keychain: keychain)
        var off = second
        off.useJumpHost = false
        off.save(original: second, to: host, context: context, keychain: keychain)
        XCTAssertNil(host.jumpHost)
    }

    // MARK: 复制

    func testDuplicateSavesAsNewProfileWithSuffix() throws {
        let context = try makeContext()
        let bastion = insertHost("bastion", in: context)
        let source = insertHost("api", in: context)
        source.jumpHost = bastion
        source.group = "prod"
        try context.save()
        try keychain.save("src-pw", profileID: source.id, kind: .password)

        let draft = HostDraft(duplicating: source, keychain: keychain)
        XCTAssertEqual(draft.name, "api 副本")
        let copy = try XCTUnwrap(draft.save(original: nil, to: nil, context: context, keychain: keychain))
        touchedIDs.append(copy.id)

        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.name, "api 副本")
        XCTAssertEqual(copy.host, source.host)
        XCTAssertEqual(copy.group, "prod")
        XCTAssertEqual(copy.jumpHost?.id, bastion.id)
        XCTAssertEqual(try keychain.load(profileID: copy.id, kind: .password), "src-pw")
        XCTAssertEqual(source.name, "api")
        XCTAssertEqual(HostDraft.duplicateName(of: "  "), "副本")
    }

    // MARK: 校验

    func testValidation() {
        var d = validDraft()
        XCTAssertTrue(d.isValid)
        d.port = ""
        XCTAssertNil(d.portError)
        XCTAssertEqual(d.portValue, 22)
        XCTAssertTrue(d.isValid)
        d.port = "abc"
        XCTAssertEqual(d.portError, "端口必须是数字")
        XCTAssertFalse(d.isValid)
        d.port = "0"
        XCTAssertEqual(d.portError, "端口需在 1–65535 之间")
        d.port = "65536"
        XCTAssertFalse(d.isValid)
        d.port = "65535"
        XCTAssertTrue(d.isValid)

        d.auth = .privateKey
        XCTAssertFalse(d.isValid, "私钥认证必须选密钥")
        d.keyID = UUID()
        XCTAssertTrue(d.isValid)

        d.useJumpHost = true
        XCTAssertFalse(d.isValid, "开了跳板机必须选一台")
        d.jumpHostID = UUID()
        XCTAssertTrue(d.isValid)

        d.name = "  "
        XCTAssertFalse(d.isValid)
    }
}
