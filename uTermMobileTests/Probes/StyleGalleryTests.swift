import AgentKit
import SwiftUI
import SwiftData
import UIKit
import XCTest
@testable import uTermMobile

/// 样式画廊：把每个页面按「设备形态 × 日 / 夜」挂起来截图，供人眼核对样式与 iPhone Duo 适配。
///
/// 这不是闸门：只在设置了环境变量 `UTERM_STYLE_SHOTS_DIR` 时才跑（`xcodebuild test` 里写成
/// `TEST_RUNNER_UTERM_STYLE_SHOTS_DIR=/path`），否则整条 `XCTSkip`，不拖慢 `make test-mobile`。
///
/// ## 设备形态
///
/// iPhone Duo（iPhone19,4，iOS 27.1 起）是一台横向对折的折叠屏：
/// - **外屏（合起）**：1398×2034 px @3x = **466×678pt**，灵动岛与状态栏在**侧边**，
///   只有远离铰链一侧是大圆角（59 / 8）；
/// - **内屏（展开）**：2007×2853 px @3x = **669×951pt**，宽度落进常规（regular）水平尺寸类；
/// - **内屏分屏**：iOS 27 把 iPad 的 Split View 搬了过来，两个 app 并排时每边约 **330pt**，
///   比 iPhone SE（375pt）还窄，必须按紧凑尺寸类排。
///
/// 探针窗口关掉了安全区（见 `MobileProbeWindow.make`），所以这里只核对内容排版与配色；
/// 侧边灵动岛 / 圆角等安全区行为以模拟器整机截图为准。
@MainActor
final class StyleGalleryTests: XCTestCase {

    private struct Device {
        let name: String
        let size: CGSize
        let hSize: UserInterfaceSizeClass
    }

    private static let devices: [Device] = [
        Device(name: "duo-folded", size: CGSize(width: 466, height: 678), hSize: .compact),
        Device(name: "duo-unfolded", size: CGSize(width: 669, height: 951), hSize: .regular),
        Device(name: "duo-split", size: CGSize(width: 330, height: 951), hSize: .compact),
        Device(name: "iphone", size: CGSize(width: 402, height: 874), hSize: .compact),
        Device(name: "ipad", size: CGSize(width: 820, height: 1180), hSize: .regular),
    ]

    private var outputDir: URL!

