import XCTest
@preconcurrency import Network
@testable import uTerm

/// 设备请 Mac 在它的 Code 标签页里做一件事（64 号消息 `codeTabAction`、65 号回复）：真的 `RemoteMacClient` 对真的
/// `RemoteHostServer`。落点先换成假的（只看线路：会话 id 与失败原因原样回来、连接不断），再接上真的本机终端窗口
///（`LocalShellCodeTabActions`，shell 是假后端）：新起的会话随后出现在 Mac 推来的 Code 标签页（63）里。
/// 经远控进程转给 App 的那条路见 `RemoteHostAgentTests.test_code_tab_action_is_done_by_the_app_through_the_agent`。
@MainActor
final class RemoteCodeTabActionTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func pairedClient(registry: TerminalSessionRegistry, features: [String] = RemoteConstants.localFeatures,
                              actor: RemoteCodeTabActor) async throws -> (RemoteHostServer, RemoteMacClient) {
        let server = RemoteHostServer(registry: registry,
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false, localFeatures: features)
        server.codeTabActions = actor
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
        return (server, client)
    }

    func test_wire_kinds_and_payloads_round_trip() throws {
        XCTAssertEqual(RemoteMessage.Kind.codeTabAction.rawValue, 64)
        XCTAssertEqual(RemoteMessage.Kind.codeTabActionResult.rawValue, 65)
        let action = RemoteCodeTabAction(action: .resume, tab: UUID(), path: "/Users/me/.claude/projects/x/a.jsonl",
                                         tool: AgentHistoryTool.claude.rawValue, sessionID: "a", directory: "/Users/me/app")
        XCTAssertEqual(try RemoteJSON.decode(RemoteCodeTabAction.self, from: RemoteJSON.encode(action)), action)
        let result = RemoteCodeTabActionResult.success(action, session: UUID())
        XCTAssertEqual(try RemoteJSON.decode(RemoteCodeTabActionResult.self, from: RemoteJSON.encode(result)), result)
        XCTAssertEqual(RemoteCodeTabActionResult.failure(action, "不行").requestID, action.requestID)
    }

    /// 落点回的会话 id / 失败原因原样到设备；失败不断开连接。
    func test_client_gets_the_session_or_the_reason() async throws {
        let made = UUID()
        let received = ReceivedActions()
        let actor = RemoteCodeTabActor { action in
            received.actions.append(action)
            return action.knownAction == .start ? .success(action, session: made)
                : .failure(action, "这个会话还在运行，结束之后才能重新开始")
        }
        let (server, client) = try await pairedClient(registry: TerminalSessionRegistry(), actor: actor)
        defer { server.stop() }
        XCTAssertTrue(client.supportsCodeTabActions)

        let start = RemoteCodeTabAction(action: .start, tool: AgentHistoryTool.codex.rawValue, directory: "/Users/me/app")
        let id = try await client.performCodeTabAction(start)
        XCTAssertEqual(id, made)
        XCTAssertEqual(received.actions, [start], "请求原样到了 Mac")

        do {
            _ = try await client.performCodeTabAction(RemoteCodeTabAction(action: .restart, session: UUID()))
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error.localizedDescription, "这个会话还在运行，结束之后才能重新开始")
        }
        XCTAssertEqual(client.state, .connected, "被拒不断开连接")
    }

    /// Mac 没接上落点（`unavailable`）：回原因，不断开。
    func test_mac_without_a_performer_refuses() async throws {
        let (server, client) = try await pairedClient(registry: TerminalSessionRegistry(), actor: .unavailable)
        defer { server.stop() }
        do {
            _ = try await client.performCodeTabAction(RemoteCodeTabAction(action: .start, tool: "claude", directory: "/tmp"))
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error.localizedDescription, String(localized: "这台 Mac 不能在 Code 标签页里替设备开会话"))
        }
        XCTAssertEqual(client.state, .connected)
    }

    /// 老 Mac（握手不带 `code-tab-actions`）：设备不发，直接报版本太旧（老 Mac 收到未知消息会断开）。
    func test_old_mac_is_not_asked() async throws {
        let received = ReceivedActions()
        let actor = RemoteCodeTabActor { action in
            received.actions.append(action)
            return .success(action, session: UUID())
        }
        let features = RemoteConstants.localFeatures.filter { $0 != RemoteFeature.codeTabActions }
        let (server, client) = try await pairedClient(registry: TerminalSessionRegistry(), features: features, actor: actor)
        defer { server.stop() }
        XCTAssertFalse(client.supportsCodeTabActions)
        do {
            _ = try await client.performCodeTabAction(RemoteCodeTabAction(action: .start, tool: "claude", directory: "/tmp"))
            XCTFail("应当失败")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("版本太旧"), error.localizedDescription)
        }
        XCTAssertTrue(received.actions.isEmpty)
        XCTAssertEqual(client.state, .connected)
    }

    /// 接上真的本机终端窗口：设备新开的会话起在 Mac 的 Code 标签页里，随后出现在 Mac 推来的 Code 标签页（63）里，
    /// 而不是成了一个终端标签页。
    func test_new_session_reaches_the_phone_in_code_tabs() async throws {
        let registry = TerminalSessionRegistry()
        let model = LocalShellWindowModel(startShell: { pane in
            Task { await pane.session.connect(using: MockBackend()) }
        })
        let windowID = UUID()
        model.attach(TerminalSessionRegistrar(registry: registry, windowID: windowID, windowKind: TerminalWindowKind.terminal))
        registry.setTabOrder(forWindow: windowID) { [weak model] in
            model?.groups.snapshot(LocalShellWindowModel.heldSessionID).tabOrder ?? []
        }
        registry.setCodeTabs(forWindow: windowID) { [weak model] in model?.remoteCodeTabs() ?? [] }
        defer { model.disposeAll() }
        let codeID = model.openCodeTab(directory: "/srv/shop")
        let code = try XCTUnwrap(model.groups.tab(codeID)?.payload.codeTab)
        let history = AgentHistoryModel(source: AgentHistoryFakeSource(tool: .claude, sessions: []),
                                        preferredDirectory: "/srv/shop", followsCurrentProject: false)
        await history.start()
        code.install(AgentHistoryConnection(history: history))

        let actor = RemoteCodeTabActor { [weak model] action in
            await LocalShellCodeTabActions.perform(action, windows: model.map { [$0] } ?? [],
                                                   openWindow: { _ in .failure(.init(message: "不该开窗口")) })
        }
        let (server, client) = try await pairedClient(registry: registry, actor: actor)
        defer { server.stop() }
        let mirrored = await waitUntil { client.codeTabs?.first?.id == codeID }
        XCTAssertTrue(mirrored)

        let id = try await client.performCodeTabAction(RemoteCodeTabAction(
            action: .start, tab: codeID, tool: AgentHistoryTool.claude.rawValue, directory: "/srv/shop"))
        XCTAssertEqual(code.runs.map(\.id), [id])
        let arrived = await waitUntil { client.codeTabs?.first?.runs.contains { $0.session == id } == true }
        XCTAssertTrue(arrived, "63 号消息里有新会话")
        let listed = await waitUntil { client.sessions.contains { $0.id == id } }
        XCTAssertTrue(listed, "会话列表里也有它（设备按 63 认出它归 Code 标签页）")
    }

    /// SSH 主机的 Code 标签页（64 号消息带 `server`）：真的工作区窗口里起会话，带着主机出现在 Mac 推来的 Code 标签页（63）
    /// 里；那台主机没有窗口时回原因、不断开，也不落到本机终端上。
    func test_ssh_host_session_reaches_the_phone_in_code_tabs() async throws {
        let registry = TerminalSessionRegistry()
        let ssh = SSHCodeTabWindowRig(registry: registry)
        defer { ssh.dispose() }
        let made1 = await ssh.openCodeTab(directory: "/srv/shop")
        let (codeID, code) = try XCTUnwrap(made1)
        let actor = RemoteCodeTabActor { [weak registry] action in
            await RemoteCodeTabActor.route(action, localWindows: [], workspaces: registry?.codeTabWorkspaces() ?? [],
                                           openLocalWindow: { _ in .failure(.init(message: "不该开本机终端窗口")) })
        }
        let (server, client) = try await pairedClient(registry: registry, actor: actor)
        defer { server.stop() }
        XCTAssertTrue(client.supportsCodeTabHosts)
        let mirrored = await waitUntil { client.codeTabs?.mirrored(serverID: ssh.host)?.id == codeID }
        XCTAssertTrue(mirrored, "SSH 主机的 Code 标签页也报了")
        XCTAssertNil(client.codeTabs?.mirrored(), "没有本机的")

        let id = try await client.performCodeTabAction(RemoteCodeTabAction(
            action: .start, tab: codeID, tool: AgentHistoryTool.claude.rawValue, directory: "/srv/shop", server: ssh.host))
        XCTAssertEqual(code.runs.map(\.id), [id])
        let arrived = await waitUntil {
            client.codeTabs?.mirrored(serverID: ssh.host)?.runs.contains { $0.session == id } == true
        }
        XCTAssertTrue(arrived, "63 号消息里有新会话")
        XCTAssertEqual(client.codeRunSessionIDs(serverIDs: [ssh.host]), [id])
        XCTAssertTrue(client.codeRunSessionIDs.isEmpty, "老的认法（只认本机的）不变")

        do {
            _ = try await client.performCodeTabAction(RemoteCodeTabAction(
                action: .start, tool: AgentHistoryTool.claude.rawValue, directory: "/srv/shop", server: UUID()))
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error.localizedDescription, WorkspaceCodeTabText.noHostWindow)
        }
        XCTAssertEqual(client.state, .connected)
    }
}

/// 落点收到的请求（测试里读）。
@MainActor
private final class ReceivedActions {
    var actions: [RemoteCodeTabAction] = []
}
