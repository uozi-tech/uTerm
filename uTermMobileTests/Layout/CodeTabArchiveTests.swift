import SwiftData
import XCTest
@testable import uTermMobile

/// App 被系统结束后重新打开：Code 标签页照原样开回来（`MobileTerminalTabArchive.codeTabs`），里面的会话带着原来的会话 id
/// 接回它里面；会话在 App 不在时已经结束的回到记录；旧版存的表照旧开、旧版读到新版的表不丢会话。
/// 终端接假传输，记录是手写的假数据源，不连任何真主机。
@MainActor
final class CodeTabArchiveTests: XCTestCase {

    /// 会话接回后问前台进程时答 `activity`；记下每次造后端时交来的会话 id。
    actor ProbeBackend: TerminalBackend {
        nonisolated let outputItems = AsyncStream<TerminalOutputItem> { _ in }
        nonisolated let exitStream = AsyncStream<Void> { _ in }
        private let activity: TerminalActivity
        init(activity: TerminalActivity) { self.activity = activity }
        func connect() async throws {}
        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async {}
        func foregroundActivity() async -> TerminalActivity { activity }
    }

    @MainActor
    final class ProbeFactory {
        var activity: TerminalActivity
        private(set) var requests: [(sessionID: UUID, resumes: Bool)] = []
        init(_ activity: TerminalActivity) { self.activity = activity }
        var transportFactory: MobileTerminalTransportFactory {
            MobileTerminalTransportFactory { [self] request in
                requests.append((request.sessionID, request.resumesSession))
                return ProbeBackend(activity: activity)
            }
        }
    }

    private static let prompt = MobileFakeTerminalScript.transcript("% \u{1B}[?2004h")
    private static var shop: String { MobileAgentHistoryFixture.shop }

    private var container: ModelContainer!
    private var host: ServerProfile!

    override func setUp() async throws {
        try await super.setUp()
        container = try MobileFixtures.modelContainer(seed: .smoke)
        host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
    }

    override func tearDown() async throws {
        MobileProbeWindow.closeAll()
        try await super.tearDown()
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "CodeTabArchiveTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func start(_ term: TermTab) {
        term.controller.start(profile: term.host, container: container, relay: HostKeyChallengeRelay())
    }

    private func makeCodeTab(_ host: ServerProfile, _ record: CodeTabRecord) -> ClaudeHistoryTab {
        MobileAgentHistoryFixture.tab(host: host, source: MobileAgentHistoryFixture.source(), directory: record.directory)
    }

    /// 一个开着终端标签页与 Code 标签页（里面一个继续的会话、一个新会话）的工作区，Code 标签页在前台、看着继续的那个。
    private func liveWorkspace() async throws
        -> (MobileWorkspace, TermTab, ClaudeHistoryTab, resumed: CodeRunBoard<TermTab>.Run, fresh: CodeRunBoard<TermTab>.Run) {
        let ws = MobileWorkspace()
        let (shell, _) = MobileFakeTerminal.tab(host: host, Self.prompt)
        start(shell)
        ws.open(.terminal(shell))
        let tab = MobileAgentHistoryFixture.tab(host: host, source: MobileAgentHistoryFixture.source())
        tab.runTerminalFactory = { host in MobileFakeTerminal.tab(host: host, Self.prompt).0 }
        ws.openHistory(tab)
        let settled = await MobileFakeClaudeHistory.settle(tab)
        XCTAssertTrue(settled)
        let model = try XCTUnwrap(tab.connection.history)
        let file = try XCTUnwrap(model.visibleFiles.first { $0.sessionID == "x-tests" })
        let plan = try XCTUnwrap(model.resumeCommand(for: file))
        tab.resumeInPlace(file, command: plan.command, directory: plan.directory, container: container,
                          relay: HostKeyChallengeRelay())
        let resumed = try XCTUnwrap(tab.runs.focused)
        let command = try XCTUnwrap(model.newSessionCommand(tool: .claude, directory: Self.shop))
        tab.startNewInPlace(tool: .claude, command: command, directory: Self.shop, container: container,
                            relay: HostKeyChallengeRelay())
        let fresh = try XCTUnwrap(tab.runs.focused)
        for run in [resumed, fresh] {
            let connected = await MobileFakeTerminal.waitUntilConnected(run.terminal.controller)
            XCTAssertTrue(connected)
        }
        tab.focusRun(resumed.id)
        return (ws, shell, tab, resumed, fresh)
    }

