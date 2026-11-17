import AppKit
import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 远程桌面「Mac → 手机」剪贴板回传（回环）：真实的 `RemoteHostServer` / `RemoteDesktopStreamer` / 加密链路 /
/// 手机侧 `RemoteMacClient` + `RemoteDesktopSession`，只有 Mac 剪贴板换成 `FakeClipboard`（不碰 `NSPasteboard.general`）。
@MainActor
final class RemoteDesktopClipboardTests: XCTestCase {

    /// 比轮询间隔（0.5 s）多等两轮：这段时间里没来就是真的不发。
    private static let quietWait: Duration = .milliseconds(1_200)

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func makeServer(_ mac: FakeDesktopMac) async throws -> RemoteHostServer {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      desktopEnvironment: mac.environment())
        server.start()
        let ready = await waitUntil { server.port != nil }
        XCTAssertTrue(ready, "服务端没起来：\(server.status)")
        return server
    }

    /// 已被 Mac 信任、已连上的手机客户端（与 uTermMobile 同一份代码，握手带 `RemoteConstants.localFeatures`）。
    private func makeClient(_ server: RemoteHostServer) async throws -> RemoteMacClient {
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "测试 iPhone",
                                    publicKey: try identity.localIdentity().publicKey.rawRepresentation, pairedAt: Date()))
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(server.port))!),
                                     identity: identity)
        await client.connect()
        XCTAssertEqual(client.state, .connected)
        return client
    }

    /// 开一路桌面流，收集回传到手机的剪贴板。
    private func startSession(_ client: RemoteMacClient) async -> (RemoteDesktopSession, ClipboardInbox) {
        let session = RemoteDesktopSession(client: client, maxWidth: 1206, maxHeight: 2622)
        let inbox = ClipboardInbox()
        session.onClipboard = { inbox.add($0) }
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        return (session, inbox)
    }

    // MARK: - 回传

    func test_mac_copy_while_phone_controls_reaches_phone_except_its_own_paste() async throws {
        let mac = FakeDesktopMac()
        mac.clipboard.copy("开流前就在剪贴板里的")
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        XCTAssertTrue(client.macFeatures.contains(RemoteFeature.desktopClipboard))
        let (session, inbox) = await startSession(client)
        defer { session.stop() }

        // 有控制权但还没操作：只是在看，Mac 上的拷贝不回传。
        mac.clipboard.copy("还没操作时拷贝的")
        try await Task.sleep(for: Self.quietWait)
        XCTAssertEqual(inbox.all, [], "手机没操作过之前不回传")

        // 第一次操作之后开始看剪贴板；之前的内容不补发。
        session.send(.move(x: 0.5, y: 0.5))
        let moved = await waitUntil { mac.injector.all.count == 1 }
        XCTAssertTrue(moved)
        mac.clipboard.copy("hello 你好 🙂")
        let copied = await waitUntil { inbox.all == [.text("hello 你好 🙂")] }
        XCTAssertTrue(copied, "\(inbox.all)")

        // 拷贝了图片：先只做文字，不发。
        mac.clipboard.copy(nil)
        try await Task.sleep(for: Self.quietWait)
        XCTAssertEqual(inbox.all.count, 1)

        // 超过 1 MB：只报大小，不截断。
        let huge = String(repeating: "a", count: RemoteDesktopClipboard.maxTextBytes + 1)
        mac.clipboard.copy(huge)
        let tooLarge = await waitUntil { inbox.all.last == .tooLarge(bytes: huge.utf8.count) }
        XCTAssertTrue(tooLarge, "\(inbox.all.count)")

        // 手机自己粘贴进来的那份不回传。
        session.paste(.text("手机粘贴过去的"))
        let pasted = await waitUntil { mac.injector.allPastes.count == 1 }
        XCTAssertTrue(pasted)
        XCTAssertEqual(mac.clipboard.text(), "手机粘贴过去的")
        try await Task.sleep(for: Self.quietWait)
        XCTAssertEqual(inbox.all.count, 2, "手机粘贴写进剪贴板的那一版不该回传")

        // 之后的拷贝照常回传。
        mac.clipboard.copy("粘贴之后再拷贝的")
        let again = await waitUntil { inbox.all.last == .text("粘贴之后再拷贝的") }
        XCTAssertTrue(again, "\(inbox.all.count)")

        // 流停了就不再看剪贴板。
        session.stop()
        let released = await waitUntil { server.desktopViewer == nil }
        XCTAssertTrue(released)
        mac.clipboard.copy("停流之后拷贝的")
        try await Task.sleep(for: Self.quietWait)
        XCTAssertEqual(inbox.all.count, 3)
    }

    func test_slow_clipboard_read_does_not_stall_the_link() async throws {
        // 2026-11-17 真机：手机上拷的图经接力出现在 Mac 的剪贴板里，Mac 一读就卡几十秒。当时读取在连接队列上，
        // 手机的心跳没人回，画面静止时每 4 秒判一次连接已死、重连重开流。
        let mac = FakeDesktopMac()
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        let (session, inbox) = await startSession(client)
        defer { session.stop() }
        session.send(.move(x: 0.5, y: 0.5))
        let moved = await waitUntil { mac.injector.all.count == 1 }
        XCTAssertTrue(moved)
        let sources = mac.sources.count

        // Mac 的剪贴板变了，读它要 8 秒；这期间屏幕完全不动（没有画面可发，全靠心跳撑着连接）。
        mac.clipboard.readDelay = 8
        mac.clipboard.copy("要等很久才读得到的字")
        try await Task.sleep(for: .seconds(6))
        XCTAssertEqual(client.state, .connected, "读剪贴板卡住时连接不能断")
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.sources.count, sources, "流被重开了：手机判定连接已死")
        // 卡住期间输入照常到 Mac。
        session.send(.move(x: 0.6, y: 0.6))
        let stillWorks = await waitUntil(2) { mac.injector.all.count == 2 }
        XCTAssertTrue(stillWorks, "读剪贴板卡住时输入应照常送达")
        // 读完了，文字照样回传。
        let arrived = await waitUntil(6) { inbox.all == [.text("要等很久才读得到的字")] }
        XCTAssertTrue(arrived, "读完之后剪贴板应回传：\(inbox.all)")
    }

    func test_handoff_and_non_text_clipboards_are_not_read() {
        let text = NSPasteboard.PasteboardType.string.rawValue
        XCTAssertTrue(RemoteSystemClipboard.shouldReadText(types: [text]))
        XCTAssertTrue(RemoteSystemClipboard.shouldReadText(types: ["public.html", text]))
        // 接力（通用剪贴板）来的：内容在别的设备上，一读就要等系统去取。不读。
        XCTAssertFalse(RemoteSystemClipboard.shouldReadText(types: [RemoteSystemClipboard.remoteClipboardType, text]))
        XCTAssertFalse(RemoteSystemClipboard.shouldReadText(types: [RemoteSystemClipboard.remoteClipboardType, "public.png"]))
        // 只有图片 / 文件：没有文字可回传，也不去读（读文字会让系统去试各种转换）。
        XCTAssertFalse(RemoteSystemClipboard.shouldReadText(types: ["public.png", "public.tiff"]))
        XCTAssertFalse(RemoteSystemClipboard.shouldReadText(types: []))
    }

    func test_view_only_phone_gets_no_clipboard() async throws {
        let mac = FakeDesktopMac()
        mac.canControl = false
        let server = try await makeServer(mac)
        defer { server.stop() }
        let client = try await makeClient(server)
        let (session, inbox) = await startSession(client)
        defer { session.stop() }
        XCTAssertEqual(session.info?.canControl, false)

        session.send(.move(x: 0.5, y: 0.5))
        mac.clipboard.copy("只看时 Mac 上拷贝的")
        try await Task.sleep(for: Self.quietWait)
        XCTAssertEqual(inbox.all, [], "只查看不控制时不回传剪贴板")
        session.stop()

        // 越过手机端的门禁硬发输入（手机也声明认得剪贴板）：Mac 没有注入器，照样不看剪贴板。
        let raw = try await rawPhone(server, features: RemoteConstants.localFeatures)
        defer { raw.link.close() }
        raw.link.send(RemoteMessage(.desktopInput, channel: raw.channel, payload: RemoteDesktopInput.move(x: 0, y: 0).encoded()))
        mac.clipboard.copy("只看时又拷贝的")
        try await Task.sleep(for: Self.quietWait)
        XCTAssertTrue(raw.inbox.of(.desktopClipboard).isEmpty)
        XCTAssertTrue(mac.injector.all.isEmpty)
    }

    func test_clipboard_is_only_sent_to_phones_that_declare_the_feature() async throws {
        let mac = FakeDesktopMac()
        let server = try await makeServer(mac)
        defer { server.stop(); withExtendedLifetime(mac) {} }

        // 老手机（握手不带 desktop-clipboard）：收到不认识的消息会断开整条连接，所以一条都不能发。
        let old = try await rawPhone(server, features: [RemoteFeature.desktop, RemoteFeature.heartbeat,
                                                          RemoteFeature.keyConfirmation])
        defer { old.link.close() }
        old.link.send(RemoteMessage(.desktopInput, channel: old.channel, payload: RemoteDesktopInput.move(x: 0, y: 0).encoded()))
        let oldMoved = await waitUntil { mac.injector.all.count == 1 }
        XCTAssertTrue(oldMoved)
        mac.clipboard.copy("给老手机的")
        try await Task.sleep(for: Self.quietWait)
        XCTAssertTrue(old.inbox.of(.desktopClipboard).isEmpty)
        old.link.close()

        // 同样的手机只多声明这一项：照常收到。
        let new = try await rawPhone(server, features: [RemoteFeature.desktop, RemoteFeature.desktopClipboard,
                                                          RemoteFeature.keyConfirmation])
        defer { new.link.close() }
        new.link.send(RemoteMessage(.desktopInput, channel: new.channel, payload: RemoteDesktopInput.move(x: 0, y: 0).encoded()))
        let newMoved = await waitUntil { mac.injector.all.count == 2 }
        XCTAssertTrue(newMoved)
        mac.clipboard.copy("给新手机的")
        let arrived = await waitUntil { !new.inbox.of(.desktopClipboard).isEmpty }
        XCTAssertTrue(arrived)
        let message = try XCTUnwrap(new.inbox.of(.desktopClipboard).first)
        XCTAssertEqual(message.channel, new.channel)
        XCTAssertEqual(try RemoteDesktopClipboard(decoding: message.payload), .text("给新手机的"))
    }

    /// 一个直接用 `RemoteLink` 说话、握手声明 `features` 的「手机」（已被 Mac 信任），开好一路桌面流。
    private func rawPhone(_ server: RemoteHostServer, features: [String])
        async throws -> (link: RemoteLink, inbox: RawInbox, channel: UInt32) {
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let id = UUID()
        try server.trust(RemotePeer(id: id, name: "原始手机", publicKey: phone.publicKey.rawRepresentation, pairedAt: Date()))
        let inbox = RawInbox()
        let link = RemoteLink(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(server.port))!,
                                                       using: RemoteLink.parameters()))
        link.setHandlers(onMessage: { inbox.add($0) }, onClose: { _ in })
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        _ = try await link.establish(role: .initiator,
                                     hello: RemoteHello(version: RemoteConstants.protocolVersion, deviceID: id,
                                                        deviceName: "原始手机",
                                                        ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                                        staticKey: phone.publicKey.rawRepresentation, features: features),
                                     staticKey: phone, ephemeralKey: ephemeral)
        // 声明了 `key-confirm` 的手机握手后要先发一帧确认，Mac 才往下走（与真手机一样）。
        if features.contains(RemoteFeature.keyConfirmation) { link.send(RemoteMessage(.keyConfirm)) }
        let paired = await waitUntil { !inbox.of(.pairing).isEmpty }
        XCTAssertTrue(paired)
        link.send(RemoteMessage(.desktopStart, payload: RemoteJSON.encode(
            RemoteDesktopStartRequest(requestID: UUID(), maxWidth: 1280, maxHeight: 800, codec: .hevc))))
        let started = await waitUntil { inbox.first(.desktopStarted) != nil }
        XCTAssertTrue(started)
        return (link, inbox, try XCTUnwrap(inbox.first(.desktopStarted)).channel)
    }

    // MARK: - 消息编解码

    func test_clipboard_message_round_trip_and_limits() throws {
        for content: RemoteDesktopClipboard in [.text("a"), .text("多字节 🙂\n第二行"), .tooLarge(bytes: 5_000_000)] {
            XCTAssertEqual(try RemoteDesktopClipboard(decoding: content.encoded()), content)
        }
        XCTAssertNil(RemoteDesktopClipboard.message(for: ""))
        let limit = String(repeating: "字", count: RemoteDesktopClipboard.maxTextBytes / 3)
        XCTAssertEqual(RemoteDesktopClipboard.message(for: limit), .text(limit))
        XCTAssertEqual(RemoteDesktopClipboard.message(for: limit + "ab"), .tooLarge(bytes: limit.utf8.count + 2))
        // 坏消息：空文字、超限文字、未知类型、非 UTF-8。
        XCTAssertThrowsError(try RemoteDesktopClipboard(decoding: Data([1])))
        XCTAssertThrowsError(try RemoteDesktopClipboard(decoding: Data([1]) + Data(count: RemoteDesktopClipboard.maxTextBytes + 1)))
        XCTAssertThrowsError(try RemoteDesktopClipboard(decoding: Data([9, 0])))
        XCTAssertThrowsError(try RemoteDesktopClipboard(decoding: Data([1, 0xFF, 0xFE])))
    }
}

/// 手机会话收到的剪贴板（主线程上写，测试读）。
@MainActor
private final class ClipboardInbox {
    private(set) var all: [RemoteDesktopClipboard] = []
    func add(_ content: RemoteDesktopClipboard) { all.append(content) }
}

private final class RawInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [RemoteMessage] = []
    func add(_ m: RemoteMessage) { lock.lock(); messages.append(m); lock.unlock() }
    var all: [RemoteMessage] { lock.lock(); defer { lock.unlock() }; return messages }
    func first(_ kind: RemoteMessage.Kind) -> RemoteMessage? { all.first { $0.kind == kind } }
    func of(_ kind: RemoteMessage.Kind) -> [RemoteMessage] { all.filter { $0.kind == kind } }
}
