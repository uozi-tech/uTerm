import CryptoKit
import SwiftData
import XCTest
@testable import uTerm

/// `relay-import` / `relay-check`。SFTP 是内存替身，中继配置存在内存里：不碰钥匙串、不碰正式版的设置。
@MainActor
final class ControlRelayHandlerTests: XCTestCase {

    private actor FakePool: ControlConnectionPooling {
        private let session: any SFTPProviding
        private var failure: Error?
        init(session: any SFTPProviding) { self.session = session }
        func failNext(_ error: Error) { failure = error }
        func executor(for host: HostConnectionSpec, maxLines: Int, maxBytes: Int) async throws -> SSHCommandExecutor {
            throw ControlConnectError.connectFailed("测试替身不提供 exec 通道")
        }
        func borrowSFTP(for host: HostConnectionSpec) async throws -> any SFTPProviding {
            if let failure { throw failure }
            return session
        }
        func returnSFTP(_ session: any SFTPProviding, for hostID: UUID) async {}
        func disconnect(hostID: UUID) async {}
        func disconnectAll() async {}
        func heldHostIDs() async -> [UUID] { [] }
        func lastHostKeyChallenge(hostID: UUID) async -> HostKeyChallenge? { nil }
        func recordChallenge(hostID: UUID, _ challenge: HostKeyChallenge) async {}
        func trustHostKey(host: HostConnectionSpec, fingerprint: String) async throws {}
    }

    private final class FakeRelay: ControlRelayManaging {
        var stored: RemoteRelayConfig?
        var saveFails = false
        let relayUpdates = RemoteRelayUpdateMonitor.inert()
        let relayManagedHosts: RemoteRelayManagedHosts
        var isRelayLinkActive = false
        var isRelayRegistered = false

        init(defaults: UserDefaults) { relayManagedHosts = RemoteRelayManagedHosts(defaults: defaults) }

        func loadRelayConfig() -> RemoteRelayConfig? { stored }
        func importRelayConfig(_ config: RemoteRelayConfig) -> Bool {
            guard !saveFails else { return false }
            stored = config
            return true
        }
    }

    private struct StubKeychain: KeychainReading {
        func load(profileID: UUID, kind: SecretKind) throws -> String? { kind == .password ? "pw" : nil }
    }

    private var container: ModelContainer!
    private var settings: ControlSettings!
    private var sftp: MockSFTP!
    private var pool: FakePool!
    private var relay: FakeRelay!
    private var handler: ControlHandler!
    private var profile: ServerProfile!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        profile = ServerProfile()
        profile.name = "relay-box"
        profile.host = "192.0.2.20"   // TEST-NET-1：绝不真正连接
        profile.username = "deploy"
        container.mainContext.insert(profile)
        try container.mainContext.save()