    // MARK: 记下来

    func testArchiveRecordsTheCodeTabAndKeepsItsRunsAsTerminalTabs() async throws {
        let (ws, shell, tab, resumed, fresh) = try await liveWorkspace()
        let archive = ws.terminalTabArchive(showsWorkspace: true)
        let sessions = [shell, resumed.terminal, fresh.terminal].map(\.controller.hostSessionID)
        XCTAssertEqual(archive.tabs.map(\.sessionID), sessions, "Code 标签页里的会话仍按终端标签页记（旧版读得懂）")
        XCTAssertEqual(archive.tabs.map(\.codeTab), [nil, tab.id, tab.id], "标明它们属于哪个 Code 标签页")
        let code = try XCTUnwrap(archive.codeTabs?.first)
        XCTAssertEqual(code.position, 1, "排在终端标签页后面")
        XCTAssertEqual(code.record.host, host.id)
        XCTAssertEqual(code.record.directory, Self.shop)
        XCTAssertEqual(code.record.runs.map(\.session), Array(sessions.dropFirst()))
        XCTAssertEqual(code.record.runs.map(\.sessionID), ["x-tests", nil], "对上了的记工具 + 会话 ID，新会话没有")
        XCTAssertEqual(code.record.runs.map(\.tool), ["codex", "claude"])
        XCTAssertEqual(code.record.selectedRun, resumed.terminal.controller.hostSessionID)
        XCTAssertEqual(archive.activeCodeTab, tab.id)
        XCTAssertEqual(archive.activeIndex, 1, "旧字段指着它看着的那个会话")
        let json = String(decoding: try JSONEncoder().encode(archive), as: UTF8.self)
        XCTAssertFalse(json.contains("订单服务") || json.contains(".jsonl"), "不存标题、记录文件的路径")

        // 看一份没在跑的记录：记那份记录。
        let model = try XCTUnwrap(tab.connection.history)
        tab.select(try XCTUnwrap(model.visibleFiles.first { $0.sessionID == "c-nginx" }))
        XCTAssertEqual(ws.terminalTabArchive(showsWorkspace: true).codeTabs?.first?.record.selectedRecord, "claude:c-nginx")
        shell.controller.close()
        tab.close()
    }

    func testEmptyCodeTabIsArchivedAndSaved() throws {
        let ws = MobileWorkspace()
        let tab = MobileAgentHistoryFixture.tab(host: host, source: MobileAgentHistoryFixture.source())
        ws.openHistory(tab)
        let archive = ws.terminalTabArchive(showsWorkspace: true)
        XCTAssertTrue(archive.tabs.isEmpty)
        XCTAssertEqual(archive.codeTabs?.map(\.record.id), [tab.id])
        XCTAssertTrue(archive.showsWorkspace)
        let defaults = try makeDefaults()
        archive.save(to: defaults)
        XCTAssertEqual(MobileTerminalTabArchive.load(from: defaults), archive, "里面没有会话在跑的也存")
        tab.close()
    }

    // MARK: 开回来

