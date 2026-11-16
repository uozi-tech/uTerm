import AppKit
import CryptoKit
import SwiftData
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 把 macOS 设置窗的每个分区（以及已知主机指纹窗口、同步诊断弹窗）渲染成 PNG，给人眼验收排版。
///
/// **不进常规全量**：只有设置了 `UTERM_SETTINGS_SHOTS=<目录>` 才跑（经 xcodebuild 传给测试宿主要写成
/// `TEST_RUNNER_UTERM_SETTINGS_SHOTS`），否则 `XCTSkip`。这里不做任何断言 —— 判据是看图。
///
///     TEST_RUNNER_UTERM_SETTINGS_SHOTS=$PWD/build/shots/after xcodebuild test -project uTerm.xcodeproj \
///         -scheme uTerm -destination platform=macOS -derivedDataPath build/DerivedData \
///         -only-testing:uTermTests/SettingsPageSnapshotTests -enableCodeCoverage NO \
///         -disableAutomaticPackageResolution -skipPackageUpdates
///
/// 测试宿主在沙盒里，目标目录写不进时退回宿主自己的 tmp（`NSTemporaryDirectory()/settings-shots/<目录名>`），
/// 实际写到哪会打在日志里（`[settings-shots] dir=`）。macOS 27 上别的进程读不到宿主容器，所以每张图
/// 同时挂成 `XCTAttachment`：给 xcodebuild 加 `-resultBundlePath`，再用
/// `xcrun xcresulttool export attachments --path <xcresult> --output-path <目录>` 导出。
///
/// 隔离：`@AppStorage` 经 `.defaultAppStorage` 换成一次性的 suite（不读写正式版的设置）；
/// SwiftData 一律是 `isStoredInMemoryOnly + cloudKitDatabase: .none` 的内存容器；
/// 远控身份用 `RemoteMemoryStorage`，不碰钥匙串。
@MainActor
final class SettingsPageSnapshotTests: XCTestCase {

    private static let windowSize = NSSize(width: 940, height: 640)
    /// 长页面再拍一张高的，滚动区以下的内容也能看到。
    private static let tallSize = NSSize(width: 940, height: 1900)
    /// 设置窗的最小尺寸（`SettingsView` 的 minWidth / minHeight）。
    private static let minimumSize = NSSize(width: 880, height: 600)

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    // MARK: - 环境

    private struct Fixture {
        let defaults: UserDefaults
        let container: ModelContainer
        let updater: AppUpdater
        let lanSync: LANSyncCoordinator
        let cloudSync: CloudKitSyncMonitor
        let control: ControlSettings
        let background: BackgroundServiceSettings
        let remoteSettings: RemoteControlSettings
        let remoteServer: RemoteHostServer
        /// 「我的 Mac」用的目录。没配对过 Mac、不浏览。
        let remoteMacs: RemoteMacDirectory
        /// 「我的设备」的状态。nil = 没有远控身份（截图里不读真名册）。
        var deviceGroup: RemoteDeviceGroupService?
    }

    private struct Options {
        var providers = true
        var knownHosts = true
        var remoteEnabled = true
        var pairedDevices = true
        var pairingInvitation = false
    }

