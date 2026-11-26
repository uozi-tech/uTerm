import XCTest
import CryptoKit
@preconcurrency import Network
@testable import uTerm

/// Mac 上的 Code 标签页经远控发给设备（63 号消息）：编解码、能力门禁、和会话列表的先后、标题节流、位置。
@MainActor
final class RemoteCodeTabsTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func run(_ session: UUID, title: String? = nil, ended: Date? = nil) -> RemoteCodeTabInfo.Run {
        RemoteCodeTabInfo.Run(session: session, tool: AgentHistoryTool.claude.rawValue, directory: "/Users/me/app",
                              startedAt: Date(timeIntervalSince1970: 1_800_000_000), sessionID: nil, path: nil,
                              title: title, endedAt: ended)
    }

    private func info(_ id: UUID, runs: [RemoteCodeTabInfo.Run], slot: Int? = nil) -> RemoteCodeTabInfo {
        RemoteCodeTabInfo(id: id, serverID: RemoteConstants.localShellServerID, serverName: "这台 Mac",
                          directory: "/Users/me/app", slot: slot, runs: runs, selectedRun: runs.first?.session,
                          selectedRecord: nil)
    }

    // MARK: - 线上形态

    func test_update_round_trips_and_kind_63_is_declared() throws {
        let session = UUID()
        var tab = info(UUID(), runs: [run(session, title: "修登录页", ended: Date(timeIntervalSince1970: 1_800_000_500))],
                       slot: 2)
        tab.runs[0].sessionID = "abc-123"
        tab.runs[0].path = "/Users/me/.claude/projects/-Users-me-app/abc-123.jsonl"
        tab.selectedRecord = "claude:abc-123"
        let update = RemoteCodeTabsUpdate(tabs: [tab])
        XCTAssertEqual(try RemoteJSON.decode(RemoteCodeTabsUpdate.self, from: RemoteJSON.encode(update)), update)

        XCTAssertEqual(RemoteMessage.Kind.codeTabs.rawValue, 63)
        let message = RemoteMessage(.codeTabs, payload: RemoteJSON.encode(update))
        XCTAssertEqual(try RemoteMessage(decoding: message.encoded()), message)
        XCTAssertTrue(RemoteConstants.localFeatures.contains(RemoteFeature.codeTabs))
    }

    /// 只差标题、路径算同样的形状（并进节流）；会话增减、结束、选中、位置都不算。
    func test_shape_ignores_only_titles_and_paths() {
        let a = UUID(), b = UUID()
        let base = [info(a, runs: [run(b, title: "一")])]
        var renamed = base
        renamed[0].runs[0].title = "二"
        renamed[0].runs[0].path = "/x.jsonl"
        XCTAssertTrue(renamed.sameShape(as: base))
        var ended = base
        ended[0].runs[0].endedAt = Date()
        XCTAssertFalse(ended.sameShape(as: base))
        var moved = base
        moved[0].slot = 3
        XCTAssertFalse(moved.sameShape(as: base))
        var reselected = base
        reselected[0].selectedRun = nil
        XCTAssertFalse(reselected.sameShape(as: base))
        XCTAssertFalse(base.sameShape(as: nil))
    }

    /// App 是老版本（XPC 里没有这个键）：解出来是 nil，远控进程据此一条 63 都不发。
    func test_old_agent_payload_without_code_tabs_decodes_as_nil() throws {
        let old = """
        {"entries":[],"terminalEngine":"x","restored":true,"workspaces":["/tmp"]}
        """
        let decoded = try XCTUnwrap(RemoteHostAgentJSON.decode(RemoteHostAgentSessions.self, from: Data(old.utf8)))
        XCTAssertNil(decoded.codeTabs)
        XCTAssertEqual(decoded.workspaces, ["/tmp"])

        let forwarded = RemoteForwardedSessions()
        forwarded.apply(decoded)
        XCTAssertNil(forwarded.codeTabs(), "老 App 没交过：不知道有没有 Code 标签页")

        let tabs = [info(UUID(), runs: [])]
        var fresh = decoded
        fresh.codeTabs = tabs
        let roundTripped = try XCTUnwrap(RemoteHostAgentJSON.decode(RemoteHostAgentSessions.self,
                                                                     from: RemoteHostAgentJSON.encode(fresh)))
        forwarded.apply(roundTripped)
        XCTAssertEqual(forwarded.codeTabs(), tabs)
        forwarded.appDisconnected()
        XCTAssertEqual(forwarded.codeTabs(), tabs, "App 走了留着最后一份")
    }

    // MARK: - 位置

    /// `slot` 是 Code 标签页在设备收到的会话列表里排在第几个之前：前面窗口的会话，加上同一窗口里排在它前面、
    /// 此刻登记着的 shell。还没登记的（正在连接）不占位置。
    func test_slot_counts_registered_sessions_before_the_code_tab_across_windows() {
        let registry = TerminalSessionRegistry()
        let (a1, a2, b1, pending, loose) = (UUID(), UUID(), UUID(), UUID(), UUID())
        for id in [a1, a2, b1, loose] { register(id, in: registry) }
        let first = UUID(), second = UUID()
        registry.setTabOrder(forWindow: first) { [a1, a2] }
        registry.setTabOrder(forWindow: second) { [b1, pending] }
        let codeID = UUID()
        registry.setCodeTabs(forWindow: second) {
            [.init(info: self.info(codeID, runs: []), precedingSessions: [b1, pending])]
        }
        XCTAssertEqual(registry.orderedEntries().map(\.id), [a1, a2, b1, loose])
        XCTAssertEqual(registry.codeTabs().map(\.slot), [3])

        registry.setCodeTabs(forWindow: first) {
            [.init(info: self.info(UUID(), runs: []), precedingSessions: [])]
        }
        XCTAssertEqual(registry.codeTabs().map(\.slot), [0, 3], "窗口按标签顺序登记的先后")

        registry.forgetWindow(first)
        XCTAssertEqual(registry.codeTabs().map(\.id), [codeID], "关掉的窗口一并撤掉")
    }

    private func register(_ id: UUID, in registry: TerminalSessionRegistry) {
        registry.register(TerminalSessionEntry(id: id, serverID: RemoteConstants.localShellServerID,
                                               serverName: "这台 Mac", windowKind: TerminalWindowKind.terminal,
                                               title: "zsh", connectedAt: Date()))
    }

    // MARK: - 端到端（原始手机）

    /// 一个本机终端窗口：标签顺序与 Code 标签页由测试摆。
    @MainActor
    @Observable
    final class FakeWindow {
        var order: [UUID]
        var codeTab: RemoteCodeTabInfo
        var preceding: [UUID]

        init(order: [UUID], codeTab: RemoteCodeTabInfo, preceding: [UUID]) {
            self.order = order
            self.codeTab = codeTab
            self.preceding = preceding
        }
    }

    private struct Rig {
        let registry: TerminalSessionRegistry
        let server: RemoteHostServer
        let window: FakeWindow
        let shell: UUID
        let run: UUID
    }

    /// 一个 shell 标签、一个 Code 标签页（排在 shell 后面），里面跑着一个会话。
    private func makeRig(features: [String] = RemoteConstants.localFeatures) async throws -> Rig {
        let registry = TerminalSessionRegistry()
        let shell = UUID(), run = UUID()
        register(shell, in: registry)
        register(run, in: registry)
        let window = FakeWindow(order: [shell], codeTab: info(UUID(), runs: [self.run(run)]), preceding: [shell])
        let windowID = UUID()
        registry.setTabOrder(forWindow: windowID) { window.order }
        registry.setCodeTabs(forWindow: windowID) { [.init(info: window.codeTab, precedingSessions: window.preceding)] }
        let server = RemoteHostServer(registry: registry,
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false, localFeatures: features)
        server.start()
        _ = await waitUntil { server.port != nil }
        return Rig(registry: registry, server: server, window: window, shell: shell, run: run)
    }

    private func rawPhone(_ server: RemoteHostServer, features: [String]) async throws -> (link: RemoteLink, inbox: CodeTabInbox) {
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let id = UUID()
        try server.trust(RemotePeer(id: id, name: "原始手机", publicKey: phone.publicKey.rawRepresentation, pairedAt: Date()))
        let inbox = CodeTabInbox()
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

    private static let base = [RemoteFeature.keyConfirmation, RemoteFeature.programStatus]

    /// 老设备不声明 `code-tabs`：收到 63 会断开整条连接，一条都不能发。新设备订阅时 63 → 20 → 46。
    func test_only_phones_declaring_the_feature_get_code_tabs_and_before_the_list() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }

        let old = try await rawPhone(rig.server, features: Self.base)
        defer { old.link.close() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(old.inbox.of(.codeTabs).isEmpty)

        let new = try await rawPhone(rig.server, features: Self.base + [RemoteFeature.codeTabs])
        defer { new.link.close() }
        let arrived = await waitUntil { !new.inbox.of(.programStatus).isEmpty }
        XCTAssertTrue(arrived)
        let kinds = new.inbox.all.map(\.kind).filter { [.codeTabs, .sessions, .programStatus].contains($0) }
        XCTAssertEqual(Array(kinds.prefix(3)), [.codeTabs, .sessions, .programStatus])
        let tabs = try XCTUnwrap(new.inbox.codeTabs.first)
        XCTAssertEqual(tabs.first?.runs.map(\.session), [rig.run])
        XCTAssertEqual(tabs.first?.slot, 1, "排在 shell 后面")
    }

    /// Mac 关着 Code 标签页这项能力（老版本 Mac）：对声明了的设备也不发。
    func test_mac_without_the_feature_sends_nothing() async throws {
        let rig = try await makeRig(features: RemoteConstants.localFeatures.filter { $0 != RemoteFeature.codeTabs })
        defer { rig.server.stop() }
        let phone = try await rawPhone(rig.server, features: Self.base + [RemoteFeature.codeTabs])
        defer { phone.link.close() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(phone.inbox.of(.codeTabs).isEmpty)
    }

    /// Code 标签页里新起一个会话：设备先收到归属（63）、再收到列着它的会话列表（20），不会先给它开一个终端标签页。
    func test_new_run_reaches_the_phone_in_code_tabs_before_the_list_names_it() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let phone = try await rawPhone(rig.server, features: Self.base + [RemoteFeature.codeTabs])
        defer { phone.link.close() }

        let added = UUID()
        rig.window.codeTab.runs.append(run(added))
        register(added, in: rig.registry)
        let listed = await waitUntil { phone.inbox.firstIndex(ofSessionsListing: added) != nil }
        XCTAssertTrue(listed)
        let list = try XCTUnwrap(phone.inbox.firstIndex(ofSessionsListing: added))
        let owner = try XCTUnwrap(phone.inbox.firstIndex(ofCodeTabsWith: added), "列表之前先发归属")
        XCTAssertLessThan(owner, list)
    }

    /// 会话挪出 Code 标签页（Mac 上「移到新标签页」）：设备先知道它不归 Code 标签页了，再收到它当标签排在哪的列表。
    func test_detached_run_leaves_code_tabs_before_the_reordered_list() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let phone = try await rawPhone(rig.server, features: Self.base + [RemoteFeature.codeTabs])
        defer { phone.link.close() }
        let before = phone.inbox.all.count

        rig.window.codeTab.runs = []
        rig.window.order = [rig.run, rig.shell]
        rig.window.preceding = [rig.run, rig.shell]
        let reordered = await waitUntil {
            phone.inbox.index(after: before) { message in
                message.kind == .sessions
                    && (try? RemoteJSON.decode([RemoteSessionInfo].self, from: message.payload))?.macTabOrder == [rig.run, rig.shell]
            } != nil
        }
        XCTAssertTrue(reordered)
        let list = try XCTUnwrap(phone.inbox.index(after: before) { message in
            message.kind == .sessions
                && (try? RemoteJSON.decode([RemoteSessionInfo].self, from: message.payload))?.macTabOrder == [rig.run, rig.shell]
        })
        let released = try XCTUnwrap(phone.inbox.index(after: before) { message in
            message.kind == .codeTabs
                && (try? RemoteJSON.decode(RemoteCodeTabsUpdate.self, from: message.payload))?.tabs.first?.runs.isEmpty == true
        })
        XCTAssertLessThan(released, list)
    }

    /// 只是标题变了：同标签名一样节流（一秒合成一次）；会话结束马上发。
    func test_title_changes_are_throttled_but_ending_is_immediate() async throws {
        let rig = try await makeRig()
        defer { rig.server.stop() }
        let phone = try await rawPhone(rig.server, features: Self.base + [RemoteFeature.codeTabs])
        defer { phone.link.close() }
        let sent = phone.inbox.of(.codeTabs).count

        let renamedAt = Date()
        rig.window.codeTab.runs[0].title = "修登录页"
        try await Task.sleep(for: .milliseconds(300))
        rig.window.codeTab.runs[0].title = "修登录页的样式"
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(phone.inbox.of(.codeTabs).count, sent, "标题变化不立刻推")
        let renamed = await waitUntil(3) { phone.inbox.codeTabs.last?.first?.runs.first?.title == "修登录页的样式" }
        XCTAssertTrue(renamed)
        XCTAssertGreaterThan(Date().timeIntervalSince(renamedAt), 0.8)
        XCTAssertEqual(phone.inbox.of(.codeTabs).count, sent + 1, "合成一次")

        let endedAt = Date()
        rig.window.codeTab.runs[0].endedAt = Date(timeIntervalSince1970: 1_800_000_900)
        let ended = await waitUntil(3) { phone.inbox.codeTabs.last?.first?.runs.first?.endedAt != nil }
        XCTAssertTrue(ended)
        XCTAssertLessThan(Date().timeIntervalSince(endedAt), 0.5, "结束马上到")
    }

    // MARK: - SSH 主机的 Code 标签页（真的工作区窗口）

    /// SSH 主机窗口里的 Code 标签页新起一个会话：同本机的一样，设备先收到它归哪个 Code 标签页（63，带着主机），
    /// 再收到列着它的会话列表（20）；挪出去之后先收到它不归 Code 标签页了，再收到它当标签排在哪的列表。
    func test_ssh_host_run_reaches_the_phone_in_code_tabs_before_the_list() async throws {
        let registry = TerminalSessionRegistry()
        let ssh = SSHCodeTabWindowRig(registry: registry)
        defer { ssh.dispose() }
        let made1 = await ssh.openTerminal()
        let terminal = try XCTUnwrap(made1)
        let made2 = await ssh.openCodeTab(directory: "/srv/shop")
        let (codeID, code) = try XCTUnwrap(made2)
        let server = RemoteHostServer(registry: registry,
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      localFeatures: RemoteConstants.localFeatures)
        server.start()
        defer { server.stop() }
        _ = await waitUntil { server.port != nil }
        let phone = try await rawPhone(server, features: Self.base + [RemoteFeature.codeTabs])
        defer { phone.link.close() }
        let first = try XCTUnwrap(phone.inbox.codeTabs.first?.first)
        XCTAssertEqual(first.id, codeID)
        XCTAssertEqual(first.serverID, ssh.host)
        XCTAssertEqual(first.serverName, ssh.hostName)
        XCTAssertEqual(first.slot, 1, "排在终端标签页后面")

        let run = try XCTUnwrap(code.startNewSession(tool: .claude, in: "/srv/shop"))
        let listed = await waitUntil { phone.inbox.firstIndex(ofSessionsListing: run.id) != nil }
        XCTAssertTrue(listed)
        let list = try XCTUnwrap(phone.inbox.firstIndex(ofSessionsListing: run.id))
        let owner = try XCTUnwrap(phone.inbox.firstIndex(ofCodeTabsWith: run.id), "列表之前先发归属")
        XCTAssertLessThan(owner, list)
        let sessions = try XCTUnwrap(phone.inbox.of(.sessions).last.flatMap {
            try? RemoteJSON.decode([RemoteSessionInfo].self, from: $0.payload)
        })
        XCTAssertEqual(sessions.first { $0.id == run.id }?.serverID, ssh.host)

        let before = phone.inbox.all.count
        let codeTab = try XCTUnwrap(ssh.workspace.terminalGroups.allTabs.first { $0.payload.id == codeID }?.id)
        ssh.workspace.moveCodeRunToTab(run.id, fromCodeTab: codeTab)
        // 挪出去的标签排到最前（同 Mac 上拖过去）：列表顺序变了才重推。
        let terminalTab = try XCTUnwrap(ssh.workspace.terminalGroups.allTabs.first { $0.payload.id == terminal }?.id)
        ssh.workspace.terminalGroups.arrangeTabs(by: [run.id, codeTab, terminalTab]) { $0.id }
        let reordered = await waitUntil {
            phone.inbox.index(after: before) { message in
                message.kind == .sessions
                    && (try? RemoteJSON.decode([RemoteSessionInfo].self, from: message.payload))?.macTabOrder == [run.id, terminal]
            } != nil
        }
        XCTAssertTrue(reordered)
        let reorderedList = try XCTUnwrap(phone.inbox.index(after: before) { message in
            message.kind == .sessions
                && (try? RemoteJSON.decode([RemoteSessionInfo].self, from: message.payload))?.macTabOrder == [run.id, terminal]
        })
        let released = try XCTUnwrap(phone.inbox.index(after: before) { message in
            message.kind == .codeTabs
                && (try? RemoteJSON.decode(RemoteCodeTabsUpdate.self, from: message.payload))?.tabs.first?.runs.isEmpty == true
        })
        XCTAssertLessThan(released, reorderedList)
    }
}

