import XCTest
import CryptoKit
@preconcurrency import Network
@testable import uTerm

/// 远控里终端程序状态（`programStatus`，46 号消息）：快照、变化推送、老版本降级、镜像不重复回答查询。
@MainActor
final class RemoteProgramStatusTests: XCTestCase {

    private static let quietWait: Duration = .milliseconds(300)

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func osc(_ body: String) -> Data { Data("\u{1b}]7501;\(body)\u{1b}\\".utf8) }

    private func record(_ state: ProgramState, kind: ProgramBlockKind? = nil, app: String? = "claude-code",
                        message: String? = nil) -> ProgramStatusRecord {
        ProgramStatusRecord(state: state, kind: kind, progress: nil, app: app, title: nil, message: message)
    }

    // MARK: - 线上形态

    func test_status_round_trips_through_json() throws {
        let original = ProgramStatusRecord(state: .blocked, kind: .permission, progress: 40, app: "codex",
                                           title: "构建", message: "要执行 rm -rf build")
        let update = RemoteProgramStatusUpdate(replacesAll: true, entries: [
            .init(sessionID: UUID(), status: RemoteProgramStatus(original)),
            .init(sessionID: UUID(), status: nil),
        ])
        let decoded = try RemoteJSON.decode(RemoteProgramStatusUpdate.self, from: RemoteJSON.encode(update))
        XCTAssertEqual(decoded, update)
        XCTAssertEqual(decoded.entries.first?.status?.record, original)
    }

    func test_unknown_state_from_a_newer_mac_drops_only_that_entry() throws {
        let known = UUID(), future = UUID()
        let json = """
        {"replacesAll":false,"entries":[
          {"sessionID":"\(known.uuidString)","status":{"state":"working","app":"codex"}},
          {"sessionID":"\(future.uuidString)","status":{"state":"thinking-hard","kind":"telepathy"}}]}
        """
        let update = try RemoteJSON.decode(RemoteProgramStatusUpdate.self, from: Data(json.utf8))
        var book = RemoteProgramStatusBook()
        book.apply(update)
        XCTAssertEqual(book.report(for: known)?.state, .working)
        XCTAssertNil(book.report(for: future), "认不出的状态当作没有状态，不连累同一份里的其它会话")
    }

    func test_message_kind_46_is_program_status_and_round_trips() throws {
        XCTAssertEqual(RemoteMessage.Kind.programStatus.rawValue, 46)
        let message = RemoteMessage(.programStatus, payload: Data("{}".utf8))
        XCTAssertEqual(try RemoteMessage(decoding: message.encoded()), message)
        XCTAssertTrue(RemoteConstants.localFeatures.contains(RemoteFeature.programStatus))
    }

    // MARK: - 设备侧的账本

    func test_book_snapshot_replaces_and_delta_merges() {
        let a = UUID(), b = UUID(), c = UUID()
        var book = RemoteProgramStatusBook()
        book.apply(.init(replacesAll: true, entries: [.init(sessionID: a, status: .init(record(.working))),
                                                      .init(sessionID: b, status: .init(record(.blocked, kind: .question)))]))
        XCTAssertEqual(book.display(for: a)?.state, .working)
        XCTAssertEqual(book.display(for: b)?.kind, .question)

        // 变化推送只动列出的会话。
        book.apply(.init(replacesAll: false, entries: [.init(sessionID: a, status: nil),
                                                       .init(sessionID: c, status: .init(record(.idle)))]))
        XCTAssertNil(book.report(for: a))
        XCTAssertEqual(book.display(for: b)?.state, .blocked)
        XCTAssertEqual(book.report(for: c)?.state, .idle, "idle 也记着：前台是 Agent")
        XCTAssertNil(book.display(for: c), "idle 不上标签")

        // 新快照里没有的会话清掉。
        book.apply(.init(replacesAll: true, entries: [.init(sessionID: c, status: .init(record(.working)))]))
        XCTAssertNil(book.report(for: b))
        XCTAssertEqual(book.display(for: c)?.state, .working)

        // Mac 的会话列表里没了的一并丢掉。
        book.retain([])
        XCTAssertNil(book.report(for: c))
    }