    func testRestoreReopensTheCodeTabWithItsRunsInside() async throws {
        let shellSession = UUID(), resumedSession = UUID(), freshSession = UUID(), codeID = UUID()
        var archive = MobileTerminalTabArchive()
        archive.tabs = [.init(hostID: host.id, sessionID: shellSession),
                        .init(hostID: host.id, sessionID: resumedSession, codeTab: codeID),
                        .init(hostID: host.id, sessionID: freshSession, codeTab: codeID)]
        archive.codeTabs = [.init(position: 1, record: CodeTabRecord(id: codeID, host: host.id, directory: Self.shop, runs: [
            CodeRunRecord(session: resumedSession, tool: .codex, sessionID: "x-tests", directory: Self.shop,
                          startedAt: Date().addingTimeInterval(-600)),
            CodeRunRecord(session: freshSession, tool: .claude, sessionID: nil, directory: Self.shop,
                          startedAt: Date().addingTimeInterval(-60)),
        ], selectedRun: resumedSession))]
        archive.activeIndex = 1
        archive.activeCodeTab = codeID
        let defaults = try makeDefaults()
        archive.save(to: defaults)
        let loaded = MobileTerminalTabArchive.load(from: defaults)
        XCTAssertEqual(loaded, archive)

        let ws = MobileWorkspace()
        let factory = ProbeFactory(.running("codex"))
        let opened = loaded.restore(into: ws, hosts: [host], transportFactory: factory.transportFactory,
                                    makeCodeTab: makeCodeTab, start: start)
        XCTAssertEqual(ws.tabs.count, 2, "终端标签页 + Code 标签页，里面的会话不再各开一个")
        XCTAssertEqual(ws.terminalTabs.map(\.controller.hostSessionID), [shellSession])
        let code = try XCTUnwrap(ws.tabs.last?.history)
        XCTAssertEqual(ws.activeTab?.id, code.id, "它原来在前台")
        XCTAssertEqual(code.runs.runs.map(\.terminal.controller.hostSessionID), [resumedSession, freshSession])
        XCTAssertEqual(code.runs.focused?.terminal.controller.hostSessionID, resumedSession, "看的还是继续的那个")
        XCTAssertEqual(Set(opened.map(\.controller.hostSessionID)), [shellSession, resumedSession, freshSession])
        XCTAssertEqual(ws.allTerminals.count, 3, "照终端标签页那样算（键盘、实时活动、归档）")
        for term in opened {
            let connected = await MobileFakeTerminal.waitUntilConnected(term.controller)
            XCTAssertTrue(connected)
        }
        XCTAssertEqual(Set(factory.requests.map(\.sessionID)), [shellSession, resumedSession, freshSession])
        XCTAssertTrue(factory.requests.allSatisfy(\.resumes), "走保持进程的接回路径")

        let settled = await MobileFakeClaudeHistory.settle(code)
        XCTAssertTrue(settled)
        let model = try XCTUnwrap(code.connection.history)
        let resolved = await MobileFakeTerminal.waitUntil { code.runs.runs.first?.sessionPath != nil }
        XCTAssertTrue(resolved, "列表读出来后对回原来的记录")
        XCTAssertEqual(code.runs.runs.first?.sessionPath, model.files.first { $0.sessionID == "x-tests" }?.path)
        XCTAssertEqual(model.selectedFile?.sessionID, "x-tests")
        XCTAssertTrue(code.runs.runs.last?.isNewSession == true, "新会话照旧等着对记录")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(code.runs.runs.count, 2, "前台还有程序：当它还在跑")

        // 开回来之后的归档和之前对得上。
        let again = ws.terminalTabArchive(showsWorkspace: false)
        XCTAssertEqual(again.tabs.map(\.sessionID), archive.tabs.map(\.sessionID))
        XCTAssertEqual(again.codeTabs?.first?.record.runs.map(\.session), [resumedSession, freshSession])
        XCTAssertEqual(again.activeCodeTab, code.id)
        opened.forEach { $0.controller.close() }
        code.close()
    }