/// 原始手机收到的消息（连接队列上写，测试读）。
private final class CodeTabInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [RemoteMessage] = []
    func add(_ m: RemoteMessage) { lock.lock(); messages.append(m); lock.unlock() }
    var all: [RemoteMessage] { lock.lock(); defer { lock.unlock() }; return messages }
    func of(_ kind: RemoteMessage.Kind) -> [RemoteMessage] { all.filter { $0.kind == kind } }

    var codeTabs: [[RemoteCodeTabInfo]] {
        of(.codeTabs).compactMap { try? RemoteJSON.decode(RemoteCodeTabsUpdate.self, from: $0.payload).tabs }
    }

    func index(after start: Int, where match: (RemoteMessage) -> Bool) -> Int? {
        let all = self.all
        guard start < all.count else { return nil }
        return all[start...].firstIndex(where: match)
    }

    func firstIndex(ofSessionsListing id: UUID) -> Int? {
        index(after: 0) { message in
            message.kind == .sessions
                && ((try? RemoteJSON.decode([RemoteSessionInfo].self, from: message.payload))?.contains { $0.id == id } ?? false)
        }
    }

    func firstIndex(ofCodeTabsWith id: UUID) -> Int? {
        index(after: 0) { message in
            message.kind == .codeTabs
                && ((try? RemoteJSON.decode(RemoteCodeTabsUpdate.self, from: message.payload))?
                    .tabs.contains { $0.runs.contains { $0.session == id } } ?? false)
        }
    }
}
