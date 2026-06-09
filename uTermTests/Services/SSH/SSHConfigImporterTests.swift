import XCTest
import SwiftData
@testable import uTerm

@MainActor
final class SSHConfigImporterTests: XCTestCase {

    private func host(_ alias: String, wildcard: Bool = false) -> ParsedSSHHost {
        ParsedSSHHost(alias: alias, hostName: "h", user: "u", port: 22,
                      identityFile: nil, isWildcard: wildcard)
    }

    func testPlanMarksExisting() {
        let rows = SSHConfigImporter.plan(
            [host("web"), host("db")], existingNames: ["db"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.host.alias), ["web", "db"])
        XCTAssertFalse(rows[0].existing)
        XCTAssertTrue(rows[1].existing)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)   // ids 唯一
    }

    func testPlanPassesWildcardThrough() {
        let rows = SSHConfigImporter.plan([host("*.lab", wildcard: true)], existingNames: [])
        XCTAssertTrue(rows[0].host.isWildcard)
        XCTAssertFalse(rows[0].existing)
    }

    func testImportReviewRowsDoNotDeclareKeyboardFocusRing() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Import/Views/SSHConfigImportView.swift"
        ), encoding: .utf8)

        XCTAssertFalse(source.contains(".focusable("))
        XCTAssertFalse(source.contains(".focusEffectDisabled("))
    }

    func testRunImportsQuotedIdentityFileFromSubdirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("uTerm-config-import-\(UUID().uuidString)", isDirectory: true)
        let sshDir = root.appendingPathComponent(".ssh", isDirectory: true)
        let keysDir = sshDir.appendingPathComponent("keys", isDirectory: true)
        try fileManager.createDirectory(at: keysDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let generated = SSHKeyGenerator.generateEd25519(comment: "config-import")
        let keyURL = keysDir.appendingPathComponent("app key")
        try generated.privateKeyText.write(to: keyURL, atomically: true, encoding: .utf8)

        let candidatePaths = SSHIdentityFileResolver.urls(
            for: "~/.ssh/keys/app key",
            configDir: sshDir
        ).map(\.path)
        XCTAssertTrue(
            candidatePaths.contains(keyURL.standardizedFileURL.path),
            candidatePaths.joined(separator: "\n")
        )

        let rows = SSHConfigImporter.plan(parseSSHConfig("""
        Host app
            HostName app.example.com
            User deploy
            IdentityFile "~/.ssh/keys/app key"
        """), existingNames: [])

        let context = try makeContext()
        let keyStore = MemoryConfigKeyStore()
        let parsed = try PrivateKeyImporter.resolve(pem: generated.privateKeyText, passphrase: nil)
        _ = try KeyImportInspector.inspect(rawText: generated.privateKeyText, parsed: parsed, comment: "")

        let result = SSHConfigImporter(context: context, keyStore: keyStore)
            .run(rows: rows, selected: Set(rows.map(\.id)), dir: sshDir)

        XCTAssertEqual(result.created, 1)
        XCTAssertEqual(result.updated, 0)
        XCTAssertEqual(result.keysImported, 1)
        XCTAssertEqual(result.keysSkipped, 0)

        let profile = try XCTUnwrap(context.fetch(FetchDescriptor<ServerProfile>()).first)
        XCTAssertEqual(profile.name, "app")
        XCTAssertEqual(profile.host, "app.example.com")
        XCTAssertEqual(profile.username, "deploy")
        XCTAssertEqual(profile.authMethod, .privateKey)
        let keyID = try XCTUnwrap(profile.keyID)

        let key = try XCTUnwrap(context.fetch(FetchDescriptor<SSHKey>()).first)
        XCTAssertEqual(key.id, keyID)
        XCTAssertEqual(key.name, "app key")
        XCTAssertEqual(key.publicKey, generated.publicKeyWithoutComment)
        XCTAssertEqual(keyStore.privateKeys[keyID], generated.privateKeyText)
    }

    func testRunLinksExistingKeyByIdentityFileName() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("uTerm-config-import-existing-\(UUID().uuidString)", isDirectory: true)
        let sshDir = root.appendingPathComponent(".ssh", isDirectory: true)
        try fileManager.createDirectory(at: sshDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let context = try makeContext()
        let existingKey = SSHKey()
        existingKey.name = "prod-key"
        existingKey.type = .ed25519
        existingKey.publicKey = "ssh-ed25519 AAAATEST"
        context.insert(existingKey)
        try context.save()

        let rows = SSHConfigImporter.plan(parseSSHConfig("""
        Host prod
            HostName prod.example.com
            IdentityFile ~/.ssh/prod-key.pem
        """), existingNames: [])

        let result = SSHConfigImporter(context: context, keyStore: MemoryConfigKeyStore())
            .run(rows: rows, selected: Set(rows.map(\.id)), dir: sshDir)

        XCTAssertEqual(result.created, 1)
        XCTAssertEqual(result.keysImported, 0)
        XCTAssertEqual(result.keysLinked, 1)
        XCTAssertEqual(result.keysSkipped, 0)

        let profiles = try context.fetch(FetchDescriptor<ServerProfile>())
        XCTAssertEqual(profiles.first?.keyID, existingKey.id)
        XCTAssertEqual(profiles.first?.authMethod, .privateKey)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ServerProfile.self, SSHKey.self, configurations: config)
        return ModelContext(container)
    }
}

private final class MemoryConfigKeyStore: SSHConfigKeyStoring {
    var privateKeys: [UUID: String] = [:]
    var passphrases: [UUID: String] = [:]

    func save(keyID: UUID, privateKey: String, passphrase: String?) throws {
        privateKeys[keyID] = privateKey
        if let passphrase, !passphrase.isEmpty {
            passphrases[keyID] = passphrase
        } else {
            passphrases.removeValue(forKey: keyID)
        }
    }
}

private extension SSHKeyGenerator.GeneratedKey {
    var publicKeyWithoutComment: String {
        publicKey.split(separator: " ").prefix(2).joined(separator: " ")
    }
}