    /// App 不在时会话已经结束了：主机上用同一个 id 新开了一个 shell、停在提示符上，照程序退出处理，回到记录。
    func testRestoredRunWhoseProgramIsGoneReturnsToTheRecord() async throws {
        let session = UUID(), codeID = UUID()
        var archive = MobileTerminalTabArchive()
        archive.tabs = [.init(hostID: host.id, sessionID: session, codeTab: codeID)]
        archive.codeTabs = [.init(position: 0, record: CodeTabRecord(id: codeID, host: host.id, directory: Self.shop, runs: [
            CodeRunRecord(session: session, tool: .codex, sessionID: "x-tests", directory: Self.shop,
                          startedAt: Date().addingTimeInterval(-600)),
        ], selectedRun: session))]
        let ws = MobileWorkspace()
        let factory = ProbeFactory(.idle)
        archive.restore(into: ws, hosts: [host], transportFactory: factory.transportFactory,
                        makeCodeTab: makeCodeTab, start: start)
        let code = try XCTUnwrap(ws.tabs.first?.history)
        let ended = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { code.runs.runs.isEmpty }
        XCTAssertTrue(ended, "停在提示符上：程序已经不在了")
        let back = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            code.connection.history?.selectedFile?.sessionID == "x-tests"
        }
        XCTAssertTrue(back, "回到它的记录")
        XCTAssertNil(code.runs.focused)

