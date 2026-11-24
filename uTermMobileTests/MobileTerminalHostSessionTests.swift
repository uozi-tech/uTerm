import SwiftData
import XCTest
@testable import uTermMobile

/// 终端标签和主机上那个会话的对应关系：会话 id 怎么交给后端、什么时候换、断开后怎么重连、进后台做什么，
/// 以及 App 重新打开后标签怎么回来（`MobileTerminalTabArchive`）。后端全是假的，不发起任何连接。
@MainActor
final class MobileTerminalHostSessionTests: XCTestCase {

    /// 会话留在主机上的后端的替身：能存检查点，测试能让它「shell 退出」。
    actor HeldBackend: CheckpointingTerminalBackend {
        nonisolated let outputItems = AsyncStream<TerminalOutputItem> { _ in }
        nonisolated let exitStream: AsyncStream<Void>
        private nonisolated let exitContinuation: AsyncStream<Void>.Continuation
        private let connectFailure: String?
        private(set) var checkpointRequests = 0
        private(set) var closeCount = 0
        private nonisolated let hooksBox = HooksBox()

        final class HooksBox: @unchecked Sendable {
            private let lock = NSLock()
            private var hooks: TerminalCheckpointHooks?
            var value: TerminalCheckpointHooks? {
                get { lock.withLock { hooks } }
                set { lock.withLock { hooks = newValue } }
            }
        }

        struct Failure: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }

        init(connectFailure: String? = nil) {
            self.connectFailure = connectFailure
            (exitStream, exitContinuation) = AsyncStream<Void>.makeStream()
        }

        func connect() async throws {
            if let connectFailure { throw Failure(message: connectFailure) }
        }
        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async { closeCount += 1 }
        nonisolated func setCheckpointHooks(_ hooks: TerminalCheckpointHooks) { hooksBox.value = hooks }
        func saveCheckpoint() async { checkpointRequests += 1 }