    private func makeFixture(_ options: Options) throws -> Fixture {
        let suite = "SettingsPageSnapshotTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: Schema(ModelRegistry.types), configurations: config)
        let context = container.mainContext
        if options.providers {
            let samples: [(String, ProviderKind, String)] = [
                ("Anthropic", .anthropic, "https://ai.example.com"),
                ("OpenAI", .openai, ProviderPreset.openAIBaseURL),
                ("DeepSeek", .openai, "https://api.deepseek.com"),
            ]
            for (index, sample) in samples.enumerated() {
                let provider = AIProvider(name: sample.0, kind: sample.1, baseURL: sample.2, model: "")
                provider.sortOrder = index
                context.insert(provider)
            }
        }
        if options.knownHosts {
            let hosts: [(String, Int, String, String)] = [
                ("10.0.1.24", 22, "ssh-ed25519", "SHA256:q3H8Pc0q1yUuR6m0uZx4p5wB2nK9vD7sL1aT0eF3gHk"),
                ("prod-api.example.com", 2222, "rsa-sha2-256", "SHA256:Zb4XyQ0mN8kR2tV6wH1cP9sD5fG3jL7aE0uI4oY2rTx"),
                ("build-mac.local", 22, "ecdsa-sha2-nistp256", "SHA256:Lm2Nq5Rs8Tv1Wx4Yz7Ab0Cd3Ef6Gh9Ij2Kl5Mn8Op1Q"),
            ]
            for (index, sample) in hosts.enumerated() {
                let host = KnownHost()
                host.host = sample.0
                host.port = sample.1
                host.keyTypeRaw = sample.2
                host.fingerprint = sample.3
                host.firstTrustedAt = Date(timeIntervalSince1970: 1_790_000_000 - Double(index) * 86_400 * 9)
                context.insert(host)
            }
            for name in ["生产", "测试"] {
                context.insert(ServerGroup(name: name))
            }
            for name in ["id_ed25519", "deploy", "github"] {
                let key = SSHKey()
                key.name = name
                context.insert(key)
            }
        }
        try context.save()

        let lanSync = LANSyncCoordinator(
            role: .sender,
            preferences: SharedPreferencesSync(defaults: defaults, store: SnapshotKeyValueStore()),
            dataStore: LANSyncDataStore(container: container),
            defaults: defaults)

        let remoteSettings = RemoteControlSettings(defaults: defaults)
        let identity = RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage())
        if options.pairedDevices {
            let peers: [(String, TimeInterval)] = [
                ("我的 iPhone", 1_789_000_000),
                ("工作室 iPad Pro", 1_786_500_000),
            ]
            for peer in peers {
                try identity.trust(RemotePeer(id: UUID(), name: peer.0,
                                              publicKey: Data(repeating: 7, count: 32),
                                              pairedAt: Date(timeIntervalSince1970: peer.1)))
            }
        }
        let remoteServer = RemoteHostServer(registry: TerminalSessionRegistry(), identity: identity,
                                            localName: "测试 Mac", localID: UUID(), advertises: false)
        if options.remoteEnabled {
            remoteSettings.isEnabled = true
            remoteSettings.isLocalShellEnabled = true
            remoteSettings.isDesktopEnabled = true
            // 有中继配置才画得出公网接入那一组；不打开「允许经公网接入」，免得真去连中继。
            remoteServer.relayConfig = RemoteRelayConfig(name: "relay-sz", host: "relay.example.invalid",
                                                         port: 47310, relayID: "snapshot",
                                                         key: Data(repeating: 1, count: 32).base64EncodedString())
        }
        if options.pairingInvitation {
            _ = try remoteServer.makePairingInvitation()
        }

