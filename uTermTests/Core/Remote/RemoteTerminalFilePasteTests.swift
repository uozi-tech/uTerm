import XCTest
@preconcurrency import Network
@testable import uTerm

/// 手机往远控 Mac 的终端里贴视频 / 文件：本机 shell 经文件通道传到那台 Mac 的临时目录（正式是 `/private/tmp`，
/// 测试宿主带沙盒，换成自己的临时目录），返回路径给手机粘进终端；Mac 上开着的 SSH 终端收不了。
///
/// 真实的加密链路走本机回环，被控端的文件服务直接调 `RemoteFileService`（辅助程序要真机）。
@MainActor
final class RemoteTerminalFilePasteTests: XCTestCase {

    private var root = ""

    override func setUp() async throws {
        try await super.setUp()
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        root = base.appendingPathComponent("remote-terminal-paste-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: root)
        try await super.tearDown()
    }

    func test_local_shell_receives_a_file_in_the_upload_directory() async throws {
        let rig = try await Rig.make(serverID: RemoteConstants.localShellServerID)
        defer { rig.stop() }
        let backend = RemoteTerminalBackend(client: rig.client, sessionID: rig.sessionID, uploadDirectory: root)
        XCTAssertFalse(backend.receivesFiles, "接上之前不知道是不是本机 shell")
        try await backend.connect()
        defer { Task { await backend.close() } }
        XCTAssertTrue(backend.receivesFiles)

        var bytes = [UInt8](repeating: 0, count: 300_000)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let local = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paste-\(UUID().uuidString).pdf")
        try Data(bytes).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let file = TerminalVideo(localURL: local, fileExtension: "pdf", size: Int64(bytes.count), kind: .file)

        let path = try await backend.deliverVideo(file)
        XCTAssertTrue(path.hasPrefix(root + "/uterm-file-"), path)
        XCTAssertTrue(path.hasSuffix(".pdf"), path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data(bytes))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "只给自己读写")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root).filter { $0.hasPrefix(".") }
        XCTAssertTrue(leftovers.isEmpty, "传完不留半截的临时文件：\(leftovers)")
    }

    func test_ssh_terminal_on_the_mac_refuses_files() async throws {
        let rig = try await Rig.make(serverID: UUID())
        defer { rig.stop() }
        let backend = RemoteTerminalBackend(client: rig.client, sessionID: rig.sessionID, uploadDirectory: root)
        try await backend.connect()
        defer { Task { await backend.close() } }
        XCTAssertFalse(backend.receivesFiles)

        let local = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("paste-\(UUID().uuidString).mov")
        try Data([1, 2, 3]).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        do {
            _ = try await backend.deliverVideo(TerminalVideo(localURL: local, fileExtension: "mov", size: 3))
            XCTFail("应当拒绝")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("SSH"), error.localizedDescription)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root), [])
    }

    // MARK: - 夹具

    /// 起服务端 + 配对好的手机客户端，Mac 上登记一个假后端驱动的终端。
    @MainActor
    private struct Rig {
        let server: RemoteHostServer
        let client: RemoteMacClient
        let session: TerminalSession
        let sessionID: UUID

        func stop() {
            server.stop()
            session.dispose()
        }

        static func make(serverID: UUID) async throws -> Rig {
            let registry = TerminalSessionRegistry()
            let session = TerminalSession()
            await session.connect(using: MockBackend())
            let sessionID = UUID()
            registry.register(TerminalSessionEntry(id: sessionID, serverID: serverID, serverName: "Mac",
                                                   windowKind: TerminalWindowKind.terminal, title: "zsh",
                                                   connectedAt: Date()), session: session)
            let server = RemoteHostServer(registry: registry,
                                          identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                          localName: "测试 Mac", localID: UUID(), advertises: false,
                                          localFeatures: RemoteConstants.localFeatures)
            server.fileAccess = RemoteFileAccess(refusal: { _ in nil },
                                                 perform: { payload in RemoteFileService.handle(payload) })
            server.start()
            _ = await waitUntil { server.port != nil }
            let port = try XCTUnwrap(server.port)
            let client = RemoteMacClient(macName: "测试 Mac",
                                         endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                         identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
            let connecting = Task { await client.connect() }
            _ = await waitUntil { !server.pairingRequests.isEmpty }
            server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
            await connecting.value
            XCTAssertEqual(client.state, .connected)
            let listed = await waitUntil { client.sessions.contains { $0.id == sessionID } }
            XCTAssertTrue(listed)
            return Rig(server: server, client: client, session: session, sessionID: sessionID)
        }

        private static func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !(await condition()) {
                if Date() > deadline { return false }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return true
        }
    }
}