    func test_book_acknowledges_results_seen_on_this_device() {
        let id = UUID()
        var book = RemoteProgramStatusBook()
        book.apply(.init(replacesAll: false, entries: [.init(sessionID: id, status: .init(record(.blocked)))]))
        book.acknowledge(id)
        XCTAssertEqual(book.display(for: id)?.state, .blocked, "卡住等人的不因为看过就消失")

        book.apply(.init(replacesAll: false, entries: [.init(sessionID: id, status: .init(record(.done)))]))
        XCTAssertEqual(book.display(for: id)?.state, .done)
        book.acknowledge(id)
        XCTAssertNil(book.display(for: id), "看过的结果不再提示")
        XCTAssertEqual(book.report(for: id)?.state, .done, "Mac 那边仍是已完成")

        // 断线重连：Mac 又发一份同样的快照，看过的结果不重新亮起来。
        book.removeAllReports()
        book.apply(.init(replacesAll: true, entries: [.init(sessionID: id, status: .init(record(.done)))]))
        XCTAssertNil(book.display(for: id))

        // 又跑了一轮、又完成：这是新的结果。
        book.apply(.init(replacesAll: false, entries: [.init(sessionID: id, status: .init(record(.working)))]))
        book.apply(.init(replacesAll: false, entries: [.init(sessionID: id, status: .init(record(.done)))]))
        XCTAssertEqual(book.display(for: id)?.state, .done)
    }

    func test_book_results_arriving_while_watched_count_as_seen() {
        let id = UUID()
        var book = RemoteProgramStatusBook()
        book.setWatched(id, true)
        book.apply(.init(replacesAll: false, entries: [.init(sessionID: id, status: .init(record(.error)))]))
        XCTAssertNil(book.display(for: id), "正看着这个终端时出的结果不用再提示")
        book.setWatched(id, false)
        book.apply(.init(replacesAll: false, entries: [.init(sessionID: id, status: .init(record(.working)))]))
        book.apply(.init(replacesAll: false, entries: [.init(sessionID: id, status: .init(record(.done)))]))
        XCTAssertEqual(book.display(for: id)?.state, .done, "切走之后的结果照常提示")
    }

    // MARK: - 端到端

    private struct MacSide {
        let registry: TerminalSessionRegistry
        let server: RemoteHostServer
        let session: TerminalSession
        let backend: MockBackend
        let sessionID: UUID
        let port: UInt16
    }

