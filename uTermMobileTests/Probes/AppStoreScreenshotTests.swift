import ActivityKit
import CoreVideo
import Network
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// App Store 截图：真页面 + 干净的示例数据（保留网段与 example 域名），整屏连状态栏由外面的 `simctl io screenshot` 拍，
/// 再由 `internal/appstore/compose/` 的模板加上标题、底色与机身。
///
/// 每一屏整屏挂在宿主 App 的主窗口上（同 `PromoGalleryTests.shootDevice`：系统照真机排状态栏、安全区与工具栏），
/// 摆好后写 `<目录>/ready-<名字>`，等外面拍完写回 `<目录>/done-<名字>`（最多 60 秒）。
/// 外面的脚本是 `scripts/appstore-screenshots.sh`，三种设备各跑一遍：
/// - `iphone`：6.9 英寸 iPhone 竖握（1320×2868）
/// - `ipad`：13 英寸 iPad 竖握（2064×2752）
/// - `duo`：iPhone Duo 展开、横握的内屏（2853×2007）
///
/// 开关 `UTERM_APPSTORE_SHOTS_DIR`（不设就跳过）；`UTERM_APPSTORE_DEVICE` 选设备；远程桌面的画面取 Mac 画廊
/// （`make gallery GALLERY_FILTER=窗口模式` 与「桌面/远程桌面」）的出图目录 `UTERM_PROMO_MAC_SHOTS`。
/// 默认日间（`UTERM_APPSTORE_DARK=1` 改拍夜间），远程桌面的画面跟着取 Mac 画廊同一外观的图。
@MainActor
final class AppStoreScreenshotTests: XCTestCase {
    private enum Device: String { case iphone, ipad, duo }

    private var dir: URL!
    private var device: Device = .iphone
    private var dark = false
    /// 界面语言（`-testLanguage` 选的那个）：示例数据里的分组名、命令名跟着它换。
    private static var language: String { Bundle.main.preferredLocalizations.first ?? "zh-Hans" }

