import CryptoKit
import Observation
import XCTest
import SwiftTerm
@preconcurrency import Network
@testable import uTerm

/// 远控服务端的回环集成测试：127.0.0.1 上起真实的 `RemoteHostServer`（不广播），
/// 一个「手机」客户端直接用 `RemoteLink` 走完配对 → 会话列表 → 接入 → 输入输出 → 断开。
@MainActor
final class RemoteHostServerTests: XCTestCase {

    private final class SilentDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// 客户端收到的消息（连接队列上写入，测试线程读）。
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [RemoteMessage] = []
        private var arrivals: [Date] = []
        private(set) var closed = false
        func add(_ m: RemoteMessage) { lock.lock(); messages.append(m); arrivals.append(Date()); lock.unlock() }
        func close() { lock.lock(); closed = true; lock.unlock() }
        var all: [RemoteMessage] { lock.lock(); defer { lock.unlock() }; return messages }
        func first(_ kind: RemoteMessage.Kind) -> RemoteMessage? { all.first { $0.kind == kind } }
        func of(_ kind: RemoteMessage.Kind) -> [RemoteMessage] { all.filter { $0.kind == kind } }
        func arrival(where match: (RemoteMessage) -> Bool) -> Date? {
            lock.lock(); defer { lock.unlock() }
            return zip(messages, arrivals).first { match($0.0) }?.1
        }
    }

    private struct Phone {
        let staticKey = Curve25519.KeyAgreement.PrivateKey()
        let id = UUID()
        let name = "测试 iPhone"
    }

    private let phoneDelegate = SilentDelegate()

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private func corpus(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "terminal-corpus-\(name)", withExtension: "bin"))
        return [UInt8](try Data(contentsOf: url))
    }

    /// 一台连上 MockBackend 并登记到注册表的 Mac 会话，以及在 127.0.0.1 上监听的服务端。
    private func makeServer() async throws -> (RemoteHostServer, TerminalSession, MockBackend, UUID, UInt16) {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        let sessionID = UUID()
        registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "测试主机",
                                               windowKind: TerminalWindowKind.workspace, title: "zsh",
                                               connectedAt: Date()),
                          session: session)
        let server = RemoteHostServer(registry: registry, identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false)
        server.start()
        let ready = await waitUntil { server.port != nil }
        XCTAssertTrue(ready, "服务端没起来：\(server.status)")
        return (server, session, backend, sessionID, try XCTUnwrap(server.port))
    }

    private func connect(_ phone: Phone, port: UInt16) async throws -> (RemoteLink, Inbox, String) {
        let inbox = Inbox()
        let link = RemoteLink(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                                       using: RemoteLink.parameters()))
        link.setHandlers(onMessage: { inbox.add($0) }, onClose: { _ in inbox.close() })
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hello = RemoteHello(version: RemoteConstants.protocolVersion, deviceID: phone.id, deviceName: phone.name,
                                ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                staticKey: phone.staticKey.publicKey.rawRepresentation,
                                features: [RemoteFeature.keyConfirmation])
        let established = try await link.establish(role: .initiator, hello: hello, staticKey: phone.staticKey,
                                                   ephemeralKey: ephemeral)
        // 与真手机一样握手后先证明持有私钥：Mac 不接受不做这一步的连接。
        link.send(RemoteMessage(.keyConfirm))
        XCTAssertEqual(established.peer.deviceName, "测试 Mac")
        return (link, inbox, established.verificationCode)
    }

    private func pairingStates(_ inbox: Inbox) -> [RemotePairingState] {
        inbox.of(.pairing).compactMap { $0.payload.first.flatMap(RemotePairingState.init(rawValue:)) }
    }

    /// 声明支持密钥确认、但始终发不出合法密文的连接（比如拿着别人公开的长期公钥来冒充）：
    /// 不能写进信任、不能算已连接，也不能弹审批，到时限就断开。
    func test_peer_that_never_confirms_its_key_is_not_trusted_or_authorized() async throws {
        let registry = TerminalSessionRegistry()
        let identity = RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage())
        let server = RemoteHostServer(registry: registry, identity: identity, localName: "测试 Mac", localID: UUID(),
                                      advertises: false, keyConfirmationTimeout: .milliseconds(200))
        server.start()
        defer { server.stop() }
        let ready = await waitUntil { server.port != nil }
        XCTAssertTrue(ready)

        let victim = Phone()
        try identity.trust(RemotePeer(id: victim.id, name: victim.name,
                                      publicKey: victim.staticKey.publicKey.rawRepresentation, pairedAt: Date()))
        let spoofer = Curve25519.KeyAgreement.PrivateKey()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let inbox = Inbox()
        let link = RemoteLink(connection: NWConnection(host: "127.0.0.1",
                                                       port: NWEndpoint.Port(rawValue: try XCTUnwrap(server.port))!,
                                                       using: RemoteLink.parameters()))
        link.setHandlers(onMessage: { inbox.add($0) }, onClose: { _ in inbox.close() })
        let hello = RemoteHello(version: RemoteConstants.protocolVersion, deviceID: victim.id, deviceName: victim.name,
                                ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                staticKey: victim.staticKey.publicKey.rawRepresentation,
                                features: [RemoteFeature.keyConfirmation])
        // 手里没有受害者的私钥，算出来的会话密钥和 Mac 不一样。
        _ = try await link.establish(role: .initiator, hello: hello, staticKey: spoofer, ephemeralKey: ephemeral)

        let closed = await waitUntil { inbox.closed }
        XCTAssertTrue(closed, "到时限应该断开")
        XCTAssertTrue(server.connectedDevices.isEmpty)
        XCTAssertTrue(server.pairingRequests.isEmpty)
        XCTAssertTrue(inbox.of(.pairing).isEmpty, "身份没确认前不该告诉对方配对结果")
    }

    /// 冒充者在握手里干脆不报 key-confirm：不能因此跳过验证，直接断开。
    func test_peer_that_omits_key_confirmation_feature_is_rejected() async throws {
        let registry = TerminalSessionRegistry()
        let identity = RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage())
        let server = RemoteHostServer(registry: registry, identity: identity, localName: "测试 Mac", localID: UUID(),
                                      advertises: false, keyConfirmationTimeout: .seconds(5))
        server.start()
        defer { server.stop() }
        let ready = await waitUntil { server.port != nil }
        XCTAssertTrue(ready)

        let victim = Phone()
        try identity.trust(RemotePeer(id: victim.id, name: victim.name,
                                      publicKey: victim.staticKey.publicKey.rawRepresentation, pairedAt: Date()))
        let spoofer = Curve25519.KeyAgreement.PrivateKey()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let inbox = Inbox()
        let link = RemoteLink(connection: NWConnection(host: "127.0.0.1",
                                                       port: NWEndpoint.Port(rawValue: try XCTUnwrap(server.port))!,
                                                       using: RemoteLink.parameters()))
        link.setHandlers(onMessage: { inbox.add($0) }, onClose: { _ in inbox.close() })
        let hello = RemoteHello(version: RemoteConstants.protocolVersion, deviceID: victim.id, deviceName: victim.name,
                                ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                staticKey: victim.staticKey.publicKey.rawRepresentation,
                                features: [RemoteFeature.heartbeat])
        // Mac 一看到握手内容就断开时，这边的握手可能走不完；用例看的是「被断开」。
        do {
            _ = try await link.establish(role: .initiator, hello: hello, staticKey: spoofer, ephemeralKey: ephemeral)
        } catch {
            inbox.close()
        }

        let closed = await waitUntil { inbox.closed }
        XCTAssertTrue(closed, "不报 key-confirm 应该立刻断开，而不是等超时")
        XCTAssertTrue(server.connectedDevices.isEmpty)
        XCTAssertTrue(inbox.of(.pairing).isEmpty)
    }

    /// 名册担保的设备：要先确认密钥才写进本机信任。
    func test_known_device_is_authorized_only_after_key_confirmation() async throws {
        let (server, session, _, _, port) = try await makeServer()
        defer { server.stop(); session.dispose() }
        let phone = Phone()
        try server.identity.trust(RemotePeer(id: phone.id, name: phone.name,
                                             publicKey: phone.staticKey.publicKey.rawRepresentation, pairedAt: Date()))
        let inbox = Inbox()
        let link = RemoteLink(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                                       using: RemoteLink.parameters()))
        link.setHandlers(onMessage: { inbox.add($0) }, onClose: { _ in inbox.close() })
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hello = RemoteHello(version: RemoteConstants.protocolVersion, deviceID: phone.id, deviceName: phone.name,
                                ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                staticKey: phone.staticKey.publicKey.rawRepresentation,
                                features: [RemoteFeature.keyConfirmation])
        _ = try await link.establish(role: .initiator, hello: hello, staticKey: phone.staticKey, ephemeralKey: ephemeral)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(server.connectedDevices.isEmpty, "还没确认密钥")
        XCTAssertTrue(inbox.of(.pairing).isEmpty)

        link.send(RemoteMessage(.keyConfirm))
        let authorized = await waitUntil { self.pairingStates(inbox).contains(.trusted) }
        XCTAssertTrue(authorized)
        XCTAssertEqual(server.connectedDevices, [phone.name])
        link.close()
    }

    /// 真实的手机客户端带着能力位走完配对，密钥确认对它透明。
    func test_real_client_pairs_through_key_confirmation() async throws {
        let (server, session, _, _, port) = try await makeServer()
        defer { server.stop(); session.dispose() }
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        defer { client.disconnect() }
        let connecting = Task { await client.connect() }
        let asked = await waitUntil { !server.pairingRequests.isEmpty }
        XCTAssertTrue(asked)
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
    }

    /// 不经过 `listener` 的连接也能接：公网路径就是这样进来的，局域网监听失败不该连累它。
    func test_accept_transport_works_without_a_listener() async throws {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false)
        let (phoneSide, macSide) = RemoteMemoryTransport.pair()
        server.accept(transport: macSide)

        let phone = Phone()
        let inbox = Inbox()
        let link = RemoteLink(transport: phoneSide)
        link.setHandlers(onMessage: { inbox.add($0) }, onClose: { _ in inbox.close() })
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hello = RemoteHello(version: RemoteConstants.protocolVersion, deviceID: phone.id, deviceName: phone.name,
                                ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                staticKey: phone.staticKey.publicKey.rawRepresentation,
                                features: [RemoteFeature.keyConfirmation])
        let established = try await link.establish(role: .initiator, hello: hello, staticKey: phone.staticKey,
                                                   ephemeralKey: ephemeral)
        // 与真手机一样握手后先证明持有私钥：Mac 不接受不做这一步的连接。
        link.send(RemoteMessage(.keyConfirm))
        XCTAssertEqual(established.peer.deviceName, "测试 Mac")
        link.close()
    }

    /// 手机看到的是 Mac 标签上的名字；程序连续改标题时合并推送，`title` 保持稳定。
    func test_session_list_follows_tab_title_and_merges_rapid_changes() async throws {
        let (server, session, _, sessionID, port) = try await makeServer()
        defer { server.stop(); session.dispose() }
        let phone = Phone()
        let (link, inbox, _) = try await connect(phone, port: port)
        let pending = await waitUntil { !server.pairingRequests.isEmpty }
        XCTAssertTrue(pending)
        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        let approved = await waitUntil { self.pairingStates(inbox).contains(.approved) }
        XCTAssertTrue(approved)
        link.send(RemoteMessage(.subscribeSessions))

        func latest() throws -> RemoteSessionInfo? {
            guard let message = inbox.of(.sessions).last else { return nil }
            return try RemoteJSON.decode([RemoteSessionInfo].self, from: message.payload).first { $0.id == sessionID }
        }
        let listed = await waitUntil { (try? latest())??.tabTitle == "zsh" }
        XCTAssertTrue(listed)
        let before = inbox.of(.sessions).count

        for frame in 0..<50 {
            session.terminalView.feed(text: "\u{1b}]0;frame \(frame)\u{07}")
            try await Task.sleep(for: .milliseconds(10))
        }
        let followed = await waitUntil { (try? latest())??.tabTitle == "frame 49" }
        XCTAssertTrue(followed)
        XCTAssertEqual(try latest()?.title, "zsh")
        XCTAssertLessThanOrEqual(inbox.of(.sessions).count - before, 3, "50 次改标题不能变成 50 条推送")

        session.terminalView.feed(text: "\u{1b}]0;\u{07}")
        let restored = await waitUntil { (try? latest())??.tabTitle == "zsh" }
        XCTAssertTrue(restored, "程序清掉标题后回到原名")
    }

    func test_pair_attach_stream_input_detach_and_trust_lifecycle() async throws {
        let (server, session, backend, sessionID, port) = try await makeServer()
        defer { server.stop(); session.dispose() }
        let phone = Phone()

        // 1. 首次连接：等 Mac 审批，两端核对码一致。
        let (link, inbox, code) = try await connect(phone, port: port)
        let pending = await waitUntil { !server.pairingRequests.isEmpty }
        XCTAssertTrue(pending)
        XCTAssertEqual(server.pairingRequests.first?.code, code, "两端核对码必须一致")
        XCTAssertEqual(pairingStates(inbox), [.awaitingApproval])

        // 审批之前发的请求一律不理。
        link.send(RemoteMessage(.subscribeSessions))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(inbox.first(.sessions))

        server.approvePairing(try XCTUnwrap(server.pairingRequests.first?.id))
        let approved = await waitUntil { self.pairingStates(inbox).contains(.approved) }
        XCTAssertTrue(approved)
        XCTAssertEqual(server.trustedPeers.map(\.id), [phone.id])

        // 2. 会话列表。
        link.send(RemoteMessage(.subscribeSessions))
        let listed = await waitUntil { inbox.first(.sessions) != nil }
        XCTAssertTrue(listed)
        let sessions = try RemoteJSON.decode([RemoteSessionInfo].self, from: try XCTUnwrap(inbox.first(.sessions)).payload)
        XCTAssertEqual(sessions.map(\.id), [sessionID])

        // 3. 接入：Mac 终端钉成手机的尺寸，快照 + 后续输出在手机端还原出一致的状态。
        let phoneTerminal = Terminal(delegate: phoneDelegate, options: TerminalOptions(cols: 71, rows: 22, scrollback: 2000))
        link.send(RemoteMessage(.attach, payload: RemoteJSON.encode(RemoteAttachRequest(sessionID: sessionID, cols: 71, rows: 22))))
        let attached = await waitUntil { inbox.first(.attached) != nil }
        XCTAssertTrue(attached)
        let attachMessage = try XCTUnwrap(inbox.first(.attached))
        XCTAssertNil(try RemoteJSON.decode(RemoteAttachResult.self, from: attachMessage.payload).error)
        let channel = attachMessage.channel
        XCTAssertEqual(session.terminalView.getTerminal().cols, 71)
        XCTAssertEqual(session.remoteController, phone.name)

        let vim = try corpus("vim")
        for chunk in stride(from: 0, to: vim.count, by: 433) {
            await backend.emitOutput(Data(vim[chunk..<min(vim.count, chunk + 433)]))
        }
        var fed = 0
        let consistent = await waitUntil(5) {
            let outputs = inbox.of(.output).filter { $0.channel == channel }
            for message in outputs.dropFirst(fed) { phoneTerminal.feed(byteArray: [UInt8](message.payload)) }
            fed = outputs.count
            return session.terminalView.getTerminal().snapshotFingerprint()
                .differences(from: phoneTerminal.snapshotFingerprint()).isEmpty
        }
        XCTAssertTrue(consistent, "\(session.terminalView.getTerminal().snapshotFingerprint().differences(from: phoneTerminal.snapshotFingerprint()))")

        // 4. 输入原样写进后端。
        link.send(RemoteMessage(.input, channel: channel, payload: Data("ls -la\r".utf8)))
        let wrote = await waitUntil { await backend.writtenData.contains(Data("ls -la\r".utf8)) }
        XCTAssertTrue(wrote)

        // 5. 断开：尺寸交还给窗格。
        link.send(RemoteMessage(.detach, channel: channel))
        let released = await waitUntil { session.remoteController == nil }
        XCTAssertTrue(released)
        link.close()
        _ = await waitUntil { server.connectedDevices.isEmpty }

        // 6. 再连：已信任，直接放行。
        let (again, againInbox, _) = try await connect(phone, port: port)
        let trusted = await waitUntil { self.pairingStates(againInbox) == [.trusted] }
        XCTAssertTrue(trusted)
        XCTAssertTrue(server.pairingRequests.isEmpty)
        again.close()
        _ = await waitUntil { server.connectedDevices.isEmpty }

        // 7. 撤销后再连：重新要审批；拒绝则断开。
        server.revoke(phone.id)
        let (revoked, revokedInbox, _) = try await connect(phone, port: port)
        let askedAgain = await waitUntil { !server.pairingRequests.isEmpty }
        XCTAssertTrue(askedAgain)
        server.rejectPairing(try XCTUnwrap(server.pairingRequests.first?.id))
        let closed = await waitUntil { revokedInbox.closed }
        XCTAssertTrue(closed)
        XCTAssertEqual(pairingStates(revokedInbox), [.awaitingApproval, .rejected])
        revoked.close()
    }

    /// 同一台设备换了长期密钥（冒充或重装）：不能直接放行，必须重新审批。
    func test_known_device_id_with_different_key_needs_approval() async throws {
        let (server, session, _, _, port) = try await makeServer()
        defer { server.stop(); session.dispose() }
        let phone = Phone()
        try server.trust(RemotePeer(id: phone.id, name: phone.name,
                                    publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                    pairedAt: Date()))
        let (link, inbox, _) = try await connect(phone, port: port)
        let asked = await waitUntil { self.pairingStates(inbox) == [.awaitingApproval] }
        XCTAssertTrue(asked)
        link.close()
    }

    /// 读数探针（不设断言）：回环上按键到后端、输出到手机的单程耗时。
    func test_probe_loopback_latency() async throws {
        let (server, session, backend, sessionID, port) = try await makeServer()
        defer { server.stop(); session.dispose() }
        let phone = Phone()
        try server.trust(RemotePeer(id: phone.id, name: phone.name, publicKey: phone.staticKey.publicKey.rawRepresentation,
                                    pairedAt: Date()))
        let attachStart = Date()
        let (link, inbox, _) = try await connect(phone, port: port)
        // 密钥确认之后才授权：没授权前发的请求 Mac 不理。
        _ = await waitUntil { self.pairingStates(inbox).contains(.trusted) }
        link.send(RemoteMessage(.attach, payload: RemoteJSON.encode(RemoteAttachRequest(sessionID: sessionID, cols: 80, rows: 24))))
        _ = await waitUntil { !inbox.of(.output).isEmpty }
        let attachMs = Date().timeIntervalSince(attachStart) * 1000
        let channel = try XCTUnwrap(inbox.first(.attached)).channel

        var inputMs: [Double] = []
        var outputMs: [Double] = []
        for i in 0..<50 {
            // 每轮隔开 30 ms：让 Mac 的输出循环回到空闲态，量的是打字回显那条路径。连续输出时
            // 它按 16 ms 一帧合批，那段延迟 Mac 本地显示同样有，不是远控引入的。
            try? await Task.sleep(for: .milliseconds(30))
            let key = Data("k\(i)".utf8)
            let sent = Date()
            link.send(RemoteMessage(.input, channel: channel, payload: key))
            _ = await waitUntil { await backend.writtenData.contains(key) }
            inputMs.append(Date().timeIntervalSince(sent) * 1000)

            let marker = Data("<\(i)>".utf8)
            let emitted = Date()
            await backend.emitOutput(marker)
            _ = await waitUntil { inbox.arrival { $0.kind == .output && $0.payload.range(of: marker) != nil } != nil }
            if let arrived = inbox.arrival(where: { $0.kind == .output && $0.payload.range(of: marker) != nil }) {
                outputMs.append(arrived.timeIntervalSince(emitted) * 1000)
            }
        }
        func p(_ xs: [Double], _ q: Double) -> Double { let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count) * q))] }
        print(String(format: "[远控回环探针] 接入到首帧 %.1f ms；按键→后端 p50 %.2f / p95 %.2f ms；输出→手机 p50 %.2f / p95 %.2f ms（Debug，含测试轮询粒度 2 ms）",
                     attachMs, p(inputMs, 0.5), p(inputMs, 0.95), p(outputMs, 0.5), p(outputMs, 0.95)))
        link.close()
    }

    /// 只有标签名变时，列表要更新，但不能惊动按 id 跟随的工作区。
    func test_client_keeps_listed_ids_quiet_when_only_titles_change() {
        let client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        var info = RemoteSessionInfo(id: UUID(), serverID: UUID(), serverName: "本机", title: "zsh 2",
                                     windowKind: TerminalWindowKind.terminal, tabTitle: "zsh 2")
        client.receiveSessions([info])

        final class Flag: @unchecked Sendable { var fired = false }
        let idsChanged = Flag()
        withObservationTracking { _ = client.listedSessionIDs } onChange: { idsChanged.fired = true }

        info.tabTitle = "vim"
        client.receiveSessions([info])
        XCTAssertEqual(client.sessions.first?.displayTitle, "vim")
        XCTAssertFalse(idsChanged.fired)

        client.receiveSessions([])
        XCTAssertTrue(idsChanged.fired)
    }

    /// 老版本 Mac 的列表没有 `tabTitle`：手机回到 `title`。
    func test_session_info_from_old_mac_falls_back_to_title() throws {
        let json = """
        {"id":"\(UUID().uuidString)","serverID":"\(UUID().uuidString)","serverName":"本机","title":"zsh 2","windowKind":"terminal"}
        """
        let info = try JSONDecoder().decode(RemoteSessionInfo.self, from: Data(json.utf8))
        XCTAssertNil(info.tabTitle)
        XCTAssertEqual(info.displayTitle, "zsh 2")
    }
}
