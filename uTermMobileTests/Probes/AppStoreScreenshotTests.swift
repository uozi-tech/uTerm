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
            let front = terminal(web, device == .duo ? Self.claudeTranscript : Self.terminalTranscript)
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

        // 远程桌面：整块屏幕只在 Duo 横握拍（竖屏里 Mac 的横屏画面只剩中间一条）；Duo 与 iPad 再拍窗口模式
        // （iPhone 竖握比 Mac 终端窗口的最小宽度还窄）。
        // Mac 把窗口调成手机画布的大小：Duo 横握 951×669 点、13 英寸 iPad 竖握 1032×1376 点（同 Mac 画廊里那两张图）。
        let canvas = device == .duo ? CGSize(width: 951, height: 669) : CGSize(width: 1032, height: 1376)
        if device == .duo {
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
            let frame = try Self.macFrame(device == .duo ? "终端窗口__手机窗口模式" : "终端窗口__iPad_窗口模式", dark: dark)
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
                commandID: commandID, commandName: "重启服务并检查", command: command, intent: "", aiAssisted: false,
                targets: targets, doctor: nil, store: QuickCommandStore(context: container.mainContext),
                container: container, executor: ScriptedParallelExecutor())
            let request = ParallelRunRequest(commandID: commandID, name: "重启服务并检查", command: command,
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

        // 主机：顶上是体验主机，下面是「我的 Mac」与分组。
        do {
            let store = MobileStore()
            store.tab = .hosts
            try await present("8-hosts", before: { directory.setDiscovered(macsOnline) }) {
                shell(store, MobileWorkspace())
            }
        }
    }

    // MARK: - 摆一屏，等外面拍

    /// 整屏挂在宿主 App 的主窗口上（临时换掉它的根控制器，拍完换回），排好后请外面截屏。
    private func present<V: View>(_ name: String, settle: Duration = .milliseconds(900),
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
        let deadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
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
        for (i, (name, color)) in [("生产", "#ef4444"), ("测试", "#3b82f6"), ("家里", "#a855f7")].enumerated() {
            ctx.insert(ServerGroup(name: name, colorHex: color, isPinned: i == 0, sortOrder: i))
        }
        let key = SSHKey()
        key.name = "iphone-2026"
        key.typeRaw = SSHKeyKind.ed25519.rawValue
        key.bits = 256
        key.fingerprint = "SHA256:Qm4bXo2Lk3T0w8V1sN7cHf9eRZy6aJd5uPq2gKtW4E"
        ctx.insert(key)
        let rows: [(String, String, String, String, Double?)] = [
            ("bastion", "203.0.113.10", "ops", "生产", -3_600),
            ("prod-web-01", "10.0.1.11", "deploy", "生产", -180),
            ("prod-web-02", "10.0.1.12", "deploy", "生产", -7_200),
            ("prod-db", "10.0.2.21", "postgres", "生产", -86_400),
            ("staging", "staging.example.com", "deploy", "测试", -1_800),
            ("k3s-lab", "192.168.10.30", "ubuntu", "测试", -86_400 * 3),
            ("nas", "192.168.1.5", "admin", "家里", -86_400 * 9),
            ("raspberry-pi", "192.168.1.42", "pi", "家里", nil),
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
        for (i, (name, command)) in [("重启服务并看日志", "systemctl restart app && journalctl -u app -n 40"),
                                     ("磁盘占用", "df -h /"), ("清理 Docker", "docker system prune -f")].enumerated() {
            let q = QuickCommand()
            q.name = name
            q.command = command
            q.serverIDs = Array(hosts.values.prefix(4 - i)).map(\.id)
            ctx.insert(q)
        }
        try ctx.save()
        return (c, hosts)
    }

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
        let e = "\u{1B}["
        let prompt = "\(e)1;32mdeploy@prod-web-01\(e)0m:\(e)1;34m~\(e)0m$ "
        guard let url = Bundle(for: AppStoreScreenshotTests.self).url(forResource: "claude-code-106x35", withExtension: "raw"),
              let data = try? Data(contentsOf: url) else { return prompt + "缺录制文件 claude-code-106x35.raw\r\n" }
        return prompt + "claude\r\n" + String(decoding: data, as: UTF8.self)
    }()

    private static func macPrompt(_ dir: String) -> String {
        "\u{1B}[1;36mdev@MacBook-Pro\u{1B}[0m \u{1B}[1;34m\(dir)\u{1B}[0m % "
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
            macPrompt("~/code/shop") + "git status -sb",
            "## main...origin/main [ahead 2]",
            " \(e)31mM\(e)0m src/routes/orders.tsx",
            " \(e)31mM\(e)0m src/styles.css",
            macPrompt("~/code/shop") + "npm test",
            "",
            " \(e)32m✓\(e)0m src/cart.test.ts \(e)2m(12 tests)\(e)0m 38ms",
            " \(e)32m✓\(e)0m src/orders.test.ts \(e)2m(9 tests)\(e)0m 51ms",
            " \(e)32m✓\(e)0m src/invoice.test.ts \(e)2m(14 tests)\(e)0m 64ms",
            " \(e)32m✓\(e)0m src/auth.test.ts \(e)2m(6 tests)\(e)0m 22ms",
            "",
            " \(e)2mTest Files\(e)0m  \(e)1;32m4 passed\(e)0m (4)",
            " \(e)2m     Tests\(e)0m  \(e)1;32m41 passed\(e)0m (41)",
            " \(e)2m  Duration\(e)0m  1.21s",
            macPrompt("~/code/shop"),
        ].joined(separator: "\r\n")
    }()

    private static let terminalTranscript: String = {
        let e = "\u{1B}["
        let prompt = "\(e)1;32mdeploy@prod-web-01\(e)0m:\(e)1;34m~\(e)0m$ "
        return [
            prompt + "systemctl status nginx",
            "\(e)1;32m●\(e)0m nginx.service - nginx web server",
            "     Loaded: loaded (enabled)",
            "     Active: \(e)1;32mactive (running)\(e)0m since 09:12",
            "   Main PID: 1042 (nginx)",
            "      Tasks: 5 (limit: 4557)",
            "     Memory: 12.4M",
            prompt + "df -h /",
            "Filesystem  Size  Used Avail Use% Mounted on",
            "/dev/vda1    40G   12G   27G  31% /",
            prompt + "git -C /srv/www/shop log --oneline -5",
            "\(e)33ma1c3e9f\(e)0m fix: retry upstream on 502",
            "\(e)33m7d02b41\(e)0m feat: order export to CSV",
            "\(e)33m3f9a6c0\(e)0m chore: bump node to 22",
            "\(e)33me51b7d2\(e)0m perf: cache product list",
            "\(e)33m0c8d9aa\(e)0m fix: timezone in invoices",
            prompt + "tail -n 8 /var/log/nginx/access.log",
            "10.0.1.5 GET /api/products 200 12ms",
            "10.0.1.5 GET /api/cart 200 8ms",
            "10.0.1.7 POST /api/orders \(e)32m201\(e)0m 41ms",
            "10.0.1.5 GET /healthz 200 1ms",
            "10.0.1.9 GET /api/products?page=2 200 15ms",
            "10.0.1.7 GET /static/app.js 304 2ms",
            "10.0.1.5 GET /api/user \(e)33m401\(e)0m 3ms",
            "10.0.1.9 POST /api/orders \(e)32m201\(e)0m 38ms",
            prompt + "free -h",
            "       total   used   free  shared  cache",
            "Mem:   3.8Gi  1.2Gi  1.1Gi   12Mi  1.5Gi",
            "Swap:     0B     0B     0B",
            prompt + "ls /srv/www/shop",
            "\(e)1;34mlogs\(e)0m  \(e)1;34mpublic\(e)0m  \(e)1;34msrc\(e)0m  Dockerfile  README.md",
            "docker-compose.yml  \(e)1;32mdeploy.sh\(e)0m  nginx.conf",
            prompt,
        ].joined(separator: "\r\n")
    }()
}

/// 并行执行的假执行器：每台整段返回一份写好的输出（同真 SSH：不按节拍回吐）。
private struct ScriptedParallelExecutor: ParallelCommandExecuting {
    func makeSession(for profile: ServerProfile, trustNewKeys: Bool) async -> ParallelExecutionSession {
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