    /// 示例数据的文字，按界面语言取。没列出的语言用英文。
    private static func text(_ zh: String, en: String, hant: String, ja: String, ko: String) -> String {
        switch language {
        case "zh-Hans": zh
        case "zh-Hant": hant
        case "ja": ja
        case "ko": ko
        default: en
        }
    }
    private static let groupProd = text("生产", en: "Production", hant: "正式", ja: "本番", ko: "운영")
    private static let groupTest = text("测试", en: "Staging", hant: "測試", ja: "検証", ko: "테스트")
    private static let groupHome = text("家里", en: "Home", hant: "家裡", ja: "自宅", ko: "집")
    private static let restartCheck = text("重启服务并检查", en: "Restart and check", hant: "重新啟動服務並檢查",
                                           ja: "再起動して確認", ko: "재시작 후 확인")
    private static let now = Date()

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        guard let path = env["UTERM_APPSTORE_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("未设置 UTERM_APPSTORE_SHOTS_DIR：App Store 截图只按需跑")
        }
        dir = URL(fileURLWithPath: path, isDirectory: true)
        device = Device(rawValue: env["UTERM_APPSTORE_DEVICE"] ?? "") ?? .iphone
        dark = env["UTERM_APPSTORE_DARK"] == "1"
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func testScreens() async throws {
        // iPad 横握拍：商店图用横屏（分屏、远程桌面都更舒展）。
        if device == .ipad { try await rotateToLandscape() }
        let (container, hosts) = try fixtures()
        let relay = HostKeyChallengeRelay()
        let suite = "AppStoreScreenshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (directory, macsOnline) = try macDirectory(defaults)
        let lan = LANSyncCoordinator(role: .receiver, preferences: SharedPreferencesSync(),
                                     dataStore: LANSyncDataStore(container: container))
        let subscriptions = SubscriptionStore.live()
        let web = try XCTUnwrap(hosts["prod-web-01"])

        /// 真的外壳（同 `MobileRootView`）：主机页 / 命令页 + 盖在上面的工作区。
        func shell(_ store: MobileStore, _ workspace: MobileWorkspace) -> some View {
            ZStack {
                MobileTabShell()
                WorkspaceLayer()
            }
            .environment(store)
            .environment(workspace)
            .environment(relay)
            .environment(TerminalActivityCenter())
            .environment(lan)
            .environment(directory)
            .environment(subscriptions)
            .environment(CloudKitSyncMonitor())
            .modelContainer(container)
        }
        func terminal(_ host: ServerProfile, _ text: String) -> TermTab {
            let tab = TermTab(host: host, transportFactory: MobileTerminalTransportFactory { _ in
                TranscriptBackend(text: text)
            })
            tab.controller.start(profile: host, container: container, relay: relay)
            return tab
        }
        func files(_ host: ServerProfile) async -> FileTab {
            let tab = FileTab(host: host, controller: MobileSFTPController(
                testProvider: DemoSFTPProvider(fileSystem: Self.siteFileSystem()), startPath: "/srv/www/shop"))
            await tab.controller.load("/srv/www/shop")
            return tab
        }
        var opened: [TermTab] = []
        defer { for tab in opened { tab.controller.close() } }

        // 终端：Duo 横握正好是 Claude Code 录制时的 106×35；竖屏放不下全屏界面，用写好的 shell 输出。
        do {
            let workspace = MobileWorkspace()
            // Claude Code 的录制是中文对话，只在简体中文里用。
            let claude = device == .duo && Self.language == "zh-Hans"
            let front = terminal(web, claude ? Self.claudeTranscript : Self.terminalTranscript)
            let others = ["staging", "prod-db"].compactMap { hosts[$0] }.map { terminal($0, Self.terminalTranscript) }
            opened += [front] + others
            for tab in others { workspace.open(.terminal(tab)) }
            workspace.open(.terminal(front))
            workspace.activate(front.id)
            let store = MobileStore()
            store.showWorkspace = true
            try await present("1-terminal", settle: .seconds(2)) { shell(store, workspace) }
        }

        // 接管 Mac 上的终端：远控标签（标签上带 Mac 的记号），内容是写好的输出。
        do {
            let client = RemoteMacClient(macName: "MacBook Pro", endpoint: .hostPort(host: "127.0.0.1", port: 9),
                                         identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
            let workspace = MobileWorkspace()
            var front: TermTab?
            for (title, text) in [("MacBook Pro", Self.macDevTranscript), ("MacBook Pro", Self.macTestTranscript),
                                  ("prod-web-01", Self.terminalTranscript)] {
                let host = ServerProfile()
                host.name = title
                host.host = title == "MacBook Pro" ? "本机" : "10.0.1.11"
                let tab = TermTab(host: host, remote: MRemoteSource(client: client, sessionID: UUID()),
                                  transportFactory: MobileTerminalTransportFactory { _ in TranscriptBackend(text: text) })
                tab.controller.start(profile: host, container: container, relay: relay)
                opened.append(tab)
                workspace.open(.terminal(tab))
                front = front ?? tab
            }
            if let front { workspace.activate(front.id) }
            let store = MobileStore()
            store.showWorkspace = true
            try await present("2-mac-terminal", settle: .seconds(2)) { shell(store, workspace) }
        }

        // 远程桌面：整块屏幕在 Duo 与 iPad 横握拍（竖屏里 Mac 的横屏画面只剩中间一条）；两者再拍窗口模式
        // （iPhone 竖握比 Mac 终端窗口的最小宽度还窄）。
        // Mac 把窗口调成手机画布的大小：Duo 横握 951×669 点、13 英寸 iPad 横握 1376×1032 点（同 Mac 画廊里那几张图）。
        let canvas = device == .duo ? CGSize(width: 951, height: 669) : CGSize(width: 1376, height: 1032)
        if device != .iphone {
            let client = RemoteMacClient(macName: "MacBook Pro", endpoint: .hostPort(host: "127.0.0.1", port: 9),
                                         identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
            let session = RemoteDesktopSession(client: client, maxWidth: 3024, maxHeight: 1964)
            let desktop = try Self.macFrame("桌面__远程桌面", dark: dark)
            try await present("3-remote-desktop", settle: .milliseconds(1_400), before: {
                session.showGalleryWindow(desktop, windowID: nil, title: nil, pointSize: CGSize(width: 1512, height: 982))
            }) {
                RemoteDesktopScreen(client: client, started: session, onClose: {})
                    .environment(subscriptions)
            }
            session.stop()
        }
        if device != .iphone {
            let client = RemoteMacClient(macName: "MacBook Pro", endpoint: .hostPort(host: "127.0.0.1", port: 9),
                                         identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
            let session = RemoteDesktopSession(client: client, maxWidth: Int(canvas.width * 3),
                                               maxHeight: Int(canvas.height * 3))
            // 窗口模式的画面：简体中文用跑着 Claude Code 的那张，别的语言用命令行输出的那张（录制是中文对话）。
            let base = device == .duo ? "终端窗口__手机窗口模式" : "终端窗口__iPad_横屏窗口模式"
            let frame = try Self.macFrame(Self.language == "zh-Hans" ? base : base + "_命令行", dark: dark)
            try await present("4-remote-window", settle: .milliseconds(1_400), before: {
                session.showGalleryWindow(frame, windowID: 1, title: "prod-web-01", pointSize: canvas)
            }) {
                RemoteDesktopScreen(client: client, started: session, initialWindow: 1, onClose: {})
                    .environment(subscriptions)
            }
            session.stop()
        }

        // 分屏：终端 + 文件。
        do {
            let workspace = MobileWorkspace()
            let term = terminal(web, Self.terminalTranscript)
            opened.append(term)
            workspace.open(.terminal(term))
            let browser = await files(web)
            workspace.open(.files(browser))
            workspace.moveToOtherPane(browser.id)
            let store = MobileStore()
            store.showWorkspace = true
            try await present("5-split", settle: .seconds(2)) { shell(store, workspace) }
        }

        // 文件（iPhone、iPad 单独一张；Duo 的分屏已经够大）。
        if device != .duo {
            let workspace = MobileWorkspace()
            workspace.open(.files(await files(web)))
            let store = MobileStore()
            store.showWorkspace = true
            try await present("6-files") { shell(store, workspace) }
        }

        // 并行执行（写好的输出，像真的 SSH 一样整段返回）。
        do {
            let targets = ["prod-web-01", "prod-web-02", "staging", "k3s-lab", "nas", "raspberry-pi"].compactMap { hosts[$0] }
            let command = "systemctl restart app && systemctl is-active app && curl -s localhost:8080/healthz"
            let commandID = UUID()
            let controller = ParallelRunController(
                commandID: commandID, commandName: Self.restartCheck, command: command, intent: "", aiAssisted: false,
                targets: targets, doctor: nil, store: QuickCommandStore(context: container.mainContext),
                container: container, executor: ScriptedParallelExecutor())
            let request = ParallelRunRequest(commandID: commandID, name: Self.restartCheck, command: command,
                                             intent: "", aiAssisted: false, serverIDs: targets.map(\.id))
            controller.start()
            let store = MobileStore()
            store.tab = .commands
            try await present("7-parallel", settle: .seconds(2)) {
                ParallelRunView(request: request, controller: controller, onClose: {})
                    .environment(store).environment(subscriptions).modelContainer(container)
            }
            controller.cancel()
        }

        // Code 标签页：三种编码工具的会话按项目分组，Codex 那个会话正在这个标签页里跑（行上标着状态），
        // 右边（窄屏是详情那一层）是 Claude Code 一次对话的记录。iPhone 另拍一张列表。
        do {
            defaults.set(AgentHistoryGrouping.project.rawValue, forKey: DefaultsKey.agentHistoryGrouping)
            defaults.removeObject(forKey: DefaultsKey.agentHistoryShownTools)
            let workspace = MobileWorkspace()
            let term = terminal(web, Self.terminalTranscript)
            opened.append(term)
            workspace.open(.terminal(term))
            let code = workspace.openHistory(MobileAgentHistoryFixture.tab(host: web, source: Self.codeSource(long: device == .ipad),
                                                                           directory: Self.shopDir))
            code.runTerminalFactory = { MobileFakeTerminal.tab(host: $0, .transcript(Self.codexRunTranscript)).0 }
            _ = await MobileFakeClaudeHistory.settle(code)
            let model = try XCTUnwrap(code.connection.history)
            let codex = try XCTUnwrap(model.visibleFiles.first { $0.sessionID == "x-tests" })
            let plan = try XCTUnwrap(model.resumeCommand(for: codex))
            code.resumeInPlace(codex, command: plan.command, directory: plan.directory, container: container, relay: relay)
            for run in code.runs.runs {
                _ = await MobileFakeTerminal.waitUntilConnected(run.terminal.controller)
                code.finishCover(run.id)
            }
            let login = try XCTUnwrap(model.visibleFiles.first { $0.sessionID == "c-login" })
            code.select(login)
            _ = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) { model.transcript?.reachedStart == true }
            let store = MobileStore()
            store.showWorkspace = true
            try await present("9-code", settle: .seconds(2)) { shell(store, workspace).defaultAppStorage(defaults) }
            if device == .iphone {
                code.backToList()
                try await present("9-code-list", settle: .seconds(1)) { shell(store, workspace).defaultAppStorage(defaults) }
            }
            code.close()
        }

        // 主机：顶上是体验主机，下面是「我的 Mac」与分组。
        do {
            let store = MobileStore()
            store.tab = .hosts
            try await present("8-hosts", before: { directory.setDiscovered(macsOnline) }) {
                shell(store, MobileWorkspace())
            }
        }

        // 灵动岛（只拍 iPhone，放最后：拍的时候 App 被外面切到后台，之后不再回到前台）。
        // 三个终端标签页报着程序状态（OSC 7501）：Claude Code 等待确认、Codex 运行中、另一个 Claude Code 已完成。
        if device == .iphone {
            let workspace = MobileWorkspace()
            let rows: [(String, String, String)] = [
                ("prod-web-01", Self.text("修复登录超时", en: "Fix login timeout", hant: "修復登入逾時", ja: "ログインのタイムアウト修正",
                                          ko: "로그인 시간 초과 수정"), "state=blocked:app=claude-code:kind=permission"),
                ("staging", Self.text("订单服务集成测试", en: "Order service tests", hant: "訂單服務整合測試", ja: "注文サービスのテスト",
                                      ko: "주문 서비스 테스트"), "state=working:app=codex"),
                ("k3s-lab", Self.text("升级 nginx 到 1.27", en: "Upgrade nginx to 1.27", hant: "升級 nginx 到 1.27",
                                      ja: "nginx を 1.27 に更新", ko: "nginx 1.27로 업그레이드"), "state=done:app=claude-code"),
            ]
            var front: TermTab?
            for (name, title, status) in rows {
                guard let host = hosts[name] else { continue }
                let text = Self.terminalTranscript + "\u{1B}]2;\(title)\u{07}\u{1B}]7501;\(status)\u{1B}\\"
                let tab = terminal(host, text)
                opened.append(tab)
                workspace.open(.terminal(tab))
                front = front ?? tab
            }
            if let front { workspace.activate(front.id) }
            let center = TerminalActivityCenter()
            center.start(workspace: workspace)
            let store = MobileStore()
            store.showWorkspace = true
            try await present("10-live", settle: .seconds(3), timeout: 120, onSignal: { _ in
                await Self.alertLiveActivity()
            }) {
                shell(store, workspace).environment(center)
            }
        }
    }

    /// 外面把 App 按到后台之后，给实时活动推一次带提醒的更新：系统会把灵动岛展开几秒（拍展开态）。
    /// 内容不变，只是让系统提醒一下；App 自己不这么推（它在后台改发本地通知）。
    private static func alertLiveActivity() async {
        guard let activity = Activity<TerminalActivityAttributes>.activities.first else { return }
        let handle = UncheckedSendable(activity)
        let alert = AlertConfiguration(
            title: LocalizedStringResource(stringLiteral: "Claude Code"),
            body: LocalizedStringResource(stringLiteral: text("等待确认", en: "Waiting for approval", hant: "等待確認",
                                                              ja: "承認待ち", ko: "승인 대기")),
            sound: .default)
        await pushAlert(handle, alert)
    }

    private nonisolated static func pushAlert(_ handle: UncheckedSendable<Activity<TerminalActivityAttributes>>,
                                              _ alert: AlertConfiguration) async {
        await handle.value.update(handle.value.content, alertConfiguration: alert)
    }

    // MARK: - 摆一屏，等外面拍

    /// iPad 要横握拍。App 在 iPad 上改不了自己的方向（`requestGeometryUpdate` 报 UISceneErrorDomain 101），由外面的脚本用
    /// `devicectl device orientation set` 把模拟器转成横屏；这里等它转好，没转就跳过并说明。
    private func rotateToLandscape() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let refusal = UncheckedSendable(NSMutableString())
        if !scene.effectiveGeometry.interfaceOrientation.isLandscape {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                refusal.value.setString(error.localizedDescription)
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while !scene.effectiveGeometry.interfaceOrientation.isLandscape, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard scene.effectiveGeometry.interfaceOrientation.isLandscape else {
            throw XCTSkip("iPad 不是横屏（\(refusal.value)）：先 `xcrun devicectl device orientation set --device <模拟器> landscapeLeft`")
        }
    }

    /// 整屏挂在宿主 App 的主窗口上（临时换掉它的根控制器，拍完换回），排好后请外面截屏。
    /// `onSignal`：外面拍的途中写 `signal-<名字>` 时调一次（灵动岛：App 已经在后台了，推一次带提醒的更新），
    /// 做完写回 `signaled-<名字>`。
    private func present<V: View>(_ name: String, settle: Duration = .milliseconds(900), timeout: TimeInterval = 60,
                                  onSignal: ((String) async -> Void)? = nil,
                                  before: () -> Void = {}, _ view: () -> V) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow } ?? scene.windows.first)
        let original = window.rootViewController
        let originalStyle = window.overrideUserInterfaceStyle
        defer {
            window.rootViewController = original
            window.overrideUserInterfaceStyle = originalStyle
        }
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let host = ScreenshotHostingController(rootView: AnyView(view()
            .environment(\.mAccent, M.accent)
            .tint(M.accent)
            .mMeasuresChrome()
            .persistentSystemOverlays(.hidden)))
        host.view.backgroundColor = dark ? .black : .white
        window.rootViewController = host
        host.setNeedsUpdateOfHomeIndicatorAutoHidden()
        try await Task.sleep(for: .milliseconds(600))
        before()
        try await Task.sleep(for: settle)
        // 终端挂上会拿焦点、弹出软键盘，商店图里收起来（键盘条照常显示）。
        window.endEditing(true)
        try await Task.sleep(for: .milliseconds(700))
        let ready = dir.appendingPathComponent("ready-\(name)")
        let done = dir.appendingPathComponent("done-\(name)")
        try? FileManager.default.removeItem(at: done)
        try Data().write(to: ready)
        let signal = dir.appendingPathComponent("signal-\(name)")
        let signaled = dir.appendingPathComponent("signaled-\(name)")
        try? FileManager.default.removeItem(at: signal)
        try? FileManager.default.removeItem(at: signaled)
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
            if let onSignal, FileManager.default.fileExists(atPath: signal.path),
               !FileManager.default.fileExists(atPath: signaled.path) {
                await onSignal(name)
                try Data().write(to: signaled)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try? FileManager.default.removeItem(at: ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "外面没拍 \(name)")
    }

