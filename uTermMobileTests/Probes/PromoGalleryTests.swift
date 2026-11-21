import CoreVideo
import Network
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 宣传用的 iOS 截图：真视图、干净的夹具（几台常见名字的主机、真的 Claude Code 录制）。
///
/// `StyleGalleryTests` 的夹具是压力数据（超长名字、探针文案），用来核排版；这里只出能放到官网上的几屏。
/// 和样式画廊同一个开关：`UTERM_STYLE_SHOTS_DIR`（不设就跳过），文件名前缀 `promo-`。
@MainActor
final class PromoGalleryTests: XCTestCase {

    private struct Device {
        let name: String
        let size: CGSize
        let hSize: UserInterfaceSizeClass
    }

    private static let devices: [Device] = [
        // iPhone Duo 展开、横握：常规宽度，大标题与工具栏按钮同行（`.inlineLarge`），和真机一致。
        Device(name: "duo-landscape", size: CGSize(width: 951, height: 669), hSize: .regular),
    ]

    private static let now = Date(timeIntervalSince1970: 1_795_180_000)

    private var outputDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        guard let dir = ProcessInfo.processInfo.environment["UTERM_STYLE_SHOTS_DIR"], !dir.isEmpty else {
            throw XCTSkip("未设置 UTERM_STYLE_SHOTS_DIR：官网截图只按需跑")
        }
        outputDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    // MARK: - 截图（同 StyleGalleryTests.shoot）

    private func shoot<V: View>(_ name: String, on device: Device, settle: Duration = .milliseconds(400),
                                _ view: () -> V) async throws {
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
            let png = UIGraphicsImageRenderer(bounds: host.view.bounds).pngData { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            try png.write(to: outputDir.appendingPathComponent(
                "promo-\(name)-\(device.name)-\(style == .dark ? "dark" : "light").png"))
            MobileProbeWindow.close(window)
        }
    }

    /// 只拍一种外观；`before` 在视图挂上、排完版之后调（画布要先接上，才能往里送画面）。
    private func shootOnce<V: View>(_ name: String, on device: Device, dark: Bool, settle: Duration,
                                    before: () -> Void, _ view: () -> V) async throws {
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        let root = view()
            .environment(\.horizontalSizeClass, device.hSize)
            .environment(\.mAccent, M.accent)
            .tint(M.accent)
            .frame(width: device.size.width, height: device.size.height)
        let (window, host) = MobileProbeWindow.make(size: device.size, rootView: root)
        window.overrideUserInterfaceStyle = style
        host.view.backgroundColor = dark ? .black : .white
        host.view.layoutIfNeeded()
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(500))
        before()
        try await Task.sleep(for: settle)
        host.view.layoutIfNeeded()
        CATransaction.flush()
        let png = UIGraphicsImageRenderer(bounds: host.view.bounds).pngData { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        try png.write(to: outputDir.appendingPathComponent("promo-\(name)-\(device.name)-\(dark ? "dark" : "light").png"))
        MobileProbeWindow.close(window)
    }

    // MARK: - 夹具

    /// 与 Mac 画廊（`UICatalogFixtures`）同一套主机：保留网段与 example 域名。
    private func container() throws -> (ModelContainer, [String: ServerProfile]) {
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
        key.createdAt = Self.now.addingTimeInterval(-86_400 * 120)
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
        try ctx.save()
        return (c, hosts)
    }

    /// 终端里跑着真的 Claude Code：录好的输出字节（`Support/Recordings/claude-code-106x35.raw`，录法见 Mac 画廊的
    /// `Recordings/README.md`）。Claude Code 按录制时的 106×35 排版，正好是 Duo 横握时终端的行列数。
    private static let transcript: String = {
        let e = "\u{1B}["
        let prompt = "\(e)1;32mdeploy@prod-web-01\(e)0m:\(e)1;34m~\(e)0m$ "
        guard let url = Bundle(for: PromoGalleryTests.self).url(forResource: "claude-code-106x35", withExtension: "raw"),
              let data = try? Data(contentsOf: url) else { return prompt + "缺录制文件 claude-code-106x35.raw\r\n" }
        return prompt + "claude\r\n" + String(decoding: data, as: UTF8.self)
    }()

    /// 「我的 Mac」：两台配对过的 Mac，名字中性，标成在局域网里找得到（`setDiscovered` 是给测试用的入口）。
    /// 已激活：列表才显示。挂上后区块会开 Bonjour 搜索、结果会盖掉这里设的在线状态，所以拍之前再设一次
    /// （真找到的 Mac 不会进画面：「我的 Mac」只列信任过的，「附近的 Mac」只列同一 iCloud 账户的，测试宿主读不到真名册）。
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