        nonisolated var hooks: TerminalCheckpointHooks? { hooksBox.value }
        nonisolated func endSession() { exitContinuation.yield(()) }
    }

    /// 记下每次造后端时的请求，按顺序发预先备好的后端。
    @MainActor
    final class Factory {
        private(set) var requests: [(sessionID: UUID, resumes: Bool)] = []
        private var backends: [HeldBackend]
        private(set) var issued: [HeldBackend] = []

        init(_ backends: HeldBackend...) { self.backends = backends }

        var transportFactory: MobileTerminalTransportFactory {
            MobileTerminalTransportFactory { [self] request in
                requests.append((request.sessionID, request.resumesSession))
                let backend = backends.isEmpty ? HeldBackend() : backends.removeFirst()
                issued.append(backend)
                return backend
            }
        }
    }

    private var container: ModelContainer!
    private var host: ServerProfile!

    override func setUp() async throws {
        try await super.setUp()
        container = try MobileFixtures.modelContainer(seed: .smoke)
        host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
    }

    private func start(_ controller: MobileTerminalController) {
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
    }

    // MARK: - 会话 id

    /// 新开的标签：自己生成一个会话 id 交给后端，不算「上次留下的」。
    func testNewTabHandsItsOwnSessionIDToTheBackend() async {
        let factory = Factory()
        let controller = MobileTerminalController(transportFactory: factory.transportFactory)
        start(controller)
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        XCTAssertEqual(factory.requests.count, 1)
        XCTAssertEqual(factory.requests.first?.sessionID, controller.hostSessionID)
        XCTAssertEqual(factory.requests.first?.resumes, false)
        controller.close()
    }

    /// 恢复的标签：带着上次的会话 id，并告诉后端主机上多半还有它。
    func testRestoredTabResumesTheSavedSession() async {
        let saved = UUID()
        let factory = Factory()
        let controller = MobileTerminalController(transportFactory: factory.transportFactory, hostSessionID: saved)
        start(controller)
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        XCTAssertEqual(factory.requests.first?.sessionID, saved)
        XCTAssertEqual(factory.requests.first?.resumes, true)
        controller.close()
    }

    /// 没连上（网络不通）再重试：还是原来的会话，这样才接得回去。
    func testRetryAfterAFailedConnectKeepsTheSession() async {
        let saved = UUID()
        let factory = Factory(HeldBackend(connectFailure: "network down"))
        let controller = MobileTerminalController(transportFactory: factory.transportFactory, hostSessionID: saved)
        start(controller)
        let failed = await MobileFakeTerminal.waitUntil {
            if case .failed = controller.state { return true }
            return false
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(controller.canReconnect)

        controller.restart()
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        XCTAssertEqual(factory.requests.map(\.sessionID), [saved, saved])
        XCTAssertEqual(factory.requests.map(\.resumes), [true, true])
        controller.close()
    }

    /// 会话结束（shell 退出）：标签进「已断开」，可以重新连接；重新连接开的是新会话。
    func testReconnectAfterTheSessionEndedStartsANewSession() async {
        let saved = UUID()
        let first = HeldBackend()
        let factory = Factory(first)
        let controller = MobileTerminalController(transportFactory: factory.transportFactory, hostSessionID: saved)
        start(controller)
        var connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        XCTAssertFalse(controller.canReconnect)

        first.endSession()
        let disconnected = await MobileFakeTerminal.waitUntil { controller.state == .disconnected }
        XCTAssertTrue(disconnected)
        XCTAssertTrue(controller.canReconnect)
        XCTAssertNotEqual(controller.hostSessionID, saved)

        controller.restart()
        connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        XCTAssertEqual(factory.requests.count, 2)
        XCTAssertEqual(factory.requests.last?.sessionID, controller.hostSessionID)
        XCTAssertNotEqual(factory.requests.last?.sessionID, saved)
        XCTAssertEqual(factory.requests.last?.resumes, false)
        let closedOld = await MobileFakeTerminal.waitUntilAsync { await first.closeCount == 1 }
        XCTAssertTrue(closedOld, "换连接时旧后端要关掉")
        controller.close()
    }

    /// 断开了、但主机上的会话还在（连不上、自动重连停下了）：会话 id 不换，重新连接接回的还是它。
    /// 只有保持进程说会话没了（`HostSessionOwning.hostSessionHasEnded`）才换。
    func testDisconnectWithTheHostSessionAliveKeepsTheSessionID() async {
        let saved = UUID()
        let first = AttentiveBackend(sessionEnded: false)
        let factory = AttentiveFactory(first)
        let controller = MobileTerminalController(transportFactory: factory.transportFactory, hostSessionID: saved)
        start(controller)
        var connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)

        first.end()
        let disconnected = await MobileFakeTerminal.waitUntil { controller.state == .disconnected }
        XCTAssertTrue(disconnected)
        XCTAssertEqual(controller.hostSessionID, saved, "主机上的 shell 还在，不能换 id")

        controller.restart()
        connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        XCTAssertEqual(factory.requests.map(\.sessionID), [saved, saved])
        XCTAssertEqual(factory.requests.last?.resumes, true)
        controller.close()
    }

    /// 新开的标签第一次就没连上（还没接上过主机上的会话）：重试用同一个 id，但**不是接回**——主机上还没有这个会话，
    /// 新 shell 的启动输出要照常处理、终端查询要回答（当成接回的话 fish 等 10 秒报错，提示符卡住）。
    func testFirstConnectThatNeverAttachedRetriesAsANewSession() async {
        let first = AttentiveBackend(sessionEnded: false, attached: false)
        let factory = AttentiveFactory(first)
        let controller = MobileTerminalController(transportFactory: factory.transportFactory)
        start(controller)
        var connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        let id = controller.hostSessionID

        first.end()
        let disconnected = await MobileFakeTerminal.waitUntil { controller.state == .disconnected }
        XCTAssertTrue(disconnected)

        controller.restart()
        connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        XCTAssertEqual(factory.requests.map(\.sessionID), [id, id])
        XCTAssertEqual(factory.requests.map(\.resumes), [false, false], "没接上过就不是接回")
        controller.close()
    }

    /// 恢复的标签（带着上次的 id）第一次没连上：主机上多半还有那个会话，重试仍然是接回。
    func testRestoredTabThatFailsFirstStillResumes() async {
        let saved = UUID()
        let first = AttentiveBackend(sessionEnded: false, attached: false)
        let factory = AttentiveFactory(first)
        let controller = MobileTerminalController(transportFactory: factory.transportFactory, hostSessionID: saved)
        start(controller)
        var connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        first.end()
        _ = await MobileFakeTerminal.waitUntil { controller.state == .disconnected }

        controller.restart()
        connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        XCTAssertEqual(factory.requests.map(\.resumes), [true, true])
        controller.close()
    }

    /// 后端停下来等用户（凭据被拒之类）：标签上显示原因；点重试交给后端，原因随之清掉。会话 id 不动。
    func testAttentionIsShownAndRetryIsForwardedToTheBackend() async {
        let saved = UUID()
        let backend = AttentiveBackend(sessionEnded: false)
        let factory = AttentiveFactory(backend)
        let controller = MobileTerminalController(transportFactory: factory.transportFactory, hostSessionID: saved)
        start(controller)
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)

        backend.needsAttention("服务器拒绝了密码")
        let shown = await MobileFakeTerminal.waitUntil { controller.attentionMessage == "服务器拒绝了密码" }
        XCTAssertTrue(shown)
        XCTAssertEqual(controller.state, .connected, "会话还在，不翻成已断开")

        controller.retryAfterAttention()
        XCTAssertNil(controller.attentionMessage)
        let retried = await MobileFakeTerminal.waitUntilAsync { await backend.retries == 1 }
        XCTAssertTrue(retried)
        XCTAssertEqual(controller.hostSessionID, saved)
        controller.close()
    }

    /// 关掉的标签不再重连。
    func testClosedTabCannotReconnect() async {
        let factory = Factory()
        let controller = MobileTerminalController(transportFactory: factory.transportFactory)
        start(controller)
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        controller.close()
        XCTAssertFalse(controller.canReconnect)
        controller.restart()
        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertEqual(factory.requests.count, 1)
    }

    // MARK: - 进后台

    /// 进后台：向系统多要一段运行时间，让后端把终端状态存到主机上；回前台把时间还回去。
    func testEnteringBackgroundSavesACheckpointAndAsksForTime() async {
        let backend = HeldBackend()
        let factory = Factory(backend)
        let controller = MobileTerminalController(transportFactory: factory.transportFactory)
        start(controller)
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        XCTAssertNotNil(backend.hooks, "建连前就要把拍检查点的办法交给后端")
        MobileBackgroundGrace.shared.end()

        controller.appVisibilityChanged(inBackground: true)
        XCTAssertTrue(MobileBackgroundGrace.shared.isActive)
        let saved = await MobileFakeTerminal.waitUntilAsync { await backend.checkpointRequests == 1 }
        XCTAssertTrue(saved)

        controller.appVisibilityChanged(inBackground: false)
        XCTAssertFalse(MobileBackgroundGrace.shared.isActive)
        let requests = await backend.checkpointRequests
        XCTAssertEqual(requests, 1, "回前台不存")
        controller.close()
    }

    /// 没连上的标签进后台：不占后台时间，也没有可存的。
    func testDisconnectedTabDoesNotAskForBackgroundTime() async {
        let backend = HeldBackend()
        let factory = Factory(backend)
        let controller = MobileTerminalController(transportFactory: factory.transportFactory)
        start(controller)
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        backend.endSession()
        let disconnected = await MobileFakeTerminal.waitUntil { controller.state == .disconnected }
        XCTAssertTrue(disconnected)
        MobileBackgroundGrace.shared.end()

        controller.appVisibilityChanged(inBackground: true)
        XCTAssertFalse(MobileBackgroundGrace.shared.isActive)
        try? await Task.sleep(for: .milliseconds(100))
        let requests = await backend.checkpointRequests
        XCTAssertEqual(requests, 0)
        controller.appVisibilityChanged(inBackground: false)
    }

    /// 交给后端的那两个闭包接的是这个标签的终端：拍出来的检查点能还原出屏幕上的内容，程序状态存得进去、取得出来。
    func testCheckpointHooksCaptureThisTerminal() async throws {
        let backend = HeldBackend()
        let factory = Factory(backend)
        let controller = MobileTerminalController(transportFactory: factory.transportFactory)
        start(controller)
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        controller.terminal.feed(Data("on the phone screen".utf8))

        let hooks = try XCTUnwrap(backend.hooks)
        let checkpoint = try XCTUnwrap(controller.terminal.outputPump.performWhileFeedingPaused { hooks.capture() })
        let snapshot = try XCTUnwrap(TerminalCheckpointBlob.decode(checkpoint.blob))
        let restored = ShadowTerminal(cols: 20, rows: 5, options: TerminalScrollbackLimits(lines: 100).shadowOptions)
        try restored.restore(snapshot: snapshot)
        XCTAssertTrue(restored.viewportText().contains("on the phone screen"))
        XCTAssertNotNil(TerminalCheckpointBlob.decodeProgramStatus(checkpoint.blob))
        controller.close()
    }

    // MARK: - 标签归档

    private func makeDefaults() throws -> UserDefaults {
        let suite = "MobileTerminalHostSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func allHosts() throws -> [ServerProfile] {
        try container.mainContext.fetch(FetchDescriptor<ServerProfile>(sortBy: [SortDescriptor(\ServerProfile.sortOrder)]))
            .filter { !$0.sftpOnly }
    }

    /// 归档记的是直连主机、还没断开的终端标签，按标签条上的先后；前台是谁、工作区是不是展开着也记下。
    func testArchiveListsLiveDirectTerminalTabsInOrder() async throws {
        let hosts = try allHosts()
        try XCTSkipIf(hosts.count < 2, "夹具里至少要两台能开终端的主机")
        let workspace = MobileWorkspace()
        let endable = HeldBackend()
        let factories = [Factory(), Factory(endable), Factory()]
        var tabs: [TermTab] = []
        for (index, factory) in factories.enumerated() {
            let tab = TermTab(host: hosts[index % hosts.count], transportFactory: factory.transportFactory)
            tab.controller.start(profile: tab.host, container: container, relay: HostKeyChallengeRelay())
            workspace.open(.terminal(tab))
            tabs.append(tab)
        }
        workspace.open(.files(FileTab(host: hosts[0])), activate: false)
        for tab in tabs {
            let connected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
            XCTAssertTrue(connected)
        }
        workspace.activate(tabs[0].id)

        var archive = workspace.terminalTabArchive(showsWorkspace: true)
        XCTAssertEqual(archive.tabs.map(\.sessionID), tabs.map(\.controller.hostSessionID))
        XCTAssertEqual(archive.tabs.map(\.hostID), tabs.map(\.host.id))
        XCTAssertEqual(archive.activeIndex, 0)
        XCTAssertTrue(archive.showsWorkspace)

        // 第二个标签的 shell 退出了：它不在归档里（重新打开 App 不该凭空多出一个新 shell）。
        endable.endSession()
        let ended = await MobileFakeTerminal.waitUntil { tabs[1].controller.state == .disconnected }
        XCTAssertTrue(ended)
        archive = workspace.terminalTabArchive(showsWorkspace: false)
        XCTAssertEqual(archive.tabs.map(\.sessionID), [tabs[0], tabs[2]].map(\.controller.hostSessionID))
        XCTAssertFalse(archive.showsWorkspace)
        tabs.forEach { $0.controller.close() }
    }

    func testArchiveRoundTripsThroughDefaultsAndClearsWhenEmpty() throws {
        let defaults = try makeDefaults()
        XCTAssertEqual(MobileTerminalTabArchive.load(from: defaults), MobileTerminalTabArchive())

        var archive = MobileTerminalTabArchive()
        archive.tabs = [.init(hostID: UUID(), sessionID: UUID()), .init(hostID: UUID(), sessionID: UUID())]
        archive.activeIndex = 1
        archive.showsWorkspace = true
        archive.save(to: defaults)
        XCTAssertEqual(MobileTerminalTabArchive.load(from: defaults), archive)

        MobileTerminalTabArchive().save(to: defaults)
        XCTAssertNil(defaults.object(forKey: DefaultsKey.mobileRestorableTerminalTabs))
    }

    /// 恢复：标签按原来的先后开回来，各自带着上次的会话 id 去连；主机已经不在的跳过；前台还是原来那个。
    func testRestoreReopensTabsWithTheirSessions() async throws {
        let hosts = try allHosts()
        try XCTSkipIf(hosts.count < 2, "夹具里至少要两台能开终端的主机")
        var archive = MobileTerminalTabArchive()
        archive.tabs = [.init(hostID: hosts[0].id, sessionID: UUID()),
                        .init(hostID: UUID(), sessionID: UUID()),
                        .init(hostID: hosts[1].id, sessionID: UUID())]
        archive.activeIndex = 2

        let workspace = MobileWorkspace()
        let factory = Factory()
        let opened = archive.restore(into: workspace, hosts: hosts, transportFactory: factory.transportFactory) { term in
            term.controller.start(profile: term.host, container: self.container, relay: HostKeyChallengeRelay())
        }
        XCTAssertEqual(opened.map(\.host.id), [hosts[0].id, hosts[1].id])
        XCTAssertEqual(workspace.terminalTabs.map(\.id), opened.map(\.id))
        XCTAssertEqual(workspace.activeTab?.id, opened[1].id)
        for tab in opened {
            let connected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
            XCTAssertTrue(connected)
        }
        XCTAssertEqual(Set(factory.requests.map(\.sessionID)), [archive.tabs[0].sessionID, archive.tabs[2].sessionID])
        XCTAssertTrue(factory.requests.allSatisfy(\.resumes))
        // 恢复之后的归档和恢复之前的对得上（少掉的是主机已经不在的那个）。
        let again = workspace.terminalTabArchive(showsWorkspace: false)
        XCTAssertEqual(again.tabs, [archive.tabs[0], archive.tabs[2]])
        XCTAssertEqual(again.activeIndex, 1)
        opened.forEach { $0.controller.close() }
    }

    /// 测试宿主和正式版共用一份偏好：根视图里的恢复器在宿主里默认什么都不碰。
    func testRestorerIsInertInsideTheTestHost() {
        XCTAssertNil(MobileTerminalTabRestorer().defaults)
    }
}