        // 判断不了（主机上没有 ps）：当它还在跑。
        let unknownSession = UUID(), unknownCode = UUID()
        var other = MobileTerminalTabArchive()
        other.tabs = [.init(hostID: host.id, sessionID: unknownSession, codeTab: unknownCode)]
        other.codeTabs = [.init(position: 0, record: CodeTabRecord(id: unknownCode, host: host.id, runs: [
            CodeRunRecord(session: unknownSession, tool: .claude, sessionID: nil, directory: Self.shop,
                          startedAt: Date().addingTimeInterval(-600)),
        ]))]
        let ws2 = MobileWorkspace()
        let opened = other.restore(into: ws2, hosts: [host], transportFactory: ProbeFactory(.unknown).transportFactory,
                                   makeCodeTab: makeCodeTab, start: start)
        let code2 = try XCTUnwrap(ws2.tabs.first?.history)
        _ = await MobileFakeTerminal.waitUntilConnected(try XCTUnwrap(opened.first).controller)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(code2.runs.runs.count, 1)
        code.close()
        code2.close()
    }

    /// 里面没有会话在跑的 Code 标签页也开回来（哪台主机即可），排在原来的位置。
    func testEmptyCodeTabComesBackInPlace() throws {
        let before = UUID(), after = UUID(), codeID = UUID()
        var archive = MobileTerminalTabArchive()
        archive.tabs = [.init(hostID: host.id, sessionID: before), .init(hostID: host.id, sessionID: after)]
        archive.codeTabs = [.init(position: 1, record: CodeTabRecord(id: codeID, host: host.id, directory: Self.shop))]
        let ws = MobileWorkspace()
        let opened = archive.restore(into: ws, hosts: [host], transportFactory: ProbeFactory(.unknown).transportFactory,
                                     makeCodeTab: makeCodeTab, start: start)
        XCTAssertEqual(ws.tabs.map { $0.history != nil }, [false, true, false])
        XCTAssertEqual(ws.tabs.first?.terminal?.controller.hostSessionID, before)
        XCTAssertEqual(ws.tabs.last?.terminal?.controller.hostSessionID, after)
        XCTAssertTrue(ws.tabs[1].history?.runs.runs.isEmpty == true)
        opened.forEach { $0.controller.close() }
        ws.tabs[1].history?.close()

        // 主机已经不在：不开。
        let gone = MobileWorkspace()
        var missing = MobileTerminalTabArchive()
        missing.codeTabs = [.init(position: 0, record: CodeTabRecord(id: UUID(), host: UUID()))]
        missing.restore(into: gone, hosts: [host], makeCodeTab: makeCodeTab, start: start)
        XCTAssertTrue(gone.tabs.isEmpty)
    }

    // MARK: 新读旧、旧读新

    /// 旧版存的表（没有 Code 标签页那两项）：照旧开成终端标签页。
    func testOldArchiveRestoresAsTerminalTabs() throws {
        let a = UUID(), b = UUID()
        let json = #"""
        {"tabs":[{"hostID":"\#(host.id.uuidString)","sessionID":"\#(a.uuidString)"},{"hostID":"\#(host.id.uuidString)","sessionID":"\#(b.uuidString)"}],"activeIndex":1,"showsWorkspace":true}
        """#
        let archive = try JSONDecoder().decode(MobileTerminalTabArchive.self, from: Data(json.utf8))
        XCTAssertNil(archive.codeTabs)
        XCTAssertTrue(archive.tabs.allSatisfy { $0.codeTab == nil })
        let ws = MobileWorkspace()
        let opened = archive.restore(into: ws, hosts: [host], transportFactory: ProbeFactory(.unknown).transportFactory,
                                     makeCodeTab: makeCodeTab, start: start)
        XCTAssertEqual(opened.map(\.controller.hostSessionID), [a, b])
        XCTAssertEqual(ws.activeTab?.id, opened.last?.id)
        XCTAssertTrue(ws.tabs.allSatisfy { $0.history == nil })
        opened.forEach { $0.controller.close() }
    }

    /// 旧版读到新版存的表（用户装回旧版）：用旧结构体的副本解，解得开，Code 标签页里的会话照普通终端标签页开，一个不丢。
    /// 新版自己不给 `makeCodeTab` 时也是这样（同旧版的开法）。
    func testOldVersionReadingNewArchiveKeepsEverySession() throws {
        struct OldTab: Codable { var hostID: UUID; var sessionID: UUID }
        struct OldArchive: Codable { var tabs: [OldTab]; var activeIndex: Int?; var showsWorkspace: Bool }

        let shell = UUID(), run = UUID(), codeID = UUID()
        var archive = MobileTerminalTabArchive()
        archive.tabs = [.init(hostID: host.id, sessionID: shell), .init(hostID: host.id, sessionID: run, codeTab: codeID)]
        archive.codeTabs = [.init(position: 1, record: CodeTabRecord(id: codeID, host: host.id, runs: [
            CodeRunRecord(session: run, tool: .claude, sessionID: "c-login", directory: Self.shop, startedAt: Date()),
        ], selectedRun: run))]
        archive.activeIndex = 1
        archive.activeCodeTab = codeID
        archive.showsWorkspace = true
        let old = try JSONDecoder().decode(OldArchive.self, from: JSONEncoder().encode(archive))
        XCTAssertEqual(old.tabs.map(\.sessionID), [shell, run], "旧版看到的是两个终端标签页")
        XCTAssertEqual(old.activeIndex, 1)

        let ws = MobileWorkspace()
        let opened = archive.restore(into: ws, hosts: [host], transportFactory: ProbeFactory(.unknown).transportFactory,
                                     start: start)
        XCTAssertEqual(opened.map(\.controller.hostSessionID), [shell, run])
        XCTAssertTrue(ws.tabs.allSatisfy { $0.history == nil })
        XCTAssertEqual(ws.activeTab?.id, opened.last?.id)
        opened.forEach { $0.controller.close() }
    }

    /// Code 标签页那一段是别的版本写的、解不开：终端标签照样开回来。
    func testUnreadableCodeTabsKeepTheTerminalTabs() throws {
        let a = UUID()
        let json = #"""
        {"tabs":[{"hostID":"\#(host.id.uuidString)","sessionID":"\#(a.uuidString)","codeTab":"\#(UUID().uuidString)"}],"showsWorkspace":false,"codeTabs":7}
        """#
        let archive = try JSONDecoder().decode(MobileTerminalTabArchive.self, from: Data(json.utf8))
        XCTAssertNil(archive.codeTabs)
        let ws = MobileWorkspace()
        let opened = archive.restore(into: ws, hosts: [host], transportFactory: ProbeFactory(.unknown).transportFactory,
                                     makeCodeTab: makeCodeTab, start: start)
        XCTAssertEqual(opened.map(\.controller.hostSessionID), [a], "那个会话退回普通终端标签页")
        opened.forEach { $0.controller.close() }
    }
}