    // async 版 setUp 跑在主 actor 上；同步版是 nonisolated，写不了 outputDir。
    override func setUp() async throws {
        try await super.setUp()
        guard let dir = ProcessInfo.processInfo.environment["UTERM_STYLE_SHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("未设置 UTERM_STYLE_SHOTS_DIR：样式画廊只按需跑")
        }
        outputDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    // MARK: - 挂载与截图

    /// 挂一屏、等它排完版、按日 / 夜各截一张。返回成功写出的张数。
    @discardableResult
    private func shoot<V: View>(_ name: String, on device: Device,
                                settle: Duration = .milliseconds(350),
                                _ view: () -> V) async throws -> Int {
        var written = 0
        for style in [UIUserInterfaceStyle.light, .dark] {
            let root = view()
                .environment(\.horizontalSizeClass, device.hSize)
                .environment(\.mAccent, M.accent)
                .tint(M.accent)
                .frame(width: device.size.width, height: device.size.height)
            let (window, host) = MobileProbeWindow.make(size: device.size, rootView: root)
            window.overrideUserInterfaceStyle = style
            host.view.backgroundColor = style == .dark ? .black : .white
            host.view.layoutIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: settle)
            host.view.layoutIfNeeded()
            CATransaction.flush()

            let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
            let png = renderer.pngData { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let file = outputDir.appendingPathComponent(
                "\(name)-\(device.name)-\(style == .dark ? "dark" : "light").png")
            try png.write(to: file)
            written += 1
            MobileProbeWindow.close(window)
        }
        XCTAssertEqual(written, 2, "\(name) @ \(device.name)")
        return written
    }

    private func store(tab: MTab) -> MobileStore {
        let s = MobileStore()
        s.tab = tab
        return s
    }

    /// 工作区展开（盖住标签栏）的 store。
    private func workspaceStore() -> MobileStore {
        let s = MobileStore()
        s.showWorkspace = true
        return s
    }

    private func lanSync(_ c: ModelContainer) -> LANSyncCoordinator {
        LANSyncCoordinator(role: .receiver, preferences: SharedPreferencesSync(),
                           dataStore: LANSyncDataStore(container: c))
    }

    // MARK: - 列表类屏（@Query 驱动）

    func testListScreens() async throws {
        defer { MobileProbeWindow.closeAll() }
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let sync = CloudKitSyncMonitor()
        let lan = lanSync(c)

        for device in Self.devices {
            try await shoot("hosts", on: device) {
                HostsScreen().environment(store(tab: .hosts)).modelContainer(c)
            }
            // 工作区收起、仍有会话开着：主机页右上角露出「会话 N」回去的入口。
            try await shoot("hosts-with-sessions", on: device) {
                let workspace = MobileWorkspace()
                if let host = MobileFixtures.firstServer(in: c) { workspace.open(.files(FileTab(host: host))) }
                return HostsScreen()
                    .environment(store(tab: .hosts))
                    .environment(workspace)
                    .modelContainer(c)
            }
            try await shoot("commands", on: device) {
                CommandsScreen().environment(store(tab: .commands)).modelContainer(c)
            }
            try await shoot("settings", on: device) {
                SettingsScreen()
                    .environment(store(tab: .settings))
                    .environment(sync)
                    .environment(lan)
                    .environment(RemoteMacDirectory(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())))
                    .modelContainer(c)
            }
            try await shoot("keys", on: device) {
                NavigationStack { KeysScreen() }.modelContainer(c)
            }
            try await shoot("groups", on: device) {
                NavigationStack { GroupsScreen() }.modelContainer(c)
            }
            try await shoot("fingerprints", on: device) {
                NavigationStack { FingerprintsView() }.modelContainer(c)
            }
            try await shoot("palette", on: device) {
                CommandPaletteView().environment(store(tab: .hosts)).modelContainer(c)
            }
        }
    }

    // MARK: - 抽屉 / 表单