    /// 「我的 Mac」：两台配对过的 Mac，名字中性，标成在局域网里找得到（同 `PromoGalleryTests`）。
    private func macDirectory(_ defaults: UserDefaults) throws
        -> (RemoteMacDirectory, [UUID: (name: String, endpoint: NWEndpoint)]) {
        defaults.set(true, forKey: DefaultsKey.remoteBrowseActivated)
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let macs = [(UUID(), "MacBook Pro"), (UUID(), "Mac mini")]
        for (i, (id, name)) in macs.enumerated() {
            try identity.trust(RemotePeer(id: id, name: name, publicKey: Data(count: 32),
                                          pairedAt: Self.now.addingTimeInterval(-86_400 * Double(30 - i))))
        }
        let directory = RemoteMacDirectory(identity: identity, defaults: defaults)
        var found: [UUID: (name: String, endpoint: NWEndpoint)] = [:]
        for (i, (id, name)) in macs.enumerated() {
            found[id] = (name, .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(9 + i))!))
        }
        directory.setDiscovered(found)
        return (directory, found)
    }

    /// Mac 画廊渲的一张图，当成远程桌面里 Mac 送来的画面。
    private static func macFrame(_ name: String, dark: Bool) throws -> CVPixelBuffer {
        let dir = try XCTUnwrap(ProcessInfo.processInfo.environment["UTERM_PROMO_MAC_SHOTS"],
                                "设 TEST_RUNNER_UTERM_PROMO_MAC_SHOTS=<make gallery 的出图目录>")
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)--\(dark ? "dark" : "light").png")
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage, "缺图：\(url.path)")
        let width = image.width, height = image.height
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                      kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer),
                       kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let context = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(UIColor.black.cgColor)   // 窗口圆角外面是透明的，垫黑底
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    // MARK: - 示例数据

    private func fixtures() throws -> (ModelContainer, [String: ServerProfile]) {
        let c = try MobileFixtures.emptyContainer()
        let ctx = c.mainContext
        for (i, (name, color)) in [(Self.groupProd, "#ef4444"), (Self.groupTest, "#3b82f6"), (Self.groupHome, "#a855f7")].enumerated() {
            ctx.insert(ServerGroup(name: name, colorHex: color, isPinned: i == 0, sortOrder: i))
        }
        let key = SSHKey()
        key.name = "iphone-2026"
        key.typeRaw = SSHKeyKind.ed25519.rawValue
        key.bits = 256
        key.fingerprint = "SHA256:Qm4bXo2Lk3T0w8V1sN7cHf9eRZy6aJd5uPq2gKtW4E"
        ctx.insert(key)
        let rows: [(String, String, String, String, Double?)] = [
            ("bastion", "203.0.113.10", "ops", Self.groupProd, -3_600),
            ("prod-web-01", "10.0.1.11", "deploy", Self.groupProd, -180),
            ("prod-web-02", "10.0.1.12", "deploy", Self.groupProd, -7_200),
            ("prod-db", "10.0.2.21", "postgres", Self.groupProd, -86_400),
            ("staging", "staging.example.com", "deploy", Self.groupTest, -1_800),
            ("k3s-lab", "192.168.10.30", "ubuntu", Self.groupTest, -86_400 * 3),
            ("nas", "192.168.1.5", "admin", Self.groupHome, -86_400 * 9),
            ("raspberry-pi", "192.168.1.42", "pi", Self.groupHome, nil),
        ]
        var hosts: [String: ServerProfile] = [:]
        for (i, r) in rows.enumerated() {
            let p = ServerProfile()
            p.name = r.0
            p.host = r.1
            p.username = r.2
            p.group = r.3
            p.sortOrder = i
            p.lastConnectedAt = r.4.map { Self.now.addingTimeInterval($0) }
            p.keyID = key.id
            p.authMethodRaw = AuthMethod.privateKey.rawValue
            ctx.insert(p)
            hosts[r.0] = p
        }
        for (i, (name, command)) in [(Self.text("重启服务并看日志", en: "Restart and tail logs", hant: "重新啟動服務並看日誌", ja: "再起動してログを確認",
                                                ko: "재시작 후 로그 보기"), "systemctl restart app && journalctl -u app -n 40"),
                                     (Self.text("磁盘占用", en: "Disk usage", hant: "磁碟用量", ja: "ディスク使用量", ko: "디스크 사용량"), "df -h /"),
                                     (Self.text("清理 Docker", en: "Clean up Docker", hant: "清理 Docker", ja: "Docker を掃除", ko: "Docker 정리"),
                                      "docker system prune -f")].enumerated() {
            let q = QuickCommand()
            q.name = name
            q.command = command
            q.serverIDs = Array(hosts.values.prefix(4 - i)).map(\.id)
            ctx.insert(q)
        }
        try ctx.save()
        return (c, hosts)
    }

    // MARK: Code 标签页的示例数据

    static let shopDir = "/home/deploy/shop-api"
    private static let infraDir = "/home/deploy/infra"
    private static let blogDir = "/home/deploy/blog"

    /// 三种编码工具的会话（手写，按界面语言）：shop-api 下三种都有，另有 infra、blog。
    private static func codeSource(long: Bool = false) -> any AgentHistorySource {
        typealias Session = MobileFakeAgentSource.Session
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        let claude = MobileFakeAgentSource(tool: .claude, sessions: [
            Session(id: "c-login", projectID: ClaudeProjectPath.encode(shopDir), resumeDirectory: shopDir,
                    title: text("登录接口偶发 500", en: "Login API returns 500 at times", hant: "登入介面偶發 500",
                                ja: "ログイン API がときどき 500", ko: "로그인 API 간헐적 500"),
                    modifiedAt: ago(60 * 3), branch: "fix/login-timeout", items: loginConversation(at: ago(60 * 3), long: long)),
            Session(id: "c-page", projectID: ClaudeProjectPath.encode(shopDir), resumeDirectory: shopDir,
                    title: text("给订单接口加分页", en: "Paginate the orders API", hant: "幫訂單介面加分頁",
                                ja: "注文 API にページングを追加", ko: "주문 API에 페이지네이션 추가"),
                    modifiedAt: ago(86_400 * 2 + 600), branch: "feat/paging"),
            Session(id: "c-nginx", projectID: ClaudeProjectPath.encode(infraDir), resumeDirectory: infraDir,
                    title: text("升级 nginx 到 1.27", en: "Upgrade nginx to 1.27", hant: "升級 nginx 到 1.27",
                                ja: "nginx を 1.27 に更新", ko: "nginx 1.27로 업그레이드"),
                    modifiedAt: ago(86_400 + 3600 * 2)),
            Session(id: "c-font", projectID: ClaudeProjectPath.encode(blogDir), resumeDirectory: blogDir,
                    title: text("首页换一套字体", en: "New fonts for the home page", hant: "首頁換一套字型",
                                ja: "トップページのフォントを変更", ko: "홈페이지 글꼴 변경"),
                    modifiedAt: ago(86_400 * 6), branch: nil),
        ])
        let codex = MobileFakeAgentSource(tool: .codex, sessions: [
            Session(id: "x-tests", projectID: "2026-11-26", projectDirectory: shopDir, resumeDirectory: shopDir,
                    title: text("订单服务补集成测试", en: "Integration tests for orders", hant: "訂單服務補整合測試",
                                ja: "注文サービスの結合テスト", ko: "주문 서비스 통합 테스트"),
                    modifiedAt: ago(60 * 20)),
            Session(id: "x-cert", projectID: "2026-11-21", projectDirectory: infraDir, resumeDirectory: infraDir,
                    title: text("证书续期脚本", en: "Certificate renewal script", hant: "憑證續期腳本",
                                ja: "証明書の更新スクリプト", ko: "인증서 갱신 스크립트"),
                    modifiedAt: ago(86_400 * 4), branch: nil),
        ])
        let antigravity = MobileFakeAgentSource(tool: .antigravity, sessions: [
            Session(id: "u-readme", projectID: "ws-1", projectDirectory: shopDir, resumeDirectory: shopDir,
                    title: text("补 README 的部署一节", en: "Add a deploy section to README", hant: "補 README 的部署一節",
                                ja: "README にデプロイ手順を追加", ko: "README에 배포 절차 추가"),
                    modifiedAt: ago(3600 * 5)),
            Session(id: "u-lazy", projectID: "ws-2", projectDirectory: blogDir, resumeDirectory: blogDir,
                    title: text("图片懒加载", en: "Lazy-load images", hant: "圖片延遲載入",
                                ja: "画像の遅延読み込み", ko: "이미지 지연 로딩"),
                    modifiedAt: ago(86_400 * 9), branch: nil),
        ])
        return AgentHistoryCompositeSource([claude, codex, antigravity])
    }

    /// Claude Code 修登录超时的一次对话。`long`：多一轮（加索引、跑测试、总结改了什么），竖握的 iPad 上才铺得满。
    private static func loginConversation(at date: Date, long: Bool = false) -> [AgentTranscriptItem] {
        func call(_ id: String, _ name: String, _ summary: String, _ output: String, error: Bool = false) -> AgentToolCall {
            AgentToolCall(toolUseID: id, name: name, summary: summary,
                          result: AgentToolResult(toolUseID: id, content: AgentClippedText(output, limit: 4000),
                                                  isError: error, imageCount: 0))
        }
        let fail = "--- FAIL: TestLoginTimeout (2.01s)\n    handler_test.go:88: context deadline exceeded\nFAIL"
        let pass = "ok  \tshop-api/internal/auth\t0.84s"
        var items: [AgentTranscriptItem] = [
            AgentTranscriptItem(id: "u1", kind: .userText(text(
                "登录接口偶尔返回 500，日志里是 `context deadline exceeded`。帮我找找原因。",
                en: "Login sometimes returns 500 with `context deadline exceeded`. Can you find out why?",
                hant: "登入介面偶爾回傳 500，日誌裡是 `context deadline exceeded`。幫我找找原因。",
                ja: "ログイン API がときどき 500（`context deadline exceeded`）。原因を調べてください。",
                ko: "로그인 API가 가끔 500(`context deadline exceeded`)을 반환해요. 원인을 찾아 주세요.")),
                                timestamp: date.addingTimeInterval(-600)),
            AgentTranscriptItem(id: "t1", kind: .toolCall(call("t1", "Bash", "go test ./internal/auth/... -run TestLogin",
                                                              fail, error: true)),
                                timestamp: date.addingTimeInterval(-580)),
            AgentTranscriptItem(id: "a2", kind: .assistantText(text(
                """
                复现了。`Login` 每次请求都新建数据库连接，连接池上限只有 **5**，高峰时排队超过 2 秒就超时。

                1. 复用全局的 `db.Pool`，不在 handler 里 `Open`
                2. 把 `MaxOpenConns` 调到 20
                """,
                en: """
                Reproduced. `Login` opens a new database connection on every request, and the pool is capped at **5**, \
                so requests queue for over 2 seconds at peak and time out.

                1. Reuse the shared `db.Pool` instead of calling `Open` in the handler
                2. Raise `MaxOpenConns` to 20
                """,
                hant: """
                重現了。`Login` 每次請求都新建資料庫連線，連線池上限只有 **5**，尖峰時排隊超過 2 秒就逾時。

                1. 共用全域的 `db.Pool`，不在 handler 裡 `Open`
                2. 把 `MaxOpenConns` 調到 20
                """,
                ja: """
                再現しました。`Login` がリクエストごとに DB 接続を開いていて、プールの上限が **5** しかないため、\
                ピーク時に 2 秒以上待たされてタイムアウトします。

                1. handler で `Open` せず、共有の `db.Pool` を使う
                2. `MaxOpenConns` を 20 に上げる
                """,
                ko: """
                재현됐어요. `Login`이 요청마다 DB 연결을 새로 열고, 커넥션 풀 상한이 **5**라서 \
                피크 때 2초 넘게 기다리다 시간 초과가 납니다.

                1. 핸들러에서 `Open`하지 말고 공용 `db.Pool` 재사용
                2. `MaxOpenConns`를 20으로 상향
                """)), timestamp: date.addingTimeInterval(-500)),
            AgentTranscriptItem(id: "u2", kind: .userText(text(
                "两条都改吧。", en: "Go ahead with both.", hant: "兩條都改吧。", ja: "両方やってください。", ko: "둘 다 해 주세요.")),
                                timestamp: date.addingTimeInterval(-200)),
            AgentTranscriptItem(id: "t2", kind: .toolCall(call("t2", "Edit", "internal/auth/handler.go", "")),
                                timestamp: date.addingTimeInterval(-150)),
            AgentTranscriptItem(id: "t3", kind: .toolCall(call("t3", "Bash", "go test ./internal/auth/...", pass)),
                                timestamp: date.addingTimeInterval(-60)),
            AgentTranscriptItem(id: "a3", kind: .assistantText(text(
                "改好了，`TestLoginTimeout` 现在能过，压测 200 并发也没有再超时。",
                en: "Done. `TestLoginTimeout` passes now, and a 200-concurrency load test no longer times out.",
                hant: "改好了，`TestLoginTimeout` 現在能過，壓測 200 併發也沒有再逾時。",
                ja: "修正しました。`TestLoginTimeout` が通り、同時 200 の負荷試験でもタイムアウトしなくなりました。",
                ko: "수정했어요. 이제 `TestLoginTimeout`이 통과하고, 동시 200 부하 테스트에서도 시간 초과가 없어요.")),
                                timestamp: date),
            AgentTranscriptItem(id: "u3", kind: .userText(text(
                "顺便看看订单列表为什么慢。", en: "Also, why is the order list so slow?", hant: "順便看看訂單列表為什麼慢。",
                ja: "ついでに注文一覧が遅い理由も見てください。", ko: "주문 목록이 느린 이유도 봐 주세요.")),
                                timestamp: date.addingTimeInterval(-40)),
            AgentTranscriptItem(id: "t4", kind: .toolCall(call("t4", "Bash",
                                                              "psql -c \"EXPLAIN ANALYZE SELECT * FROM orders ORDER BY created_at DESC LIMIT 50\"",
                                                              "Seq Scan on orders  (rows=1204331)\nExecution Time: 1812.4 ms")),
                                timestamp: date.addingTimeInterval(-30)),
            AgentTranscriptItem(id: "a4", kind: .assistantText(text(
                "`orders.created_at` 没有索引，每次都扫全表（120 万行）。加上索引后从 **1.8 s 降到 12 ms**：\n\n```sql\nCREATE INDEX CONCURRENTLY idx_orders_created_at ON orders (created_at DESC);\n```",
                en: "`orders.created_at` has no index, so every query scans the whole table (1.2M rows). With an index it drops from **1.8 s to 12 ms**:\n\n```sql\nCREATE INDEX CONCURRENTLY idx_orders_created_at ON orders (created_at DESC);\n```",
                hant: "`orders.created_at` 沒有索引，每次都掃全表（120 萬列）。加上索引後從 **1.8 s 降到 12 ms**：\n\n```sql\nCREATE INDEX CONCURRENTLY idx_orders_created_at ON orders (created_at DESC);\n```",
                ja: "`orders.created_at` にインデックスがなく、毎回 120 万行を全件スキャンしています。インデックスを張ると **1.8 s → 12 ms** になります：\n\n```sql\nCREATE INDEX CONCURRENTLY idx_orders_created_at ON orders (created_at DESC);\n```",
                ko: "`orders.created_at`에 인덱스가 없어 매번 120만 행을 전체 스캔해요. 인덱스를 추가하면 **1.8 s → 12 ms**로 줄어요:\n\n```sql\nCREATE INDEX CONCURRENTLY idx_orders_created_at ON orders (created_at DESC);\n```")),
                                timestamp: date),
        ]
        if long {
            let migration = "migrations/0042_orders_created_at.sql"
            items += [
                AgentTranscriptItem(id: "u4", kind: .userText(text(
                    "把索引写成迁移，再把全部测试跑一遍。", en: "Add the index as a migration and run all the tests.",
                    hant: "把索引寫成遷移，再把全部測試跑一遍。", ja: "インデックスをマイグレーションにして、テストを全部流してください。",
                    ko: "인덱스를 마이그레이션으로 추가하고 전체 테스트를 돌려 주세요.")), timestamp: date),
                AgentTranscriptItem(id: "t5", kind: .toolCall(call("t5", "Write", migration, "")), timestamp: date),
                AgentTranscriptItem(id: "t6", kind: .toolCall(call("t6", "Bash", "go test ./...", "ok  \tshop-api/...\t(37 packages)")),
                                    timestamp: date),
                AgentTranscriptItem(id: "a5", kind: .assistantText(text(
                    "全部 37 个包的测试都通过了。这次改了：\n\n- `internal/auth/handler.go`：复用连接池\n- `config/db.go`：`MaxOpenConns` 调到 20\n- `\(migration)`：`orders.created_at` 的索引",
                    en: "All 37 packages pass. Changes in this session:\n\n- `internal/auth/handler.go`: reuse the connection pool\n- `config/db.go`: `MaxOpenConns` raised to 20\n- `\(migration)`: index on `orders.created_at`",
                    hant: "全部 37 個套件的測試都通過了。這次改了：\n\n- `internal/auth/handler.go`：共用連線池\n- `config/db.go`：`MaxOpenConns` 調到 20\n- `\(migration)`：`orders.created_at` 的索引",
                    ja: "37 パッケージすべてのテストが通りました。今回の変更：\n\n- `internal/auth/handler.go`：接続プールを共有\n- `config/db.go`：`MaxOpenConns` を 20 に\n- `\(migration)`：`orders.created_at` のインデックス",
                    ko: "37개 패키지 테스트가 모두 통과했어요. 이번 변경 사항:\n\n- `internal/auth/handler.go`: 커넥션 풀 재사용\n- `config/db.go`: `MaxOpenConns`를 20으로\n- `\(migration)`: `orders.created_at` 인덱스")),
                                    timestamp: date),
            ]
        }
        items.append(AgentTranscriptItem(id: "usage", kind: .usage(AgentTurnUsage(model: "claude-opus-4-5", contextTokens: 48_210,
                                                                       outputTokens: 1_284)), timestamp: date))
        return items
    }

    /// Code 标签页里跑着的 Codex 会话：终端里的样子，程序经 OSC 7501 报「运行中」。
    private static let codexRunTranscript: String = {
        let e = "\u{1B}["
        return [
            "\(e)1m>_ Codex\(e)0m  \(e)2m(resumed · ~/shop-api)\(e)0m",
            "",
            "\(e)36m›\(e)0m " + text("给订单服务补上集成测试：下单、取消、退款各两条。",
                                        en: "Add integration tests for orders: two each for create, cancel and refund.",
                                        hant: "給訂單服務補上整合測試：下單、取消、退款各兩條。",
                                        ja: "注文サービスに結合テストを追加：作成・取消・返金を 2 件ずつ。",
                                        ko: "주문 서비스에 통합 테스트 추가: 생성, 취소, 환불 각각 두 개."),
            "",
            "\(e)32m•\(e)0m Ran \(e)1mgo test ./internal/order/...\(e)0m",
            "  \(e)2m└ ok   shop-api/internal/order  1.42s\(e)0m",
            "",
            "\(e)33m•\(e)0m Working (12s • esc to interrupt)",
        ].joined(separator: "\r\n") + "\u{1B}]7501;state=working:app=codex\u{1B}\\"
    }()

    /// 一个小网站项目的目录（文件页用）。
    private static func siteFileSystem() -> DemoFileSystem {
        let fs = DemoFileSystem(seed: false)
        let day: TimeInterval = 86_400
        try? fs.mkdir("/srv/www/shop/public/assets", parents: true, now: now - 2 * day)
        try? fs.mkdir("/srv/www/shop/src/routes", parents: true, now: now - day)
        try? fs.mkdir("/srv/www/shop/logs", parents: true, now: now - 600)
        try? fs.mkdir("/srv/www/shop/.github/workflows", parents: true, now: now - 9 * day)
        let files: [(String, Int, TimeInterval)] = [
            ("package.json", 1_284, day), ("package-lock.json", 214_903, day), ("README.md", 3_120, 4 * day),
            ("docker-compose.yml", 842, 6 * day), ("Dockerfile", 512, 6 * day), (".env.example", 368, 9 * day),
            ("deploy.sh", 1_045, 2 * day), ("nginx.conf", 2_210, 12 * day), ("tsconfig.json", 611, 20 * day),
        ]
        for (name, size, age) in files {
            try? fs.write("/srv/www/shop/\(name)", data: Data(count: size), now: now - age)
        }
        try? fs.chmod("/srv/www/shop/deploy.sh", mode: 0o755)
        return fs
    }

    /// 真的 Claude Code（录制见 `Support/Recordings/`），106×35 正好是 Duo 横握时终端的行列数。
    private static let claudeTranscript: String = {
        let prompt = p10k(dir: "/srv/www/shop", branch: "main")
        guard let url = Bundle(for: AppStoreScreenshotTests.self).url(forResource: "claude-code-106x35", withExtension: "raw"),
              let data = try? Data(contentsOf: url) else { return prompt + "缺录制文件 claude-code-106x35.raw\r\n" }
        return prompt + "claude\r\n" + String(decoding: data, as: UTF8.self)
    }()

    /// zsh + powerlevel10k 的提示符，照维护者自己的 `~/.p10k.zsh`（向导选项 compatible / classic / light / blurred tails /
    /// 1 line / compact / concise；左边 dir、vcs）用真的 p10k 跑出来的字节写：深灰底、两头 ░▒▓ 渐隐、目录首尾两级加粗、
    /// `|` 之后是分支。右边的 ✔ 不画：写好的输出改尺寸时不会像真 zsh 那样重画右提示符，窄屏上会折行。
    nonisolated static func p10k(dir: String, branch: String?) -> String {
        let e = "\u{1B}["
        // "/srv/www/shop" → 根下的 srv、www、shop；"~/code/shop" → ~、code、shop。首尾两级是锚点（加粗、亮蓝）。
        let parts = dir.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let names = parts.first == "" ? Array(parts.dropFirst()) : parts
        var line = "\(e)0m\(e)38;5;238m░▒▓\(e)48;5;238m\(e)38;5;31m " + (parts.first == "" ? "/" : "")
        for (index, name) in names.enumerated() {
            if index > 0 { line += "\(e)38;5;31m/" }
            line += index == 0 || index == names.count - 1 ? "\(e)1m\(e)38;5;39m\(name)\(e)22m" : "\(e)38;5;31m\(name)"
        }
        line += "\(e)38;5;31m "
        if let branch { line += "\(e)38;5;246m|\(e)38;5;76m \(branch) " }
        return line + "\(e)0m\(e)38;5;238m▓▒░\(e)0m "
    }

    nonisolated private static func macPrompt(_ dir: String, branch: String = "main") -> String {
        p10k(dir: dir, branch: branch)
    }

    /// Mac 上跑着的开发服务器。
    private static let macDevTranscript: String = {
        let e = "\u{1B}["
        return [
            macPrompt("~/code/shop") + "npm run dev",
            "",
            "> shop@2.14.0 dev",
            "> vite",
            "",
            "  \(e)1;32mVITE\(e)0m v6.2.0  ready in \(e)1m412\(e)0m ms",
            "",
            "  \(e)32m➜\(e)0m  \(e)1mLocal\(e)0m:   \(e)36mhttp://localhost:5173/\(e)0m",
            "  \(e)32m➜\(e)0m  \(e)1mNetwork\(e)0m: use --host to expose",
            "",
            "\(e)2m21:31:07\(e)0m \(e)36m[vite]\(e)0m \(e)32mhmr update\(e)0m \(e)2m/src/routes/cart.tsx\(e)0m",
            "\(e)2m21:31:42\(e)0m \(e)36m[vite]\(e)0m \(e)32mhmr update\(e)0m \(e)2m/src/routes/orders.tsx\(e)0m",
            "\(e)2m21:32:15\(e)0m \(e)36m[vite]\(e)0m \(e)32mhmr update\(e)0m \(e)2m/src/styles.css\(e)0m",
            "\(e)2m21:33:02\(e)0m \(e)36m[vite]\(e)0m \(e)32mpage reload\(e)0m \(e)2msrc/main.tsx\(e)0m",
        ].joined(separator: "\r\n")
    }()

    /// Mac 上另一个终端：跑测试。
    private static let macTestTranscript: String = {
        let e = "\u{1B}["
        return [
            macPrompt("~/code/shop", branch: "main ⇡2") + "git status -sb",
            "## main...origin/main [ahead 2]",
            " \(e)31mM\(e)0m src/routes/orders.tsx",
            " \(e)31mM\(e)0m src/styles.css",
            macPrompt("~/code/shop", branch: "main ⇡2") + "npm test",
            "",
            " \(e)32m✓\(e)0m src/cart.test.ts \(e)2m(12 tests)\(e)0m 38ms",
            " \(e)32m✓\(e)0m src/orders.test.ts \(e)2m(9 tests)\(e)0m 51ms",
            " \(e)32m✓\(e)0m src/invoice.test.ts \(e)2m(14 tests)\(e)0m 64ms",
            " \(e)32m✓\(e)0m src/auth.test.ts \(e)2m(6 tests)\(e)0m 22ms",
            "",
            " \(e)2mTest Files\(e)0m  \(e)1;32m4 passed\(e)0m (4)",
            " \(e)2m     Tests\(e)0m  \(e)1;32m41 passed\(e)0m (41)",
            " \(e)2m  Duration\(e)0m  1.21s",
            macPrompt("~/code/shop", branch: "main ⇡2"),
        ].joined(separator: "\r\n")
    }()

    private static let terminalTranscript: String = {
        let e = "\u{1B}["
        let prompt = p10k(dir: "/srv/www/shop", branch: "main")
        return [
            prompt + "systemctl status nginx",
            "\(e)1;32m●\(e)0m nginx.service - nginx web server",
            "     Loaded: loaded (enabled)",
            "     Active: \(e)1;32mactive (running)\(e)0m since 09:12",
            "   Main PID: 1042 (nginx)",
            "     Memory: 12.4M",
            prompt + "df -h /",
            "Filesystem  Size  Used Avail Use% Mounted on",
            "/dev/vda1    40G   12G   27G  31% /",
            prompt + "git log --oneline -5",
            "\(e)33ma1c3e9f\(e)0m fix: retry upstream on 502",
            "\(e)33m7d02b41\(e)0m feat: order export to CSV",
            "\(e)33m3f9a6c0\(e)0m chore: bump node to 22",
            "\(e)33me51b7d2\(e)0m perf: cache product list",
            "\(e)33m0c8d9aa\(e)0m fix: timezone in invoices",
            prompt + "tail -n 6 /var/log/nginx/access.log",
            "10.0.1.5 GET /api/products 200 12ms",
            "10.0.1.7 POST /api/orders \(e)32m201\(e)0m 41ms",
            "10.0.1.5 GET /healthz 200 1ms",
            "10.0.1.9 GET /api/products?page=2 200 15ms",
            "10.0.1.5 GET /api/user \(e)33m401\(e)0m 3ms",
            "10.0.1.9 POST /api/orders \(e)32m201\(e)0m 38ms",
            prompt + "free -h",
            "       total   used   free  shared  cache",
            "Mem:   3.8Gi  1.2Gi  1.1Gi   12Mi  1.5Gi",
            prompt + "ls",
            "\(e)1;34mlogs\(e)0m  \(e)1;34mpublic\(e)0m  \(e)1;34msrc\(e)0m  Dockerfile  README.md",
            "docker-compose.yml  \(e)1;32mdeploy.sh\(e)0m  nginx.conf",
            prompt,
        ].joined(separator: "\r\n")
    }()
}

