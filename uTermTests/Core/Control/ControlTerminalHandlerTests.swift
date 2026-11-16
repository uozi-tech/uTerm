import XCTest
import SwiftData
@testable import uTerm

/// 终端组四个动作的门禁与语义。用真实的 `TerminalSession`（离屏 `TerminalView`，
/// 不需要窗口）+ `MockBackend`，所以读屏与注入都是真跑，不是替身。
@MainActor
final class ControlTerminalHandlerTests: XCTestCase {

    // MARK: 夹具

    /// 连接池在终端组用不到 —— 只有 `ping.openHosts` 会问它要 id。
    private actor StubPool: ControlConnectionPooling {
        func executor(
            for host: HostConnectionSpec,
            maxLines: Int,
            maxBytes: Int
        ) async throws -> SSHCommandExecutor {
            throw ControlConnectError.connectFailed("终端组用不到连接池")
        }
        func borrowSFTP(for host: HostConnectionSpec) async throws -> any SFTPProviding {
            throw ControlConnectError.connectFailed("终端组用不到连接池")
        }

        func returnSFTP(_ session: any SFTPProviding, for hostID: UUID) async {}
        func disconnect(hostID: UUID) async {}
        func disconnectAll() async {}
        func heldHostIDs() async -> [UUID] { [] }
        func lastHostKeyChallenge(hostID: UUID) async -> HostKeyChallenge? { nil }
        func recordChallenge(hostID: UUID, _ challenge: HostKeyChallenge) async {}
        func trustHostKey(host: HostConnectionSpec, fingerprint: String) async throws {
            throw ControlConnectError.connectFailed("终端组用不到连接池")
        }
    }

    private struct Fixture {
        let handler: ControlHandler
        let registry: TerminalSessionRegistry
        let settings: ControlSettings
        let container: ModelContainer
    }

    private func makeFixture(enabled: Bool = true, mutations: Bool = true) throws -> Fixture {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        // 终端组只碰 `ServerProfile`（判 sftpOnly / 解析主机），不需要整张 app schema
        //（`ChatSession` 那几张在 AgentKit 里，测试 target 里也拿不到）。
        let container = try ModelContainer(
            for: ServerProfile.self, KnownHost.self, configurations: config)
        // 独立 suite：别把开关写进用户的 UserDefaults。
        let defaults = UserDefaults(suiteName: "uterm.tests.control.\(UUID().uuidString)")!
        let settings = ControlSettings(defaults: defaults)
        settings.isEnabled = enabled
        settings.allowMutations = mutations
        let registry = TerminalSessionRegistry()
        let handler = ControlHandler(
            settings: settings,
            modelContainer: container,
            forwardingCoordinator: ForwardingCoordinator(),
            pool: StubPool(),
            registry: registry)
        return Fixture(handler: handler, registry: registry, settings: settings, container: container)
    }

    @discardableResult
    private func insertProfile(
        _ fixture: Fixture,
        name: String,
        sftpOnly: Bool = false
    ) -> ServerProfile {
        let profile = ServerProfile()
        profile.name = name
        profile.host = "10.0.0.1"
        profile.username = "root"
        profile.sftpOnly = sftpOnly
        fixture.container.mainContext.insert(profile)
        try? fixture.container.mainContext.save()
        return profile
    }

    /// 建一条**真连上**的会话并登记。返回 (entry, session, backend)。
    private func attachSession(
        _ fixture: Fixture,
        serverID: UUID = UUID(),
        serverName: String = "prod-web",
        windowKind: String = TerminalWindowKind.workspace,
        connect: Bool = true
    ) async -> (entry: TerminalSessionEntry, session: TerminalSession, backend: MockBackend) {
        let session = TerminalSession()
        let backend = MockBackend()
        if connect { await session.connect(using: backend) }
        let entry = TerminalSessionEntry(
            id: UUID(), serverID: serverID, serverName: serverName,
            windowID: UUID(), windowKind: windowKind, title: serverName,
            connectedAt: Date())
        fixture.registry.register(entry, session: session)
        return (entry, session, backend)
    }

