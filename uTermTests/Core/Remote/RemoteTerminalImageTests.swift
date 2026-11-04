import XCTest
@preconcurrency import Network
@testable import uTerm

/// 手机往远控终端里贴图片：手机发 `terminalImage` → Mac 交给该会话的后端（本机 shell 走剪贴板、SSH 传文件）
/// → 回 `terminalImageResult`。后端换成假的；真实的 SFTP 上传与剪贴板写入不在这里。
@MainActor
final class RemoteTerminalImageTests: XCTestCase {

    /// 能收图片的假后端：记下收到的图片，按 `reply` 回结果。
    private actor ImageBackend: TerminalImageReceiving {
        nonisolated var programsCanReadMacClipboard: Bool { false }
        nonisolated let outputStream: AsyncStream<Data>
        nonisolated let exitStream: AsyncStream<Void>
        private(set) var received: [TerminalImage] = []
        let reply: Result<TerminalImageDelivery, TerminalImageError>

        init(reply: Result<TerminalImageDelivery, TerminalImageError>) {
            self.reply = reply
            outputStream = AsyncStream { _ in }
            exitStream = AsyncStream { _ in }
        }

        func connect() async throws {}
        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async {}

        func deliverImage(_ image: TerminalImage) async throws -> TerminalImageDelivery {
            received.append(image)
            return try reply.get()
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// 起服务端 + 配对好的手机客户端，Mac 上登记一条由 `backend` 驱动的会话，手机接入它。
    private func attached(to backend: any TerminalBackend, features: [String]? = nil)
        async throws -> (RemoteHostServer, RemoteTerminalBackend, TerminalSession) {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession()
        await session.connect(using: backend)
        let sessionID = UUID()
        registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "测试主机",
                                               windowKind: TerminalWindowKind.terminal, title: "bash",
                                               connectedAt: Date()), session: session)
        let server = RemoteHostServer(registry: registry, identity: RemoteIdentityStore(storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      localFeatures: features ?? RemoteConstants.localFeatures)
        server.start()
        _ = await waitUntil { server.port != nil }
        let port = try XCTUnwrap(server.port)
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(storage: RemoteMemoryStorage()))
        let connecting = Task { await client.connect() }
        _ = await waitUntil { !server.pairingRequests.isEmpty }
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
        let remote = RemoteTerminalBackend(client: client, sessionID: sessionID)
        try await remote.connect()
        return (server, remote, session)
    }

    private let png = TerminalImage(format: .png, data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]))

    func test_ssh_session_gets_the_image_as_a_file_and_the_phone_gets_the_path() async throws {
        let backend = ImageBackend(reply: .success(.file(path: "/tmp/uterm-image-x.png")))
        let (server, remote, session) = try await attached(to: backend)
        defer { server.stop(); session.dispose() }

        let delivery = try await remote.deliverImage(png)
        XCTAssertEqual(delivery, .file(path: "/tmp/uterm-image-x.png"))
        let received = await backend.received
        XCTAssertEqual(received, [png], "图片原样到了 Mac 上这个会话的后端")
    }

    func test_local_shell_reports_clipboard() async throws {
        let backend = ImageBackend(reply: .success(.clipboard))
        let (server, remote, session) = try await attached(to: backend)
        defer { server.stop(); session.dispose() }

        let delivery = try await remote.deliverImage(TerminalImage(format: .jpeg, data: Data([0xFF, 0xD8, 0xFF, 9])))
        XCTAssertEqual(delivery, .clipboard)
    }

    func test_backend_failure_reaches_the_phone_without_dropping_the_connection() async throws {
        let backend = ImageBackend(reply: .failure(.unsupported("磁盘满了")))
        let (server, remote, session) = try await attached(to: backend)
        defer { server.stop(); session.dispose() }

        do {
            _ = try await remote.deliverImage(png)
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("磁盘满了"), error.localizedDescription)
        }
        // 连接照常：还能再发一次（这次仍失败，但能拿到回复，说明没断）。
        do { _ = try await remote.deliverImage(png) } catch {}
        let count = await backend.received.count
        XCTAssertEqual(count, 2)
    }

    func test_backend_that_cannot_take_images_is_refused() async throws {
        let (server, remote, session) = try await attached(to: MockBackend())
        defer { server.stop(); session.dispose() }

        do {
            _ = try await remote.deliverImage(png)
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error.localizedDescription, "这个终端不能接收图片")
        }
    }

    func test_old_mac_without_the_feature_gets_nothing_sent() async throws {
        let backend = ImageBackend(reply: .success(.clipboard))
        let (server, remote, session) = try await attached(to: backend, features: [RemoteFeature.desktop])
        defer { server.stop(); session.dispose() }

        do {
            _ = try await remote.deliverImage(png)
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("版本太旧"), error.localizedDescription)
        }
        let count = await backend.received.count
        XCTAssertEqual(count, 0, "老 Mac 收到未知消息会断开整条连接，所以手机端根本不发")
    }

    func test_wire_shape() throws {
        // 线上编号一旦发布就不能改：老版本按编号认消息。
        XCTAssertEqual(RemoteMessage.Kind.terminalImage.rawValue, 9)
        XCTAssertEqual(RemoteMessage.Kind.terminalImageResult.rawValue, 29)
        XCTAssertEqual(RemoteFeature.terminalImage, "terminal-image")
        XCTAssertTrue(RemoteConstants.localFeatures.contains(RemoteFeature.terminalImage))

        let request = RemoteTerminalImageRequest(requestID: UUID(), image: png)
        XCTAssertEqual(try RemoteTerminalImageRequest(decoding: request.encoded()), request)
        XCTAssertThrowsError(try RemoteTerminalImageRequest(decoding: Data(repeating: 0, count: 17)), "没有图片字节")
        var badFormat = request.encoded()
        badFormat[16] = 9
        XCTAssertThrowsError(try RemoteTerminalImageRequest(decoding: badFormat), "不认得的格式")

        let result = RemoteTerminalImageResult(requestID: UUID(), path: "/tmp/a.png")
        XCTAssertEqual(try RemoteJSON.decode(RemoteTerminalImageResult.self, from: RemoteJSON.encode(result)), result)
    }

    func test_temporary_remote_path_needs_no_shell_quoting() {
        var components = DateComponents(year: 2026, month: 11, day: 3, hour: 15, minute: 30, second: 12)
        components.calendar = Calendar(identifier: .gregorian)
        let path = png.temporaryRemotePath(now: components.date!)
        XCTAssertTrue(path.hasPrefix("/tmp/uterm-image-20261103-153012-"), path)
        XCTAssertTrue(path.hasSuffix(".png"), path)
        XCTAssertNil(path.rangeOfCharacter(from: CharacterSet(charactersIn: " '\"\\$`")), path)
        XCTAssertTrue(TerminalImage(format: .jpeg, data: Data()).temporaryRemotePath().hasSuffix(".jpg"))
    }
}