        return Fixture(defaults: defaults, container: container, updater: AppUpdater(),
                       lanSync: lanSync, cloudSync: CloudKitSyncMonitor(),
                       control: ControlSettings(defaults: defaults),
                       background: BackgroundServiceSettings(defaults: defaults),
                       remoteSettings: remoteSettings, remoteServer: remoteServer,
                       remoteMacs: RemoteMacDirectory(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()),
                                                      adoptsRelayAsDefault: false))
    }

    private func environment<Content: View>(_ content: Content, _ fixture: Fixture, dark: Bool) -> some View {
        content
            .modelContainer(fixture.container)
            .defaultAppStorage(fixture.defaults)
            .environment(fixture.updater)
            .environment(fixture.lanSync)
            .environment(fixture.cloudSync)
            .environment(fixture.control)
            .environment(fixture.background)
            .environment(fixture.remoteSettings)
            .environment(fixture.remoteServer)
            .environment(fixture.remoteMacs)
            // 「我的设备」的状态（截图里不读真名册）。
            .environment(fixture.deviceGroup ?? RemoteDeviceGroupService { _ in nil })
            // 公网接入那一组读它（main 上早就要了，夹具一直没给，打开截图开关就崩）。
            .environment(TerminalSessionRegistry())
            .environment(\.colorScheme, dark ? .dark : .light)
    }

    // MARK: - 出图

    private func outputDirectory() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_SETTINGS_SHOTS"] ?? env["TEST_RUNNER_UTERM_SETTINGS_SHOTS"], !raw.isEmpty else {
            throw XCTSkip("设置 UTERM_SETTINGS_SHOTS=<目录> 才拍设置页截图")
        }
        let wanted = URL(fileURLWithPath: raw, isDirectory: true)
        let probe = wanted.appendingPathComponent(".write-probe")
        if (try? FileManager.default.createDirectory(at: wanted, withIntermediateDirectories: true)) != nil,
           (try? Data().write(to: probe)) != nil {
            try? FileManager.default.removeItem(at: probe)
            return wanted
        }
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("settings-shots", isDirectory: true)
            .appendingPathComponent(wanted.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    private func shoot<Content: View>(_ name: String, size: NSSize, dark: Bool, into dir: URL,
                                      @ViewBuilder content: () -> Content) async throws {
        let host = NSHostingView(rootView: AnyView(content().frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], contentView: host, placement: .offScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        // 等 `.task` / `.onAppear` 里的异步加载（技能检测、授权查询、条数）落地后再拍。
        try await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let fileName = "\(name)-\(dark ? "dark" : "light").png"
        try? png.write(to: dir.appendingPathComponent(fileName))
        // 宿主沙盒的 tmp 在 macOS 27 上别的进程读不到：同时挂成附件，从 xcresult 里导出
        // （`xcrun xcresulttool export attachments`，manifest 里的 suggestedHumanReadableName 带文件名）。
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = fileName
        attachment.lifetime = .keepAlways
        add(attachment)
        closeAllWindows()
        try await Task.sleep(for: .milliseconds(100))
    }

    private func settingsWindow(_ section: SettingsSection, _ fixture: Fixture, dark: Bool) -> some View {
        fixture.defaults.set(section.rawValue, forKey: SettingsTabSelection.key)
        return environment(SettingsView(), fixture, dark: dark)
    }

    // MARK: - 用例

    func testRenderEverySettingsPage() async throws {
        defer { closeAllWindows() }
        let dir = try outputDirectory()
        print("[settings-shots] dir=\(dir.path)")

        for section in SettingsView.sections {
            for dark in [false, true] {
                let fixture = try makeFixture(Options())
                try await shoot(section.rawValue, size: Self.windowSize, dark: dark, into: dir) {
                    settingsWindow(section, fixture, dark: dark)
                }
            }
            let fixture = try makeFixture(Options(pairingInvitation: section == .remote))
            try await shoot("\(section.rawValue)-tall", size: Self.tallSize, dark: false, into: dir) {
                settingsWindow(section, fixture, dark: false)
            }
        }

        // 最小窗口（880×600）下最挤的页面：三列的「模型服务」不能把侧栏挤出窗口。
        for section in [SettingsSection.providers, .remote, .cli] {
            let fixture = try makeFixture(Options())
            try await shoot("\(section.rawValue)-min", size: Self.minimumSize, dark: false, into: dir) {
                settingsWindow(section, fixture, dark: false)
            }
        }

        // 空态：远控关着且没有配对设备、没有模型服务。
        for dark in [false, true] {
            let empty = try makeFixture(Options(providers: false, knownHosts: false,
                                                remoteEnabled: false, pairedDevices: false))
            try await shoot("remote-empty", size: Self.windowSize, dark: dark, into: dir) {
                settingsWindow(.remote, empty, dark: dark)
            }
            try await shoot("providers-empty", size: Self.windowSize, dark: dark, into: dir) {
                settingsWindow(.providers, empty, dark: dark)
            }
        }

        // 已知主机指纹窗口（有数据 / 空）与同步诊断弹窗（测试里注入不了 CloudKit 事件，只能拍空态）。
        for dark in [false, true] {
            let fixture = try makeFixture(Options())
            try await shoot("known-hosts", size: NSSize(width: 720, height: 480), dark: dark, into: dir) {
                environment(KnownHostsManagerView(), fixture, dark: dark)
            }
            let empty = try makeFixture(Options(knownHosts: false))
            try await shoot("known-hosts-empty", size: NSSize(width: 720, height: 480), dark: dark, into: dir) {
                environment(KnownHostsManagerView(), empty, dark: dark)
            }
            try await shoot("sync-diagnostics", size: NSSize(width: 520, height: 420), dark: dark, into: dir) {
                environment(SyncDiagnosticsView(sync: fixture.cloudSync), fixture, dark: dark)
            }
        }
        print("[settings-shots] done dir=\(dir.path)")
    }

    /// 公网接入一组单独拍：打开「允许经公网接入」后才有「中继状态」「保持唤醒」与它下面的合盖提示。
    /// 中继地址是 `.invalid`，`onAppear` 里那次连接注定连不上，不会真连外网；保持唤醒关着，不在测试宿主里拿电源断言。
    func testRenderInternetAccessGroup() async throws {
        defer { closeAllWindows() }
        let dir = try outputDirectory()
        for dark in [false, true] {
            let fixture = try makeFixture(Options())
            fixture.remoteSettings.keepsAwakeForInternet = false
            fixture.remoteSettings.isInternetEnabled = true
            try await shoot("remote-internet", size: NSSize(width: 720, height: 760), dark: dark, into: dir) {
                environment(RemoteInternetGroup().padding(24).environment(TerminalSessionRegistry()), fixture, dark: dark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(UD.bg)
            }
            fixture.remoteServer.updateInternetAccess(enabled: false, keepAwake: false)
        }
    }

    // MARK: - 我的设备（设备组）

    /// 几台设备共用一份内存名册、各自一份内存本机存储，和 `RemoteDeviceGroupTests` 一样走真的加入流程。
    @MainActor
    private final class GroupRig {
        let synced = RemoteMemorySyncedStorage()
        lazy var roster = RemoteGroupRoster(storage: synced)

        func device(_ name: String, model: String?, platform: RemoteDevicePlatform) -> RemoteDeviceGroup {
            let store = RemoteGroupLocalStore(storage: RemoteMemoryStorage())
            let key = try! store.signingKey()
            let local = RemoteGroupDevice(id: UUID(), name: name, model: model, platform: platform.rawValue,
                                          publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                          signingKey: key.publicKey.rawRepresentation, updatedAt: Date())
            let group = RemoteDeviceGroup(local: local, signingKey: key, roster: roster, store: store)
            group.refresh()
            return group
        }

        /// `candidate` 经 `member` 加入，两边各刷新到回执落地。
        func join(_ candidate: RemoteDeviceGroup, via member: RemoteDeviceGroup) throws {
            candidate.startJoin()
            member.refresh()
            guard case .showingCode(let code, _) = candidate.joinState else { throw XCTSkip("没显示核对码") }
            XCTAssertTrue(member.submitCode(code, for: candidate.local.id))
            candidate.refresh()
            member.refresh()
            candidate.refresh()
            XCTAssertEqual(candidate.joinState, .joined)
        }
    }

    private func groupFixture(_ model: RemoteDeviceGroup) throws -> Fixture {
        var fixture = try makeFixture(Options())
        fixture.deviceGroup = RemoteDeviceGroupService { _ in model }
        return fixture
    }

    private func shootGroup(_ name: String, _ model: RemoteDeviceGroup, height: CGFloat = 420, into dir: URL) async throws {
        for dark in [false, true] {
            let fixture = try groupFixture(model)
            try await shoot(name, size: NSSize(width: 720, height: height), dark: dark, into: dir) {
                environment(SettingsScroll { RemoteMyDevicesGroup() }, fixture, dark: dark)
            }
        }
    }

    /// 「我的设备」§6 的几个状态：还没进组（列出其它设备）、显示核对码、三台设备的组（含等回执、还没进组的设备），
    /// 以及移除确认与组员一侧的输码面板。
    func testRenderMyDevicesGroup() async throws {
        defer { closeAllWindows() }
        let dir = try outputDirectory()

        let solo = GroupRig()
        let mac = solo.device("我的 MacBook Pro", model: "MacBook Pro", platform: .mac)
        _ = solo.device("iPhone Duo", model: "iPhone 17 Pro", platform: .mobile)
        _ = solo.device("工作室 iPad Pro", model: "iPad Pro", platform: .mobile)
        mac.refresh()
        try await shootGroup("my-devices-solo", mac, into: dir)

        mac.startJoin()
        try await shootGroup("my-devices-code", mac, height: 520, into: dir)

        let group = GroupRig()
        let mini = group.device("Mac mini", model: "Mac mini", platform: .mac)
        let phone = group.device("iPhone Duo", model: "iPhone 17 Pro", platform: .mobile)
        let laptop = group.device("我的 MacBook Pro", model: "MacBook Pro", platform: .mac)
        let ipad = group.device("工作室 iPad Pro", model: "iPad Pro", platform: .mobile)
        try group.join(phone, via: mini)
        // laptop 经 phone 加入、phone 还没读到回执：名单是三台，带「还在等……确认」；iPad 还没进组。
        laptop.startJoin()
        phone.refresh()
        guard case .showingCode(let laptopCode, _) = laptop.joinState else { return XCTFail("laptop 没显示核对码") }
        XCTAssertTrue(phone.submitCode(laptopCode, for: laptop.local.id))
        laptop.refresh()
        XCTAssertEqual(laptop.members.count, 3)
        XCTAssertNotNil(laptop.awaitingAcknowledgement)
        try await shootGroup("my-devices-group", laptop, height: 560, into: dir)

        // 移除确认（在 mini 上移除 phone）：phone 加进来的 laptop 一起列出来。
        phone.refresh()
        mini.refresh()
        let plan = RemoteGroupRemovalPlan(target: phone.local, cascade: mini.devicesAdmitted(by: phone.local.id))
        XCTAssertEqual(plan.cascade.map(\.id), [laptop.local.id])
        for dark in [false, true] {
            let fixture = try groupFixture(mini)
            try await shoot("my-devices-remove", size: NSSize(width: 400, height: 240), dark: dark, into: dir) {
                environment(RemoteGroupRemoveSheet(plan: plan) { _ in }, fixture, dark: dark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(UD.bg)
            }
        }

        // 在 mini 上移除 phone（连同 laptop）：laptop 读到后显示「已被移出」，再给「加入」。
        mini.remove(plan.ids)
        laptop.refresh()
        XCTAssertTrue(laptop.isSelfRemoved)
        XCTAssertEqual(Set(laptop.listedOtherDevices.map(\.name)), ["Mac mini", "iPhone Duo", "工作室 iPad Pro"],
                       "被移出后原来组里的设备也列出来")
        try await shootGroup("my-devices-removed", laptop, into: dir)

        // 组员一侧的输码面板（iPad 想加入，mini 上弹）：等输入、正在核对、输错后换了新数。
        let service = RemoteDeviceGroupService { _ in mini }
        service.tick()
        ipad.startJoin()
        service.tick()
        let request = try XCTUnwrap(service.pendingRequest)
        try await shootPrompt("my-devices-prompt-waiting", service, request.id, into: dir)
        guard case .showingCode(let ipadCode, _) = ipad.joinState else { return XCTFail("iPad 没显示核对码") }
        let wrong = String(format: "%06d", ((Int(ipadCode) ?? 0) + 1) % 1_000_000)
        XCTAssertTrue(service.submit(wrong, for: request))
        try await shootPrompt("my-devices-prompt-verifying", service, request.id, into: dir)
        ipad.refresh()
        service.tick()
        try await shootPrompt("my-devices-prompt-wrong", service, request.id, into: dir)
    }

    private func shootPrompt(_ name: String, _ service: RemoteDeviceGroupService, _ id: UUID, into dir: URL) async throws {
        let fixture = try makeFixture(Options())
        for dark in [false, true] {
            try await shoot(name, size: NSSize(width: 400, height: 200), dark: dark, into: dir) {
                environment(RemoteDeviceGroupPromptView(service: service, candidateID: id), fixture, dark: dark)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(UD.panel)
            }
        }
    }
}

private final class SnapshotKeyValueStore: NSUbiquitousKeyValueStore {}