    func testSheets() async throws {
        defer { MobileProbeWindow.closeAll() }
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: c))
        let cmd = try XCTUnwrap(try c.mainContext.fetch(FetchDescriptor<QuickCommand>()).first)

        for device in Self.devices {
            try await shoot("host-sheet", on: device) {
                HostSheet(host: host, onConnect: {}, onSFTP: {}, onEdit: {}).modelContainer(c)
            }
            try await shoot("host-form", on: device) {
                HostFormSheet(host: host).modelContainer(c)
            }
            try await shoot("command-detail", on: device) {
                NavigationStack { QuickCommandDetailView(cmd: cmd) }
                    .environment(store(tab: .commands))
                    .modelContainer(c)
            }
            // 连接中页的内容晚 150ms 露面、再淡入，默认 350ms 会截到半透明。
            try await shoot("connecting", on: device, settle: .milliseconds(700)) {
                ConnectingCoverView(request: MConnectRequest(host: host, kind: .terminal, origin: .hosts),
                                    onFinish: {}, onCancel: {}, onRetry: {})
                    .environment(store(tab: .hosts))
                    .environment(HostKeyChallengeRelay())
                    .modelContainer(c)
            }
        }

        // Duo 展开竖屏：状态栏只占顶行右端，chip 应进那一行。探针窗口没有安全区，这里把
        // 根视图量到的几何按真机读数伪造出来（顶部安全区 41pt、系统顶部横条区到状态栏左侧为止），
        // 顶行用一条示意状态栏标出位置，看 chip 是否与它同行。
        let unfolded = try XCTUnwrap(Self.devices.first { $0.name == "duo-unfolded" })
        var duo = MChromeGeometry(root: CGRect(x: 0, y: 41, width: 669, height: 910),
                                  safeAreaInsets: EdgeInsets(top: 41, leading: 0, bottom: 0, trailing: 0))
        duo.topBar = CGRect(x: 0, y: 0, width: 520, height: 48)
        duo.isUnfoldedPhone = true
        try await shoot("connecting-duo-status-row", on: unfolded, settle: .milliseconds(700)) {
            ConnectingCoverView(request: MConnectRequest(host: host, kind: .terminal, origin: .hosts),
                                onFinish: {}, onCancel: {}, onRetry: {})
                .environment(store(tab: .hosts))
                .environment(HostKeyChallengeRelay())
                .environment(\.mChrome, duo)
                .overlay(alignment: .topTrailing) {
                    Text("11:57  ▮▮▮").font(.system(size: 15, weight: .semibold))
                        .frame(width: 149, height: 41).background(Color.red.opacity(0.15))
                }
                .modelContainer(c)
        }
    }

    // MARK: - 终端会话（假传输，真终端视图）

    func testTerminalSession() async throws {
        defer { MobileProbeWindow.closeAll() }
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let hosts = Array(try c.mainContext.fetch(
            FetchDescriptor<ServerProfile>(sortBy: [SortDescriptor(\.sortOrder)])).filter { !$0.sftpOnly }.prefix(3))
        let relay = HostKeyChallengeRelay()

        for device in Self.devices {
            let (sessions, _) = MobileFakeTerminal.sessions(
                count: 2, hosts: hosts, script: .interactive(seconds: 2), container: c, relay: relay)
            for tab in sessions.terminalTabs { await MobileFakeTerminal.waitUntilConnected(tab.controller) }
            try await shoot("terminal-session", on: device, settle: .milliseconds(900)) {
                WorkspaceScreen()
                    .environment(workspaceStore())
                    .environment(relay)
                    .environment(sessions)
                    .modelContainer(c)
            }
            for tab in sessions.terminalTabs { tab.controller.close() }
        }
    }

    /// 快捷条：只有常驻行，和两个面板。
    func testTerminalKeyBarPanels() async throws {
        defer { MobileProbeWindow.closeAll() }
        for device in Self.devices {
            for (name, panel) in [("row", nil), ("prompts", TerminalKeyBar.Panel.prompts), ("keys", .keys)] {
                let (controller, _) = MobileFakeTerminal.controller(.idle)
                try await shoot("keybar-\(name)", on: device) {
                    VStack(spacing: 0) {
                        Color.clear
                        TerminalKeyBar(controller: controller, panel: panel)
                    }
                    .background(M.surface)
                }
            }
        }
    }

    /// 主机页的「我的 Mac」：一台在线（调试直连）、一台不在线（配对过的），标题右侧是扫码配对。
    func testRemoteMacSection() async throws {
        defer { MobileProbeWindow.closeAll() }
        let suite = "StyleGalleryTests.remoteMacs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("127.0.0.1:1", forKey: "RemoteDebugEndpoint")
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try identity.trust(RemotePeer(id: UUID(), name: "办公室 iMac", publicKey: Data(count: 32), pairedAt: .now))
        let directory = RemoteMacDirectory(identity: identity, defaults: defaults)
        directory.activate()
        for device in Self.devices {
            try await shoot("remote-mac-section", on: device) {
                ScrollView { RemoteMacSection().padding(.top, 20) }
                    .background(M.canvas)
                    .environment(directory)
                    .environment(MobileStore())
            }
        }
    }

    /// 网络诊断：上次结果（局域网通、IPv4 打洞全失败、中继通）+ 结论；历史页按次分组。没配中继时目标那一组给出指引。
    func testNetworkDiagnostics() async throws {
        defer { MobileProbeWindow.closeAll() }
        let suite = "StyleGalleryTests.networkDiagnostics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = RemotePathMatrixLog(defaults: defaults)
        for (runIndex, network) in ["蜂窝 · 无 IPv6", "Wi-Fi · 有 IPv6"].enumerated() {
            let runID = UUID()
            var seeded: [RemotePathProbeResult] = []
            for round in 1...3 {
                var lan = RemotePathProbeResult(runID: runID, round: round, mode: .localNetwork,
                                                note: runIndex == 1 ? "家里" : "", network: network,
                                                connected: runIndex == 1, failure: runIndex == 1 ? nil : "Mac 不在这个局域网里")
                if runIndex == 1 {
                    lan.setupMillis = 180
                    lan.roundTripMillis = 4.2
                    lan.roundTripP95Millis = 9.8
                    lan.lossPercent = 0
                }
                let direct = RemotePathProbeResult(runID: runID, round: round, mode: .directIPv4, network: network,
                                                   connected: false, failure: "超时")
                var relay = RemotePathProbeResult(runID: runID, round: round, mode: .relay, network: network,
                                                  connected: true)
                relay.setupMillis = [1199, 1014, 936][round - 1]
                relay.roundTripMillis = [96, 113, 113][round - 1]
                relay.roundTripP95Millis = [174, 143, 184][round - 1]
                relay.lossPercent = 0
                seeded += [lan, direct, relay]
            }
            log.append(seeded)
        }
        let directory = RemoteMacDirectory(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()),
                                           defaults: defaults)
        for device in Self.devices {
            try await shoot("network-diagnostics", on: device, settle: .milliseconds(600)) {
                NavigationStack { RemoteNetworkDiagnosticsScreen(log: log) }
                    .environment(directory)
            }
            try await shoot("network-diagnostics-history", on: device, settle: .milliseconds(600)) {
                NavigationStack { RemotePathHistoryScreen(log: log) }
            }
        }
    }

    /// 远程桌面的键盘条：与终端同一个外壳，黑底深色。
    func testRemoteDesktopKeyBarPanels() async throws {
        defer { MobileProbeWindow.closeAll() }
        for device in Self.devices {
            for (name, panel) in [("row", nil), ("prompts", RemoteDesktopKeyBar.Panel.prompts), ("keys", .keys)] {
                try await shoot("remote-keybar-\(name)", on: device) {
                    VStack(spacing: 0) {
                        Color.black
                        RemoteDesktopKeyBar(keys: RemoteDesktopKeyState(), keyboardShown: .constant(false),
                                            panel: panel) { _ in }
                    }
                    .environment(\.colorScheme, .dark)
                }
            }
        }
    }

    // MARK: - SFTP 浏览（假会话）

    func testSFTPBrowser() async throws {
        defer { MobileProbeWindow.closeAll() }
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: c))

        for device in Self.devices {
            let provider = MobileFakeSFTPProvider(entries: 40, subdirectories: 6, childCount: 10, depth: 2)
            let (workspace, _) = await MobileFakeSFTP.workspace(host: host, provider: provider)
            try await shoot("sftp-browser", on: device) {
                WorkspaceScreen()
                    .environment(workspaceStore())
                    .environment(HostKeyChallengeRelay())
                    .environment(workspace)
                    .modelContainer(c)
            }
        }
    }

    // MARK: - Claude 历史会话（假的 ~/.claude/projects）

    /// 列表、对话、空态。宽屏（展开的 Duo、iPad）列表与对话左右并排，窄屏点进对话、左上角返回。
    func testClaudeHistoryTab() async throws {
        defer { MobileProbeWindow.closeAll() }
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: c))
        let relay = HostKeyChallengeRelay()

        func mount(_ workspace: MobileWorkspace) -> some View {
            WorkspaceScreen()
                .environment(workspaceStore())
                .environment(relay)
                .environment(workspace)
                .modelContainer(c)
        }

        for device in Self.devices {
            let workspace = MobileWorkspace()
            let history = workspace.openHistory(MobileFakeClaudeHistory.tab(host: host, tree: MobileClaudeFixture.standard()))
            let settled = await MobileFakeClaudeHistory.settle(history)
            XCTAssertTrue(settled)
            try await shoot("claude-history-list", on: device, settle: .milliseconds(600)) { mount(workspace) }

            let model = try XCTUnwrap(history.connection.history)
            model.select(try XCTUnwrap(model.visibleFiles.first))
            _ = await MobileFakeTerminal.waitUntil { model.transcript?.reachedStart == true }
            try await shoot("claude-history-transcript", on: device, settle: .milliseconds(900)) { mount(workspace) }

            // 会话还开着：往上翻着时末尾又写进了一问一答——标题旁「正在更新」、底部「有新消息」。
            let liveTree = MobileClaudeFixture.standard()
            let liveWorkspace = MobileWorkspace()
            let live = liveWorkspace.openHistory(MobileFakeClaudeHistory.tab(host: host, tree: liveTree))
            _ = await MobileFakeClaudeHistory.settle(live)
            let liveModel = try XCTUnwrap(live.connection.history)
            let liveFile = try XCTUnwrap(liveModel.visibleFiles.first)
            liveModel.select(liveFile)
            _ = await MobileFakeTerminal.waitUntil { liveModel.transcript?.reachedStart == true }
            await liveTree.append(liveFile.path, MobileClaudeFixture.user("顺便把慢查询日志也打开吧。", uuid: "u-live") + "\n"
                + MobileClaudeFixture.assistant(MobileClaudeFixture.text("好，已经在 `postgresql.conf` 里打开了。"), uuid: "a-live") + "\n")
            let liveTranscript = try XCTUnwrap(liveModel.transcript)
            liveTranscript.setFollowsTail(false)
            await liveTranscript.followOnce()
            try await shoot("claude-history-live", on: device, settle: .milliseconds(900)) { mount(liveWorkspace) }

            // 搜索：列表顶上的搜索框，结果按会话分组、命中的字加粗；点一条进到对话，停在那一条上（整条高亮）。
            let searchWorkspace = MobileWorkspace()
            let searching = searchWorkspace.openHistory(MobileFakeClaudeHistory.tab(host: host, tree: MobileClaudeFixture.standard()))
            _ = await MobileFakeClaudeHistory.settle(searching)
            let searchModel = try XCTUnwrap(searching.connection.history)
            searchModel.searchText = "接口"
            searchModel.submitSearch()
            _ = await MobileFakeTerminal.waitUntil { searchModel.search?.phase == .finished }
            try await shoot("claude-history-search", on: device, settle: .milliseconds(600)) { mount(searchWorkspace) }
            let hitSession = try XCTUnwrap(searchModel.search?.sessions.first)
            searchModel.openHit(try XCTUnwrap(hitSession.hits.first), in: hitSession)
            _ = await MobileFakeTerminal.waitUntil { searchModel.transcript?.items.isEmpty == false }
            try await shoot("claude-history-search-hit", on: device, settle: .milliseconds(900)) { mount(searchWorkspace) }

            // 比一屏长的对话：打开时停在最后一条（短的从顶上排起，见上一张）。
            let longWorkspace = MobileWorkspace()
            let long = longWorkspace.openHistory(MobileFakeClaudeHistory.tab(host: host, tree: MobileClaudeFixture.longOnly()))
            let longSettled = await MobileFakeClaudeHistory.settle(long)
            XCTAssertTrue(longSettled)
            let longModel = try XCTUnwrap(long.connection.history)
            longModel.select(try XCTUnwrap(longModel.visibleFiles.first))
            _ = await MobileFakeTerminal.waitUntil { longModel.transcript?.reachedStart == true }
            try await shoot("claude-history-long", on: device, settle: .milliseconds(900)) { mount(longWorkspace) }

            // 派了子代理的对话：调用下面有入口；点进第二个（它又派了一个，同样有入口），左上角返回上一层。
            let agentsWorkspace = MobileWorkspace()
            let agents = agentsWorkspace.openHistory(MobileFakeClaudeHistory.tab(host: host, tree: MobileClaudeFixture.withSubagents()))
            let agentsSettled = await MobileFakeClaudeHistory.settle(agents)
            XCTAssertTrue(agentsSettled)
            let agentsModel = try XCTUnwrap(agents.connection.history)
            agentsModel.select(try XCTUnwrap(agentsModel.visibleFiles.first))
            _ = await MobileFakeTerminal.waitUntil {
                agentsModel.transcript?.reachedStart == true && agentsModel.transcript?.subagentLinks.count == 2
            }
            try await shoot("claude-history-subagents", on: device, settle: .milliseconds(900)) { mount(agentsWorkspace) }
            let second = try XCTUnwrap(agentsModel.transcript?.subagentLinks["toolu_s2"])
            agentsModel.openSubagent(second)
            _ = await MobileFakeTerminal.waitUntil {
                agentsModel.displayedTranscript?.reachedStart == true
                    && agentsModel.displayedTranscript?.subagentLinks.isEmpty == false
            }
            try await shoot("claude-history-subagent", on: device, settle: .milliseconds(900)) { mount(agentsWorkspace) }

            // 这台主机上没用过 Claude Code：没有 ~/.claude/projects。
            let empty = MobileWorkspace()
            let none = empty.openHistory(MobileFakeClaudeHistory.tab(
                host: host, tree: MobileFakeClaudeTree(home: MobileClaudeFixture.home, files: [])))
            let emptySettled = await MobileFakeClaudeHistory.settle(none)
            XCTAssertTrue(emptySettled)
            try await shoot("claude-history-empty", on: device, settle: .milliseconds(500)) { mount(empty) }
        }
    }

    // MARK: - 分屏：终端 + 文件（多态标签）

    /// 左格两个终端标签、右格一个文件标签，聚焦右格：看前台胶囊与活动图标的配色（不画焦点框）。
    func testSplitWorkspace() async throws {
        defer { MobileProbeWindow.closeAll() }
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let hosts = Array(try c.mainContext.fetch(
            FetchDescriptor<ServerProfile>(sortBy: [SortDescriptor(\.sortOrder)])).filter { !$0.sftpOnly }.prefix(3))
        let relay = HostKeyChallengeRelay()

        for device in Self.devices {
            let (workspace, _) = MobileFakeTerminal.sessions(
                count: 2, hosts: hosts, script: .interactive(seconds: 2), container: c, relay: relay)
            for tab in workspace.terminalTabs { await MobileFakeTerminal.waitUntilConnected(tab.controller) }
            let provider = MobileFakeSFTPProvider(entries: 40, subdirectories: 6, childCount: 10, depth: 2)
            let files = FileTab(host: hosts[0], controller: await MobileFakeSFTP.controller(provider: provider))
            workspace.open(.files(files))
            workspace.moveToOtherPane(files.id)
            try await shoot("workspace-split", on: device, settle: .milliseconds(900)) {
                WorkspaceScreen()
                    .environment(workspaceStore())
                    .environment(relay)
                    .environment(workspace)
                    .modelContainer(c)
            }
            // 拖到底边选了「上下」：宽屏照办，窄屏本来就是上下。
            workspace.dock(files.id, to: .bottom)
            try await shoot("workspace-docked-bottom", on: device, settle: .milliseconds(600)) {
                WorkspaceScreen()
                    .environment(workspaceStore())
                    .environment(relay)
                    .environment(workspace)
                    .modelContainer(c)
            }
            // 分屏时在工作区里新开标签：连接中页只盖那个标签（这里是右格新开的文件标签），左格照常。
            workspace.dock(files.id, to: .trailing)
            let pending = FileTab(host: hosts[0])
            workspace.open(.files(pending))
            let connectingStore = workspaceStore()
            let req = MConnectRequest(host: hosts[0], kind: .sftp, origin: .hosts)
            req.originInWorkspace = true
            req.tabID = pending.id
            req.sftp = pending.controller
            connectingStore.connecting = req
            try await shoot("workspace-split-connecting", on: device, settle: .milliseconds(600)) {
                WorkspaceScreen()
                    .environment(connectingStore)
                    .environment(relay)
                    .environment(workspace)
                    .modelContainer(c)
            }
            for tab in workspace.terminalTabs { tab.controller.close() }
        }
    }

    // MARK: - Agent 会话 / 并行执行

    func testAgentAndParallel() async throws {
        defer { MobileProbeWindow.closeAll() }
        let c = try MobileFixtures.emptyContainer()
        let context = c.mainContext
        context.autosaveEnabled = false
        let provider = MobileFakeAgent.provider()
        context.insert(provider)
        let host = ServerProfile()
        host.name = "probe-node-01"
        host.host = "10.0.0.11"
        host.username = "root"
        context.insert(host)
        try context.save()

        let pc = try MobileFixtures.modelContainer(seed: .smoke)
        let profiles = Array(try pc.mainContext.fetch(
            FetchDescriptor<ServerProfile>(sortBy: [SortDescriptor(\.sortOrder)])).prefix(6))

        for device in Self.devices {
            let model = AssistantModel(client: MobilePacedLLMClient(chunks: []),
                                       provider: provider, apiKey: "sk-probe")
            model.attach(context: context)
            MobileFakeAgent.replayHistory(into: model, context: context, messages: 4)
            try await shoot("agent", on: device) {
                MobileAgentChat(model: model, host: host, tasks: MAgentTaskBag(),
                                serverContext: "probe-node-01（root@10.0.0.11:22）")
                    .environment(\.agentCommandExecutorFactory, .none)
                    .modelContainer(c)
            }
            model.dispose()

            let config = MobileFakeParallelRun.Config.streaming(
                hosts: profiles.count, lines: 30, seconds: 0.3, failing: 1, unreachable: 1)
            let fake = MobileFakeParallelRun(config: config, targets: profiles)
            let commandID = UUID()
            let controller = ParallelRunController(
                commandID: commandID, commandName: "重启并抓日志",
                command: config.command, intent: "", aiAssisted: false,
                targets: profiles, doctor: nil,
                store: QuickCommandStore(context: pc.mainContext),
                container: pc, executor: fake)
            let request = ParallelRunRequest(commandID: commandID, name: "重启并抓日志",
                                             command: config.command, intent: "",
                                             aiAssisted: false, serverIDs: profiles.map(\.id))
            controller.start()
            try await shoot("parallel", on: device, settle: .milliseconds(900)) {
                ParallelRunView(request: request, controller: controller, onClose: {})
                    .environment(store(tab: .commands))
                    .modelContainer(pc)
            }
            controller.cancel()
        }
    }

    // MARK: - Agent 输入区 / 模型服务

    /// Agent 空对话（输入区带思考深度）、模型选择、设置 › 模型服务的列表 / 编辑 / 新建。
    func testAgentComposerAndProviders() async throws {
        defer { MobileProbeWindow.closeAll() }
        let c = try MobileFixtures.emptyContainer()
        let context = c.mainContext
        context.autosaveEnabled = false
        let claude = AIProvider(name: "Claude", kind: .anthropic, baseURL: ProviderPreset.anthropicBaseURL,
                                model: "claude-opus-4-7", sortOrder: 0)
        let deepseek = AIProvider(name: "DeepSeek", kind: .openai, baseURL: "https://api.deepseek.com",
                                  model: "", sortOrder: 1)
        context.insert(claude)
        context.insert(deepseek)
        let host = ServerProfile()
        host.name = "probe-node-01"
        host.host = "10.0.0.11"
        host.username = "root"
        context.insert(host)
        try context.save()

        let suite = "StyleGallery-reasoning-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for device in Self.devices where device.name == "iphone" || device.name == "duo-split" {
            let model = AssistantModel(client: MobilePacedLLMClient(chunks: []),
                                       provider: claude, apiKey: "sk-probe")
            model.reasoningPreferences = AgentReasoningPreferences(defaults: defaults)
            model.attach(context: context)
            try await shoot("agent-empty", on: device) {
                MobileAgentChat(model: model, host: host, tasks: MAgentTaskBag(),
                                serverContext: "probe-node-01（root@10.0.0.11:22）")
                    .environment(\.agentCommandExecutorFactory, .none)
                    .modelContainer(c)
            }
            model.providers = [claude, deepseek]
            try await shoot("agent-model-picker", on: device) {
                MModelPickerSheet(model: model, activeProviderIDString: .constant(""),
                                  onManageProviders: {})
                    .modelContainer(c)
            }
            model.dispose()

            try await shoot("providers", on: device) {
                NavigationStack { ProvidersScreen() }.modelContainer(c)
            }
            try await shoot("provider-edit", on: device) {
                NavigationStack { ProviderEditScreen(provider: deepseek) }.modelContainer(c)
            }
            try await shoot("provider-new", on: device) {
                NewProviderSheet().modelContainer(c)
            }
        }
    }
}
