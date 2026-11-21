import SwiftData
import SwiftUI
import XCTest
@testable import uTermMobile

/// App Store 截图：真页面 + 干净的示例数据（保留网段与 example 域名），整屏连状态栏由外面的 `simctl io screenshot` 拍。
///
/// 测试把一屏摆到最上层后写 `<目录>/ready-<名字>`，等外面拍完写回 `<目录>/done-<名字>`（最多 60 秒）。
/// 外面的脚本见 `scripts/appstore-screenshots.sh`：在 6.9 英寸 iPhone（1320×2868）与 13 英寸 iPad（2064×2752）
/// 模拟器上各跑一遍。开关 `UTERM_APPSTORE_SHOTS_DIR`，不设就跳过。
@MainActor
final class AppStoreScreenshotTests: XCTestCase {
    private var dir: URL!
    private static let now = Date()

    override func setUp() async throws {
        try await super.setUp()
        guard let path = ProcessInfo.processInfo.environment["UTERM_APPSTORE_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("未设置 UTERM_APPSTORE_SHOTS_DIR：App Store 截图只按需跑")
        }
        dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func testScreens() async throws {
        defer { MobileProbeWindow.closeAll() }
        let (container, hosts) = try fixtures()
        let relay = HostKeyChallengeRelay()
        let style: UIUserInterfaceStyle = ProcessInfo.processInfo.environment["UTERM_APPSTORE_DARK"] == "1" ? .dark : .light

        // 1. 主机列表（顶上是体验主机）
        try await present("1-hosts", style: style) {
            HostsScreen().environment(store(tab: .hosts)).modelContainer(container)
        }

        // 2. 终端
        let web = try XCTUnwrap(hosts["prod-web-01"])
        let term = TermTab(host: web, transportFactory: MobileTerminalTransportFactory { _ in
            TranscriptBackend(text: Self.terminalTranscript)
        })
        term.controller.start(profile: web, container: container, relay: relay)
        let terminalWorkspace = MobileWorkspace()
        terminalWorkspace.open(.terminal(term))
        try await present("2-terminal", style: style, settle: .seconds(2)) {
            WorkspaceScreen().environment(workspaceStore()).environment(relay)
                .environment(terminalWorkspace).modelContainer(container)
        }

        // 3. 文件
        let files = FileTab(host: web, controller: MobileSFTPController(
            testProvider: DemoSFTPProvider(fileSystem: Self.siteFileSystem()), startPath: "/srv/www/shop"))
        await files.controller.load("/srv/www/shop")
        let filesWorkspace = MobileWorkspace()
        filesWorkspace.open(.files(files))
        try await present("3-files", style: style) {
            WorkspaceScreen().environment(workspaceStore()).environment(relay)
                .environment(filesWorkspace).modelContainer(container)
        }

        // 4. 分屏：终端 + 文件
        let split = MobileWorkspace()
        let term2 = TermTab(host: web, transportFactory: MobileTerminalTransportFactory { _ in
            TranscriptBackend(text: Self.terminalTranscript)
        })
        term2.controller.start(profile: web, container: container, relay: relay)
        split.open(.terminal(term2))
        let files2 = FileTab(host: web, controller: MobileSFTPController(
            testProvider: DemoSFTPProvider(fileSystem: Self.siteFileSystem()), startPath: "/srv/www/shop"))
        await files2.controller.load("/srv/www/shop")
        split.open(.files(files2))
        split.moveToOtherPane(files2.id)
        try await present("4-split", style: style, settle: .seconds(2)) {
            WorkspaceScreen().environment(workspaceStore()).environment(relay)
                .environment(split).modelContainer(container)
        }

        // 5. 并行执行（写好的输出，像真的 SSH 一样整段返回）
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
        try await present("5-parallel", style: style, settle: .seconds(2)) {
            ParallelRunView(request: request, controller: controller, onClose: {})
                .environment(store(tab: .commands)).modelContainer(container)
        }
        controller.cancel()
        for tab in [term, term2] { tab.controller.close() }
    }

    // MARK: - 摆一屏，等外面拍

    private func present<V: View>(_ name: String, style: UIUserInterfaceStyle,
                                  settle: Duration = .milliseconds(800), _ view: () -> V) async throws {
        let root = view().environment(\.mAccent, M.accent).tint(M.accent)
        let (window, host) = MobileProbeWindow.make(placement: .visibleOnScreen, rootView: root)
        host.safeAreaRegions = .all          // 真机一样让开状态栏与底部横条
        window.overrideUserInterfaceStyle = style
        host.view.backgroundColor = style == .dark ? .black : .white
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: settle)
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
        MobileProbeWindow.close(window)
    }

    private func store(tab: MTab) -> MobileStore {
        let s = MobileStore()
        s.tab = tab
        return s
    }

    private func workspaceStore() -> MobileStore {
        let s = MobileStore()
        s.showWorkspace = true
        return s
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