    private func makeMac(features: [String] = RemoteConstants.localFeatures) async throws -> MacSide {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession()
        session.attentionSink = { _ in }
        let backend = MockBackend()
        await session.connect(using: backend)
        let sessionID = UUID()
        registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "测试主机",
                                               windowKind: TerminalWindowKind.workspace, title: "zsh",
                                               connectedAt: Date()), session: session)
        let server = RemoteHostServer(registry: registry,
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false, localFeatures: features)
        server.start()
        _ = await waitUntil { server.port != nil }
        return MacSide(registry: registry, server: server, session: session, backend: backend, sessionID: sessionID,
                       port: try XCTUnwrap(server.port))
    }

    private func pairedClient(_ mac: MacSide) async throws -> RemoteMacClient {
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: mac.port)!),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let connecting = Task { await client.connect() }
        _ = await waitUntil { !mac.server.pairingRequests.isEmpty }
        mac.server.approvePairing(try XCTUnwrap(mac.server.pairingRequests.first?.id))
        await connecting.value
        XCTAssertEqual(client.state, .connected)
        let listed = await waitUntil { client.sessions.map(\.id) == [mac.sessionID] }
        XCTAssertTrue(listed)
        return client
    }

    /// 中途接入：程序早在手机连上之前就报过状态，手机照样拿到；之后每次变化都推过来。
    func test_phone_joining_midway_gets_current_status_then_changes() async throws {
        let mac = try await makeMac()
        defer { mac.server.stop(); mac.session.dispose() }
        await mac.backend.emitOutput(osc("state=working:app=claude-code"))
        let reported = await waitUntil { mac.session.programStatus?.state == .working }
        XCTAssertTrue(reported)

        let client = try await pairedClient(mac)
        defer { client.disconnect() }
        XCTAssertTrue(client.supportsProgramStatus)
        let started = Date()
        let snapshot = await waitUntil { client.programStatus(for: mac.sessionID)?.state == .working }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "快照紧跟会话列表到")
        XCTAssertTrue(snapshot, "快照里要有连上之前就在跑的程序")
        XCTAssertEqual(client.programStatus(for: mac.sessionID)?.app, "claude-code")

        let message = Data("要执行 touch a".utf8).base64EncodedString()
        await mac.backend.emitOutput(osc("state=blocked:app=claude-code:kind=permission:msg=\(message)"))
        let blocked = await waitUntil { client.programStatus(for: mac.sessionID)?.state == .blocked }
        XCTAssertTrue(blocked)
        XCTAssertEqual(client.programStatus(for: mac.sessionID)?.kind, .permission)
        XCTAssertEqual(client.programStatus(for: mac.sessionID)?.message, "要执行 touch a")

        await mac.backend.emitOutput(osc("state=idle"))
        let idle = await waitUntil { client.programReport(for: mac.sessionID)?.state == .idle }
        XCTAssertTrue(idle)
        XCTAssertNil(client.programStatus(for: mac.sessionID), "idle 不上标签")

        await mac.backend.emitOutput(osc("state=clear"))
        let cleared = await waitUntil { client.programReport(for: mac.sessionID) == nil }
        XCTAssertTrue(cleared)
    }

    /// 老 Mac 不声明 `program-status`：一条不推，连接照常，标签只显示连接状态。
    func test_old_mac_without_the_feature_pushes_nothing() async throws {
        let mac = try await makeMac(features: RemoteConstants.localFeatures.filter { $0 != RemoteFeature.programStatus })
        defer { mac.server.stop(); mac.session.dispose() }
        await mac.backend.emitOutput(osc("state=working:app=codex"))
        _ = await waitUntil { mac.session.programStatus != nil }

        let client = try await pairedClient(mac)
        defer { client.disconnect() }
        XCTAssertFalse(client.supportsProgramStatus)
        await mac.backend.emitOutput(osc("state=blocked"))
        try await Task.sleep(for: Self.quietWait)
        XCTAssertNil(client.programReport(for: mac.sessionID))
        XCTAssertEqual(client.state, .connected)
    }

    /// 老手机不声明 `program-status`：收到不认识的 46 号消息会断开整条连接，所以一条都不能发。
    func test_mac_only_pushes_to_phones_that_declare_the_feature() async throws {
        let mac = try await makeMac()
        defer { mac.server.stop(); mac.session.dispose() }
        await mac.backend.emitOutput(osc("state=working:app=codex"))
        _ = await waitUntil { mac.session.programStatus != nil }
        let base = [RemoteFeature.heartbeat, RemoteFeature.keyConfirmation]

        let old = try await rawPhone(mac.server, features: base)
        defer { old.link.close() }
        await mac.backend.emitOutput(osc("state=blocked"))
        try await Task.sleep(for: Self.quietWait)
        XCTAssertFalse(old.inbox.all.isEmpty, "老手机照常收到会话列表")
        XCTAssertTrue(old.inbox.of(.programStatus).isEmpty)
        old.link.close()

        let new = try await rawPhone(mac.server, features: base + [RemoteFeature.programStatus])
        defer { new.link.close() }
        let arrived = await waitUntil { !new.inbox.of(.programStatus).isEmpty }
        XCTAssertTrue(arrived)
        let kinds = new.inbox.all.map(\.kind)
        XCTAssertLessThan(try XCTUnwrap(kinds.firstIndex(of: .sessions)), try XCTUnwrap(kinds.firstIndex(of: .programStatus)),
                          "先发会话列表再发状态")
        let first = try RemoteJSON.decode(RemoteProgramStatusUpdate.self,
                                          from: try XCTUnwrap(new.inbox.of(.programStatus).first).payload)
        XCTAssertTrue(first.replacesAll)
        XCTAssertEqual(first.entries.map(\.sessionID), [mac.sessionID])
        XCTAssertEqual(first.entries.first?.status?.record?.state, .blocked)
    }

    /// 会话没了：状态跟着清掉。
    func test_session_removed_on_mac_clears_its_status() async throws {
        let mac = try await makeMac()
        defer { mac.server.stop(); mac.session.dispose() }
        let client = try await pairedClient(mac)
        defer { client.disconnect() }
        await mac.backend.emitOutput(osc("state=working"))
        let working = await waitUntil { client.programReport(for: mac.sessionID) != nil }
        XCTAssertTrue(working)
        mac.registry.unregister(id: mac.sessionID)
        let gone = await waitUntil { client.programReport(for: mac.sessionID) == nil }
        XCTAssertTrue(gone)
    }

    /// 镜像（Mac 控制 Mac 的标签）不回答 OSC 7501 查询：那台 Mac 自己答，再答一遍就成了 Agent 收到的多余输入。
    /// 标签的状态读连接上推来的。
    func test_mirror_session_does_not_answer_queries_and_reads_pushed_status() async throws {
        let mac = try await makeMac()
        defer { mac.server.stop(); mac.session.dispose() }
        let client = try await pairedClient(mac)
        defer { client.disconnect() }
        let mirror = TerminalSession()
        mirror.attentionSink = { _ in }
        defer { mirror.dispose() }
        await mirror.connect(using: RemoteTerminalBackend(client: client, sessionID: mac.sessionID))
        let attached = await waitUntil { mac.session.remoteController != nil }
        XCTAssertTrue(attached)

        await mac.backend.emitOutput(osc("?"))
        await mac.backend.emitOutput(osc("state=done:app=codex"))
        let pushed = await waitUntil { client.programReport(for: mac.sessionID)?.state == .done }
        XCTAssertTrue(pushed)
        try await Task.sleep(for: Self.quietWait)
        let written = await mac.backend.writtenData.reduce(Data(), +)
        let reply = Data(ProgramStatusTracker.queryReply)
        XCTAssertEqual(written.ranges(of: reply).count, 1, "只有 Mac 自己答了一次")
        XCTAssertNil(mirror.programStatus, "镜像不自己解析")
        XCTAssertEqual(client.programStatus(for: mac.sessionID)?.state, .done)

        // 在这边看过了：结果不再提示，Mac 那边照旧。
        mirror.acknowledgeProgramStatus()
        XCTAssertNil(client.programStatus(for: mac.sessionID))
        XCTAssertEqual(mac.session.programStatus?.state, .done)
    }

    // MARK: - 原始手机

    /// 直接用 `RemoteLink` 说话、握手声明 `features` 的「手机」（已被 Mac 信任），订阅了会话列表。
    private func rawPhone(_ server: RemoteHostServer, features: [String]) async throws -> (link: RemoteLink, inbox: RawInbox) {
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
        link.send(RemoteMessage(.keyConfirm))
        let paired = await waitUntil { !inbox.of(.pairing).isEmpty }
        XCTAssertTrue(paired)
        link.send(RemoteMessage(.subscribeSessions))
        let listed = await waitUntil { !inbox.of(.sessions).isEmpty }
        XCTAssertTrue(listed)
        return (link, inbox)
    }
}

private final class RawInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [RemoteMessage] = []
    func add(_ m: RemoteMessage) { lock.lock(); messages.append(m); lock.unlock() }
    var all: [RemoteMessage] { lock.lock(); defer { lock.unlock() }; return messages }
    func of(_ kind: RemoteMessage.Kind) -> [RemoteMessage] { all.filter { $0.kind == kind } }
}