        let suite = "ControlRelayHandlerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        settings = ControlSettings(defaults: defaults)
        settings.isEnabled = true
        settings.allowMutations = true
        sftp = MockSFTP()
        pool = FakePool(session: sftp)
        relay = FakeRelay(defaults: defaults)
        handler = ControlHandler(settings: settings, modelContainer: container,
                                 forwardingCoordinator: ForwardingCoordinator(), pool: pool,
                                 registry: TerminalSessionRegistry(), relay: relay)
        HostConnectionSpec.keychainOverride = StubKeychain()
    }

    override func tearDown() async throws {
        HostConnectionSpec.keychainOverride = nil
        handler = nil
        try await super.tearDown()
    }

    private static func config(name: String = "home", relayID: String = "be7ee457a6407b1a") -> RemoteRelayConfig {
        RemoteRelayConfig(name: name, host: "relay.example.com", port: 47310, relayID: relayID,
                          key: P256.Signing.PrivateKey().rawRepresentation.base64EncodedString())
    }

    private func seed(_ config: RemoteRelayConfig, at path: String = RemoteRelayRelease.clientConfigPath) async throws {
        await sftp.setFile(path, data: try JSONEncoder().encode(config), mtime: Date())
    }

    // MARK: - relay-import

    func testImportReadsTheInstallerFileAndNeverEchoesTheKey() async throws {
        let config = Self.config()
        try await seed(config)

        let response = await handler.handle(ControlRequest(id: "t", action: .relayImport, host: "relay-box"))

        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(relay.stored, config)
        XCTAssertEqual(response.relay?.relayID, config.relayID)
        XCTAssertEqual(response.relay?.endpoint, "relay.example.com:47310")
        XCTAssertEqual(response.relay?.managedHost, "relay-box")
        XCTAssertEqual(relay.relayManagedHosts.host(for: config.relayID), profile.id)
        let wire = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        XCTAssertFalse(wire.contains(config.key), "响应里不能出现成员密钥")
        XCTAssertFalse(wire.contains(try XCTUnwrap(config.url).absoluteString))
        let reads = await sftp.boundedDownloads
        XCTAssertEqual(reads.map(\.path), [RemoteRelayRelease.clientConfigPath])
    }

    func testImportAcceptsATildePath() async throws {
        let config = Self.config()
        try await seed(config, at: "conf/relay.json")
        let response = await handler.handle(ControlRequest(action: .relayImport, host: "relay-box", path: "~/conf/relay.json"))
        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(ControlHandler.relayConfigPath("~/a/b"), "a/b")
        XCTAssertEqual(ControlHandler.relayConfigPath(nil), RemoteRelayRelease.clientConfigPath)
        XCTAssertEqual(ControlHandler.relayConfigPath("/root/x.json"), "/root/x.json")
    }

    func testImportRefusesToReplaceAnotherRelayWithoutForce() async throws {
        relay.stored = Self.config(name: "old", relayID: "1111111111111111")
        let fresh = Self.config(name: "new", relayID: "2222222222222222")
        try await seed(fresh)

        let refused = await handler.handle(ControlRequest(action: .relayImport, host: "relay-box"))
        XCTAssertEqual(refused.code, ControlErrorCode.relay_exists.rawValue)
        XCTAssertTrue(refused.message.contains("old"), refused.message)
        XCTAssertEqual(relay.stored?.relayID, "1111111111111111")

        let replaced = await handler.handle(ControlRequest(action: .relayImport, host: "relay-box", force: true))
        XCTAssertTrue(replaced.ok, replaced.message)
        XCTAssertEqual(relay.stored, fresh)
    }

    func testReimportingTheSameRelayNeedsNoForce() async throws {
        let config = Self.config()
        relay.stored = config
        try await seed(config)
        let response = await handler.handle(ControlRequest(action: .relayImport, host: "relay-box"))
        XCTAssertTrue(response.ok, response.message)
    }

    func testImportRejectsAFileThatIsNotARelayConfig() async throws {
        await sftp.setFile(RemoteRelayRelease.clientConfigPath, data: Data(#"{"hello":"world"}"#.utf8), mtime: Date())
        let response = await handler.handle(ControlRequest(action: .relayImport, host: "relay-box"))
        XCTAssertEqual(response.code, ControlErrorCode.relay_config_invalid.rawValue)
        XCTAssertNil(relay.stored)
    }

    func testImportExplainsAMissingFile() async {
        let response = await handler.handle(ControlRequest(action: .relayImport, host: "relay-box"))
        XCTAssertEqual(response.code, ControlErrorCode.file_not_found.rawValue)
        XCTAssertTrue(response.message.contains("install"), response.message)
    }

    func testImportNeedsTheMutationSwitch() async throws {
        settings.allowMutations = false
        try await seed(Self.config())
        let response = await handler.handle(ControlRequest(action: .relayImport, host: "relay-box"))
        XCTAssertEqual(response.code, ControlErrorCode.mutations_disabled.rawValue)
        XCTAssertNil(relay.stored)
    }

    func testImportNeedsAHost() async {
        let response = await handler.handle(ControlRequest(action: .relayImport))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    func testImportReportsAKeychainFailure() async throws {
        relay.saveFails = true
        try await seed(Self.config())
        let response = await handler.handle(ControlRequest(action: .relayImport, host: "relay-box"))
        XCTAssertEqual(response.code, ControlErrorCode.operation_failed.rawValue)
    }

    // MARK: - relay-install-command

    func testInstallCommandQuotesEveryArgument() async throws {
        try XCTSkipUnless(RemoteRelayRelease.isAvailable, "这个构建没有配置中继发布地址")
        let script = try XCTUnwrap(RemoteRelayRelease.installScriptURL).absoluteString
        var request = ControlRequest(action: .relayInstallCommand)
        request.args = ["install", "--public-host", "relay.example.com", "--name", "家里 it's"]
        let response = await handler.handle(request)
        XCTAssertTrue(response.ok, response.message)
        XCTAssertTrue(response.message.contains("curl -fsSL \(script) | $S sh -s -- "), response.message)
        XCTAssertTrue(response.message.hasSuffix("'install' '--public-host' 'relay.example.com' '--name' '家里 it'\\''s'"),
                      response.message)

        request.args = ["update"]
        request.mode = "interactive"
        let interactive = await handler.handle(request)
        XCTAssertEqual(interactive.message, "curl -fsSL \(script) | sudo sh -s -- 'update'")
        XCTAssertFalse(ControlAction.relayInstallCommand.requiresMutation, "只拼命令，不动任何东西")
    }

    // MARK: - relay-check

    func testCheckWithoutAConfigSaysSo() async {
        let response = await handler.handle(ControlRequest(action: .relayCheck))
        XCTAssertEqual(response.code, ControlErrorCode.relay_not_configured.rawValue)
    }

    func testCheckOnlyNeedsTheMainSwitch() {
        XCTAssertFalse(ControlAction.relayCheck.requiresMutation)
        XCTAssertTrue(ControlAction.relayImport.requiresMutation)
        XCTAssertFalse(ControlAction.relayImport.requiresExecCapableHost, "装中继的主机可以是只传文件的")
    }

    func testCheckSummaryListsEveryStepAndProblem() {
        let result = RemoteRelayCheckResult(tcp: .ok, auth: .ok, udp: .failed, rttMs: 42, serverVersion: "1.1.0",
                                            onlineHosts: 1, mappedAddress: nil, problems: ["UDP 不通的原因"])
        let summary = ControlHandler.checkSummary(result)
        XCTAssertTrue(summary.hasPrefix("TCP 通 · 认证 通 · UDP 不通 · 往返 42 ms · 中继 1.1.0"), summary)
        XCTAssertTrue(summary.contains("UDP 不通的原因"))
        XCTAssertTrue(result.isUsable, "UDP 不通只影响打洞，中继仍可用")
    }
}