    /// 往会话里喂 VT 字节（和正式路径同一条链：影子终端解析，不等节拍；见 `TerminalSessionTestFeed`）。
    private func feed(_ session: TerminalSession, _ text: String) {
        session.feedOutput(text: text)
    }

    // MARK: terminals

    func testTerminalsListsRegisteredSessions() async throws {
        let fixture = try makeFixture()
        // 两条都要**用局部变量接住**：注册表只弱引用会话，`_ =` 会让它当场释放，
        // 那条 entry 随即被当成幻影行清掉（见 `testTerminalReadOnReleasedSessionIsNotFound`）。
        let a = await attachSession(fixture, serverName: "web-1")
        let b = await attachSession(fixture, serverName: "db-1",
                                    windowKind: TerminalWindowKind.terminal)

        let response = await fixture.handler.handle(ControlRequest(action: .terminals))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.terminals?.count, 2)
        XCTAssertEqual(response.terminals?.first?.id, a.entry.id.uuidString)
        XCTAssertEqual(response.terminals?.first?.serverName, "web-1")
        XCTAssertEqual(response.terminals?.last?.id, b.entry.id.uuidString)
        XCTAssertEqual(response.terminals?.last?.windowKind, "terminal")
    }

    func testTerminalsIsEmptyWithoutSessions() async throws {
        let fixture = try makeFixture()
        let response = await fixture.handler.handle(ControlRequest(action: .terminals))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.terminals, [])
    }

    // MARK: terminal-read

    func testTerminalReadReturnsScreenText() async throws {
        let fixture = try makeFixture()
        let attached = await attachSession(fixture)
        feed(attached.session, "alpha\r\nbeta\r\ngamma\r\n")

        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalRead, terminal: attached.entry.id.uuidString))
        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.screen?.terminal, attached.entry.id.uuidString)
        XCTAssertEqual(response.screen?.lines, ["alpha", "beta", "gamma"])
        XCTAssertEqual(response.screen?.truncated, false)
    }

    func testTerminalReadHonoursLineLimit() async throws {
        let fixture = try makeFixture()
        let attached = await attachSession(fixture)
        feed(attached.session, (1...10).map { "row\($0)\r\n" }.joined())

        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalRead, terminal: attached.entry.id.uuidString, lines: 3))
        XCTAssertEqual(response.screen?.lines, ["row8", "row9", "row10"])
        XCTAssertEqual(response.screen?.truncated, true)
    }

    /// 回归：**尾部空行超过一屏**时也要读得回内容。
    ///
    /// 旧实现只从缓冲区末尾往上多取一屏（`lines + rows`），而
    /// `TerminalScreenReader.trim` 会把尾随空行**全部**去掉 —— `clear` 之后、
    /// TUI 退出之后那种几百行空白尾巴，会把多取的一屏整个吃掉，读屏返回空数组。
    func testTerminalReadSkipsBlankTailLongerThanOneScreen() async throws {
        let fixture = try makeFixture()
        let attached = await attachSession(fixture)
        feed(attached.session, "alpha\r\nbeta\r\ngamma\r\n")
        feed(attached.session, String(repeating: "\r\n", count: 200))

        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalRead, terminal: attached.entry.id.uuidString, lines: 3))
        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.screen?.lines, ["alpha", "beta", "gamma"])
    }

    func testTerminalReadOnEmptyBufferReturnsNoLines() async throws {
        let fixture = try makeFixture()
        let attached = await attachSession(fixture)
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalRead, terminal: attached.entry.id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.screen?.lines, [])
    }

    /// 读屏**不**受改动开关管（它是只读的）。
    func testTerminalReadWorksWithMutationsDisabled() async throws {
        let fixture = try makeFixture(mutations: false)
        let attached = await attachSession(fixture)
        feed(attached.session, "hello\r\n")
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalRead, terminal: attached.entry.id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.screen?.lines, ["hello"])
    }

    func testTerminalReadNeedsMainSwitch() async throws {
        let fixture = try makeFixture(enabled: false)
        let attached = await attachSession(fixture)
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalRead, terminal: attached.entry.id.uuidString))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, ControlErrorCode.control_disabled.rawValue)
    }

    func testTerminalReadWithoutTerminalArgIsInvalid() async throws {
        let fixture = try makeFixture()
        let response = await fixture.handler.handle(ControlRequest(action: .terminalRead))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    func testTerminalReadUnknownSessionIsNotFound() async throws {
        let fixture = try makeFixture()
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalRead, terminal: UUID().uuidString))
        XCTAssertEqual(response.code, ControlErrorCode.terminal_not_found.rawValue)
    }

    /// 会话对象已释放（窗口没走 dispose 就没了）→ 注册表把那条 entry 一起清掉，
    /// 于是既不再出现在 `terminals` 里，读它也是 `terminal_not_found`。
    /// （从前只清弱引用槽、留着 entry，`terminals` 会永远列着一条读不了的幻影行。）
    func testTerminalReadOnReleasedSessionIsNotFound() async throws {
        let fixture = try makeFixture()
        let entry = TerminalSessionEntry(
            id: UUID(), serverID: UUID(), serverName: "gone",
            windowID: UUID(), windowKind: TerminalWindowKind.workspace, title: "gone")
        do {
            let session = TerminalSession()
            fixture.registry.register(entry, session: session)
        }
        let listed = await fixture.handler.handle(ControlRequest(action: .terminals))
        XCTAssertEqual(listed.terminals, [])

        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalRead, terminal: entry.id.uuidString))
        XCTAssertEqual(response.code, ControlErrorCode.terminal_not_found.rawValue)
    }

    /// 远端退出（`exitStream`）后窗格注销自己 —— `terminals` 不再列它，
    /// `terminal-read` 也不会再回同一张冻结的画面。
    func testDisconnectedPaneDropsOutOfTerminals() async throws {
        let fixture = try makeFixture()
        let pane = PaneModel(serverProfileID: UUID())
        pane.registrar = TerminalSessionRegistrar(
            registry: fixture.registry,
            windowID: UUID(),
            windowKind: TerminalWindowKind.workspace)
        let backend = MockBackend()
        await pane.session.connect(using: backend)
        // 生产路径上这一步由 `PaneModel.connect` 做（它那时才知道服务器名）。
        pane.registrar?.register(paneID: pane.id, serverID: pane.serverProfileID,
                                 serverName: "prod-web", session: pane.session)

        var listed = await fixture.handler.handle(ControlRequest(action: .terminals))
        XCTAssertEqual(listed.terminals?.count, 1)

        await backend.emitExit()
        for _ in 0..<200 where pane.session.connectionState != .disconnected {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pane.session.connectionState, .disconnected)

        listed = await fixture.handler.handle(ControlRequest(action: .terminals))
        XCTAssertEqual(listed.terminals, [])
    }

    // MARK: terminal-send

    func testTerminalSendWritesBytesWithCarriageReturn() async throws {
        let fixture = try makeFixture()
        let attached = await attachSession(fixture)
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalSend, terminal: attached.entry.id.uuidString,
            text: "uptime", enter: true))
        XCTAssertTrue(response.ok, response.message)
        let written = await attached.backend.writtenData
        XCTAssertEqual(written.map { String(decoding: $0, as: UTF8.self) }, ["uptime\r"])
    }

    func testTerminalSendWithoutEnterOmitsCarriageReturn() async throws {
        let fixture = try makeFixture()
        let attached = await attachSession(fixture)
        _ = await fixture.handler.handle(ControlRequest(
            action: .terminalSend, terminal: attached.entry.id.uuidString, text: "uptime"))
        let written = await attached.backend.writtenData
        XCTAssertEqual(written.map { String(decoding: $0, as: UTF8.self) }, ["uptime"])
    }

    func testTerminalSendNeedsMutationSwitch() async throws {
        let fixture = try makeFixture(mutations: false)
        let attached = await attachSession(fixture)
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalSend, terminal: attached.entry.id.uuidString, text: "uptime"))
        XCTAssertEqual(response.code, ControlErrorCode.mutations_disabled.rawValue)
        let written = await attached.backend.writtenData
        XCTAssertTrue(written.isEmpty)
    }

    func testTerminalSendRejectsEmptyText() async throws {
        let fixture = try makeFixture()
        let attached = await attachSession(fixture)
        for request in [
            ControlRequest(action: .terminalSend, terminal: attached.entry.id.uuidString),
            ControlRequest(action: .terminalSend, terminal: attached.entry.id.uuidString, text: "")
        ] {
            let response = await fixture.handler.handle(request)
            XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
        }
    }

    /// 主机级硬规则：`sftpOnly` 的主机拒绝终端注入。
    func testTerminalSendRejectsSFTPOnlyHost() async throws {
        let fixture = try makeFixture()
        let profile = insertProfile(fixture, name: "files-only", sftpOnly: true)
        let attached = await attachSession(fixture, serverID: profile.id, serverName: profile.name)
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalSend, terminal: attached.entry.id.uuidString, text: "rm -rf /"))
        XCTAssertEqual(response.code, ControlErrorCode.host_sftp_only.rawValue)
        let written = await attached.backend.writtenData
        XCTAssertTrue(written.isEmpty)
    }

    /// 会话还在但连接已断（远端退出）→ `terminal_disconnected`，不静默丢字节。
    func testTerminalSendOnDisconnectedSessionFails() async throws {
        let fixture = try makeFixture()
        let attached = await attachSession(fixture, connect: false)
        XCTAssertEqual(attached.session.connectionState, .idle)
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalSend, terminal: attached.entry.id.uuidString, text: "uptime"))
        XCTAssertEqual(response.code, ControlErrorCode.terminal_disconnected.rawValue)
    }

    func testTerminalSendAmbiguousPrefix() async throws {
        let fixture = try makeFixture()
        let a = TerminalSessionEntry(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            serverID: UUID(), serverName: "a", windowID: UUID(),
            windowKind: TerminalWindowKind.workspace, title: "a")
        let b = TerminalSessionEntry(
            id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!,
            serverID: UUID(), serverName: "b", windowID: UUID(),
            windowKind: TerminalWindowKind.workspace, title: "b")
        fixture.registry.register(a)
        fixture.registry.register(b)
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalSend, terminal: "AAAAAAAA", text: "x"))
        XCTAssertEqual(response.code, ControlErrorCode.terminal_ambiguous.rawValue)
    }

    // MARK: terminal-open

    func testTerminalOpenNeedsMutationSwitch() async throws {
        let fixture = try makeFixture(mutations: false)
        let profile = insertProfile(fixture, name: "web")
        var opened = false
        fixture.registry.openTerminalWindow = { _ in opened = true; return UUID() }
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalOpen, host: profile.name))
        XCTAssertEqual(response.code, ControlErrorCode.mutations_disabled.rawValue)
        XCTAssertFalse(opened)
    }

    func testTerminalOpenRejectsSFTPOnlyHost() async throws {
        let fixture = try makeFixture()
        let profile = insertProfile(fixture, name: "files-only", sftpOnly: true)
        var opened = false
        fixture.registry.openTerminalWindow = { _ in opened = true; return UUID() }
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalOpen, host: profile.name))
        XCTAssertEqual(response.code, ControlErrorCode.host_sftp_only.rawValue)
        XCTAssertFalse(opened)
    }

    func testTerminalOpenWithoutHostIsInvalid() async throws {
        let fixture = try makeFixture()
        let response = await fixture.handler.handle(ControlRequest(action: .terminalOpen))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    /// 没接上开窗口入口（app 还没起完）→ `app_not_ready`，不是崩。
    func testTerminalOpenWithoutHookIsNotReady() async throws {
        let fixture = try makeFixture()
        let profile = insertProfile(fixture, name: "web")
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalOpen, host: profile.name))
        XCTAssertEqual(response.code, ControlErrorCode.app_not_ready.rawValue)
    }

    /// 开窗口后等到会话注册上来，回它的 id。
    func testTerminalOpenWaitsForSessionToRegister() async throws {
        let fixture = try makeFixture()
        let profile = insertProfile(fixture, name: "web")
        let registry = fixture.registry
        let entryID = UUID()
        registry.openTerminalWindow = { serverID in
            let windowID = UUID()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                registry.register(TerminalSessionEntry(
                    id: entryID, serverID: serverID, serverName: "web",
                    windowID: windowID, windowKind: TerminalWindowKind.terminal,
                    title: "web", connectedAt: Date()))
            }
            return windowID
        }
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalOpen, host: profile.name))
        XCTAssertTrue(response.ok, response.message)
        XCTAssertEqual(response.terminals?.first?.id, entryID.uuidString)
    }

    func testTerminalOpenUnknownHost() async throws {
        let fixture = try makeFixture()
        fixture.registry.openTerminalWindow = { _ in UUID() }
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalOpen, host: "查无此机"))
        XCTAssertEqual(response.code, ControlErrorCode.host_not_found.rawValue)
    }

    // MARK: terminal-open -- <命令> / terminal-wait

    /// 开窗口时注册一条真连上的会话，返回 (handler 要的 profile 名, 会话, 后端)。
    private func openWithLiveSession(
        _ fixture: Fixture
    ) async -> (session: TerminalSession, backend: MockBackend, entryID: UUID) {
        let profile = insertProfile(fixture, name: "mac-01")
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        let entryID = UUID()
        let registry = fixture.registry
        registry.openTerminalWindow = { serverID in
            let windowID = UUID()
            registry.register(TerminalSessionEntry(
                id: entryID, serverID: serverID, serverName: profile.name,
                windowID: windowID, windowKind: TerminalWindowKind.terminal,
                title: profile.name, connectedAt: Date()), session: session)
            return windowID
        }
        return (session, backend, entryID)
    }

    /// 远端 shell 的行编辑器起来了（打开括号粘贴），等命令打进来，返回打进来的那一行（含回车）。
    private func lineEditorReady(_ live: (session: TerminalSession, backend: MockBackend, entryID: UUID),
                                 prompt: String = "% ") async throws -> String {
        feed(live.session, prompt + "\u{1B}[?2004h")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let written = await live.backend.writtenData.map { String(decoding: $0, as: UTF8.self) }.joined()
            if !written.isEmpty { return written }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("行编辑器起来之后命令没打进来")
        return ""
    }

    /// 后端收到的那一行里抠出标记 id（`…;S;<id>\007'`）。
    private func markerID(_ backend: MockBackend) async throws -> String {
        let written = await backend.writtenData.map { String(decoding: $0, as: UTF8.self) }.joined()
        let range = try XCTUnwrap(written.range(of: "6973;S;"))
        return String(written[range.upperBound...].prefix(8))
    }

    func testTerminalOpenRunsTheCommandAndWaitReturnsExitCodeAndOutput() async throws {
        let fixture = try makeFixture()
        let live = await openWithLiveSession(fixture)

        let opened = await fixture.handler.handle(ControlRequest(
            action: .terminalOpen, host: "mac-01", args: ["sudo", "./bootstrap.zsh", "--only-root-entry"]))
        XCTAssertTrue(opened.ok, opened.message)
        XCTAssertEqual(opened.run?.command, "sudo ./bootstrap.zsh --only-root-entry")
        XCTAssertEqual(opened.run?.state, "pending")

        try await Task.sleep(for: .milliseconds(100))
        let early = await live.backend.writtenData
        XCTAssertTrue(early.isEmpty, "远端的行编辑器还没起来就不打：早打的字会被终端驱动先回显一遍")
        let written = try await lineEditorReady(live)
        XCTAssertTrue(written.contains("; (sudo ./bootstrap.zsh --only-root-entry); "), "命令原样打进窗口（包在子 shell 里），用户看得懂")
        XCTAssertTrue(written.hasSuffix("\"$?\"\r"), "末尾回车执行，并带出退出码")
        let id = try await markerID(live.backend)

        // 远端：行编辑器回显这一行 → 开始标记 → 要密码（用户在窗口里输，没有回显）→ 输出 → 结束标记。
        feed(live.session, "\(written.dropLast())\r\n\u{1B}]6973;S;\(id)\u{07}"
            + "[sudo] password for uozi:\r\nupdated to 1.3.0\r\n\u{1B}]6973;D;\(id);3\u{07}% ")

        let screen = live.session.shadow.viewportText()
        XCTAssertFalse(screen.contains("6973"), "回显里的包装改写掉了：\(screen)")
        XCTAssertTrue(screen.contains("% sudo ./bootstrap.zsh --only-root-entry\n[sudo] password for uozi:"), screen)

        let waited = await fixture.handler.handle(ControlRequest(
            action: .terminalWait, terminal: live.entryID.uuidString, waitSeconds: 2))
        XCTAssertTrue(waited.ok, waited.message)
        XCTAssertEqual(waited.run?.state, "finished")
        XCTAssertEqual(waited.run?.exitCode, 3)
        XCTAssertEqual(waited.run?.output, "[sudo] password for uozi:\nupdated to 1.3.0")
        XCTAssertNotNil(waited.run?.finishedAt)
    }

    func testTerminalWaitReturnsRunningWithPartialOutputWhenTimeIsUp() async throws {
        let fixture = try makeFixture()
        let live = await openWithLiveSession(fixture)
        _ = await fixture.handler.handle(ControlRequest(action: .terminalOpen, host: "mac-01", command: "apt upgrade"))
        _ = try await lineEditorReady(live)
        let id = try await markerID(live.backend)
        feed(live.session, "\r\n\u{1B}]6973;S;\(id)\u{07}Reading package lists...\r\nDo you want to continue? [Y/n] ")

        let waited = await fixture.handler.handle(ControlRequest(
            action: .terminalWait, terminal: live.entryID.uuidString, waitSeconds: 0.3))
        XCTAssertTrue(waited.ok, waited.message)
        XCTAssertEqual(waited.run?.state, "running")
        XCTAssertNil(waited.run?.exitCode)
        XCTAssertEqual(waited.run?.output, "Reading package lists...\nDo you want to continue? [Y/n]")
    }

    /// 标记 id 对不上（之前那条命令的残留、用户自己 printf 的）一律不认。
    func testForeignMarkersAreIgnored() async throws {
        let fixture = try makeFixture()
        let live = await openWithLiveSession(fixture)
        _ = await fixture.handler.handle(ControlRequest(action: .terminalOpen, host: "mac-01", command: "true"))
        try await Task.sleep(for: .milliseconds(100))
        feed(live.session, "\u{1B}]6973;S;deadbeef\u{07}\u{1B}]6973;D;deadbeef;0\u{07}")
        let waited = await fixture.handler.handle(ControlRequest(
            action: .terminalWait, terminal: live.entryID.uuidString, waitSeconds: 0))
        XCTAssertEqual(waited.run?.state, "pending")
    }

    func testTerminalOpenRejectsMultilineCommands() async throws {
        let fixture = try makeFixture()
        _ = await openWithLiveSession(fixture)
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalOpen, host: "mac-01", command: "echo a\necho b"))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    func testTerminalWaitNeedsATrackedRun() async throws {
        let fixture = try makeFixture()
        let attached = await attachSession(fixture)
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalWait, terminal: attached.entry.id.uuidString, waitSeconds: 0))
        XCTAssertEqual(response.code, ControlErrorCode.invalid_request.rawValue)
    }

    /// 只读：改动开关关着也能等结果（开窗口跑命令那一步才要改动开关）。
    func testTerminalWaitWorksWithMutationsDisabled() async throws {
        let fixture = try makeFixture()
        let live = await openWithLiveSession(fixture)
        _ = await fixture.handler.handle(ControlRequest(action: .terminalOpen, host: "mac-01", command: "uptime"))
        fixture.settings.allowMutations = false
        let response = await fixture.handler.handle(ControlRequest(
            action: .terminalWait, terminal: live.entryID.uuidString, waitSeconds: 0))
        XCTAssertTrue(response.ok, response.message)
    }
}