    /// Mac 画廊（`make gallery`）渲的那个手机尺寸的终端窗口，当成窗口模式下 Mac 送来的画面。
    private static func macWindowFrame(dark: Bool, name: String = "终端窗口__手机窗口模式") throws -> CVPixelBuffer {
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
        // 窗口圆角外面是透明的：垫黑底（远程桌面的画布本来就是黑底）。
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private func store(tab: MTab, workspace: Bool = false) -> MobileStore {
        let s = MobileStore()
        s.tab = tab
        s.showWorkspace = workspace
        return s
    }

    // MARK: - 屏

    func testPromoScreens() async throws {
        defer { MobileProbeWindow.closeAll() }
        let (c, hosts) = try container()
        let relay = HostKeyChallengeRelay()

        let suite = "PromoGalleryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (directory, macsOnline) = try macDirectory(defaults)

        for device in Self.devices {
            for dark in [false, true] {
                try await shootOnce("hosts", on: device, dark: dark, settle: .milliseconds(500),
                                    before: { directory.setDiscovered(macsOnline) }) {
                    HostsScreen()
                        .environment(store(tab: .hosts))
                        .environment(directory)
                        .modelContainer(c)
                }
            }

            // 远程桌面的窗口模式：真的 RemoteDesktopScreen，画面是 Mac 画廊渲的那个终端窗口（经画布的显示管线上屏）。
            for dark in [false, true] {
                let client = RemoteMacClient(macName: "MacBook Pro", endpoint: .hostPort(host: "127.0.0.1", port: 9),
                                             identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
                let session = RemoteDesktopSession(client: client, maxWidth: 2853, maxHeight: 2007)
                let frame = try Self.macWindowFrame(dark: dark)
                try await shootOnce("remote-window", on: device, dark: dark, settle: .milliseconds(1_200), before: {
                    session.showGalleryWindow(frame, windowID: 1, title: "prod-web-01",
                                              pointSize: CGSize(width: 951, height: 669))
                }) {
                    RemoteDesktopScreen(client: client, started: session, initialWindow: 1, onClose: {})
                        .environment(store(tab: .hosts))
                }
                session.stop()
            }

            let host = try XCTUnwrap(hosts["prod-web-01"])
            let sessions = MobileWorkspace()
            let (tab, _) = MobileFakeTerminal.tab(host: host, .transcript(Self.transcript))
            tab.controller.start(profile: host, container: c, relay: relay)
            sessions.open(.terminal(tab))
            if let first = sessions.tabs.first { sessions.activate(first.id) }
            await MobileFakeTerminal.waitUntilConnected(tab.controller)
            try await shoot("terminal", on: device, settle: .milliseconds(1_400)) {
                WorkspaceScreen()
                    .environment(store(tab: .hosts, workspace: true))
                    .environment(relay)
                    .environment(sessions)
                    .modelContainer(c)
            }
            tab.controller.close()
        }
    }

    // MARK: - 真设备形态（iPhone Duo 模拟器整屏截图）

    /// 在 iPhone Duo 模拟器（展开、横握）里整屏挂真的外壳（`MobileTabShell` + `WorkspaceLayer`，同 `MobileRootView`），
    /// 系统照真机排状态栏那一列、安全区和工具栏位置；屏幕由宿主那边的脚本用 `simctl io screenshot --mask alpha` 截
    /// （带状态栏和屏幕圆角）。每一屏摆好后写 `<文件名>.ready`，等脚本把 `<文件名>` 截出来再往下走。
    /// 开关：`UTERM_PROMO_DEVICE_SHOTS`（目录）；截图脚本在维护者私有仓库（`internal/website/scripts/shoot-duo.sh`）。
    func testPromoScreensOnDevice() async throws {
        guard let dir = ProcessInfo.processInfo.environment["UTERM_PROMO_DEVICE_SHOTS"], !dir.isEmpty else {
            throw XCTSkip("未设置 UTERM_PROMO_DEVICE_SHOTS：只在 Duo 模拟器上配合截图脚本跑")
        }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (c, hosts) = try container()
        let relay = HostKeyChallengeRelay()
        let suite = "PromoGalleryTests.device.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (directory, macsOnline) = try macDirectory(defaults)
        let lan = LANSyncCoordinator(role: .receiver, preferences: SharedPreferencesSync(),
                                     dataStore: LANSyncDataStore(container: c))
        let host = try XCTUnwrap(hosts["prod-web-01"])

        for dark in [false, true] {
            // 主机页（带「我的 Mac」）与终端：同一个外壳，终端是展开的工作区。
            let workspace = MobileWorkspace()
            let (tab, handles) = MobileFakeTerminal.tab(host: host, .transcript(Self.transcript))
            tab.controller.start(profile: host, container: c, relay: relay)
            workspace.open(.terminal(tab))
            if let first = workspace.tabs.first { workspace.activate(first.id) }
            await MobileFakeTerminal.waitUntilConnected(tab.controller)
            let store = MobileStore()
            store.tab = .hosts
            let shell = {
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
                .environment(CloudKitSyncMonitor())
                .modelContainer(c)
            }
            try await shootDevice("hosts", dark: dark, into: out, before: { directory.setDiscovered(macsOnline) }, shell)
            store.showWorkspace = true
            try await shootDevice("terminal", dark: dark, into: out, settle: .milliseconds(1_600), shell)
            if let transport = handles.issued.last { let ledger = await transport.ledger
                print("[promo] term-size \(ledger.lastCols ?? 0)x\(ledger.lastRows ?? 0)")
            }
            tab.controller.close()

            // 远程桌面的窗口模式：App 里是全屏单独呈现的。
            let client = RemoteMacClient(macName: "MacBook Pro", endpoint: .hostPort(host: "127.0.0.1", port: 9),
                                         identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
            let session = RemoteDesktopSession(client: client, maxWidth: 2853, maxHeight: 2007)
            let frame = try Self.macWindowFrame(dark: dark)
            try await shootDevice("remote-window", dark: dark, into: out, settle: .milliseconds(1_200), before: {
                session.showGalleryWindow(frame, windowID: 1, title: "prod-web-01",
                                          pointSize: CGSize(width: 951, height: 669))
            }) {
                RemoteDesktopScreen(client: client, started: session, initialWindow: 1, onClose: {})
            }
            session.stop()

            // 远程桌面看整块屏幕：画面是合成的 Mac 桌面（`internal/website/scripts/compose-mac-desktop.swift`：
            // 渐变壁纸 + 菜单栏 + Mac 画廊渲的真 uTerm 窗口 + Dock）。
            let desktopClient = RemoteMacClient(macName: "MacBook Pro", endpoint: .hostPort(host: "127.0.0.1", port: 9),
                                                identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
            let desktopSession = RemoteDesktopSession(client: desktopClient, maxWidth: 3024, maxHeight: 1964)
            let desktop = try Self.macWindowFrame(dark: dark, name: "桌面__远程桌面")
            try await shootDevice("remote-desktop", dark: dark, into: out, settle: .milliseconds(1_200), before: {
                desktopSession.showGalleryWindow(desktop, windowID: nil, title: nil,
                                                 pointSize: CGSize(width: 1512, height: 982))
            }) {
                RemoteDesktopScreen(client: desktopClient, started: desktopSession, onClose: {})
            }
            desktopSession.stop()
        }
    }

    /// 整屏挂一个视图（盖在宿主 App 的窗口上面），排好后请宿主脚本截屏。
    private func shootDevice<V: View>(_ name: String, dark: Bool, into dir: URL, settle: Duration = .milliseconds(900),
                                      before: () -> Void = {}, _ view: () -> V) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // 挂在宿主 App 自己的主窗口上（临时换掉它的根控制器，拍完换回）：Home 指示条藏不藏，系统只问主窗口。
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow } ?? scene.windows.first)
        let original = window.rootViewController
        let originalStyle = window.overrideUserInterfaceStyle
        defer {
            window.rootViewController = original
            window.overrideUserInterfaceStyle = originalStyle
        }
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let host = PromoHostingController(rootView: AnyView(view()
            .environment(\.mAccent, M.accent)
            .tint(M.accent)
            .mMeasuresChrome()
            .persistentSystemOverlays(.hidden)))
        window.rootViewController = host
        host.setNeedsUpdateOfHomeIndicatorAutoHidden()
        try await Task.sleep(for: .milliseconds(600))
        before()
        try await Task.sleep(for: settle)
        // 终端挂上会拿焦点、弹出软键盘，宣传图里收起来（键盘条照常显示）。
        window.endEditing(true)
        try await Task.sleep(for: .milliseconds(700))
        let file = "promo-\(name)-duo-device-\(dark ? "dark" : "light").png"
        let png = dir.appendingPathComponent(file)
        try? FileManager.default.removeItem(at: png)
        let marker = dir.appendingPathComponent(file + ".ready")
        try Data().write(to: marker)
        let deadline = ContinuousClock.now + .seconds(60)
        while !FileManager.default.fileExists(atPath: png.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(150))
        }
        try? FileManager.default.removeItem(at: marker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), "截图脚本没截到 \(file)")
    }
}

/// 宣传截图用的托管控制器：请系统藏起 Home 指示条（SwiftUI 的 persistentSystemOverlays 在这个单独的窗口里不生效）。
private final class PromoHostingController: UIHostingController<AnyView> {
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}