/// 并行执行的假执行器：每台整段返回一份写好的输出（同真 SSH：不按节拍回吐）。
private struct ScriptedParallelExecutor: ParallelCommandExecuting {
    func makeSession(for profile: ServerProfile, approving pin: HostKeyApprovalPin?) async -> ParallelExecutionSession {
        ScriptedParallelSession(host: profile.name)
    }
}

private struct ScriptedParallelSession: ParallelExecutionSession {
    let host: String
    var setupErrorText: String? { nil }

    func run(_ command: String,
             onLines: @escaping @Sendable ([ParallelTermLine]) -> Void) async throws -> CommandResult {
        try await Task.sleep(for: .milliseconds(Int.random(in: 150...600)))
        let ms = Int.random(in: 2...9)
        return CommandResult(output: "active\n{\"status\":\"ok\",\"host\":\"\(host)\",\"uptime\":\"3s\",\"db\":\"ok\",\"latency_ms\":\(ms)}",
                             exitCode: 0)
    }

    func takeHostKeyChallenge() -> HostKeyChallenge? { nil }
    func close() async {}
}

/// 连上就吐一段写好的输出，之后不动（截图用）。
private actor TranscriptBackend: TerminalBackend {
    nonisolated let outputItems: AsyncStream<TerminalOutputItem>
    nonisolated let exitStream: AsyncStream<Void>
    private let output: TerminalByteOutput
    private let text: String

    init(text: String) {
        let output = TerminalByteOutput()
        self.output = output
        self.text = text
        outputItems = output.items
        exitStream = AsyncStream { _ in }
    }

    func connect() async throws { output.send(Data(text.utf8)) }
    func write(_ data: Data) async {}
    func resize(cols: UInt16, rows: UInt16) async {}
    func close() async { output.finish() }
    func foregroundActivity() async -> TerminalActivity { .idle }
}

/// 商店截图用的托管控制器：请系统藏起 Home 指示条。
private final class ScreenshotHostingController: UIHostingController<AnyView> {
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}