/// 会自己重连、能说出「主机上的会话还在不在」的后端替身。
actor AttentiveBackend: ReconnectingTerminalBackend, HostSessionOwning {
    nonisolated let outputItems = AsyncStream<TerminalOutputItem> { _ in }
    nonisolated let exitStream: AsyncStream<Void>
    nonisolated let reconnecting: AsyncStream<Bool>
    nonisolated let attention: AsyncStream<String?>
    private nonisolated let exitContinuation: AsyncStream<Void>.Continuation
    private nonisolated let reconnectingContinuation: AsyncStream<Bool>.Continuation
    private nonisolated let attentionContinuation: AsyncStream<String?>.Continuation
    nonisolated let hostSessionHasEnded: Bool
    nonisolated let hasAttachedToHostSession: Bool
    private(set) var retries = 0

    init(sessionEnded: Bool, attached: Bool = true) {
        hostSessionHasEnded = sessionEnded
        hasAttachedToHostSession = attached
        (exitStream, exitContinuation) = AsyncStream<Void>.makeStream()
        (reconnecting, reconnectingContinuation) = AsyncStream<Bool>.makeStream()
        (attention, attentionContinuation) = AsyncStream<String?>.makeStream()
    }

    func connect() async throws {}
    func write(_ data: Data) async {}
    func resize(cols: UInt16, rows: UInt16) async {}
    func close() async {}
    func retryAfterAttention() async { retries += 1 }

    nonisolated func end() { exitContinuation.yield(()) }
    nonisolated func needsAttention(_ message: String) {
        reconnectingContinuation.yield(true)
        attentionContinuation.yield(message)
    }
}

@MainActor
final class AttentiveFactory {
    private(set) var requests: [(sessionID: UUID, resumes: Bool)] = []
    private var backends: [AttentiveBackend]

    init(_ backends: AttentiveBackend...) { self.backends = backends }

    var transportFactory: MobileTerminalTransportFactory {
        MobileTerminalTransportFactory { [self] request in
            requests.append((request.sessionID, request.resumesSession))
            return backends.isEmpty ? AttentiveBackend(sessionEnded: false) : backends.removeFirst()
        }
    }
}

extension MobileFakeTerminal {
    /// `waitUntil` 的异步条件版（读 actor 上的账本）。
    @discardableResult
    static func waitUntilAsync(timeout: Duration = .seconds(3),
                               _ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }
}
