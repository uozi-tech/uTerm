import AppKit
@preconcurrency import Network
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 「我的 Mac」窗口与远程 Mac 窗口的几个状态渲染成 PNG，给人眼验收排版。不做断言。
///
/// **不进常规全量**：设置了 `UTERM_REMOTE_SHOTS=<目录>`（经 xcodebuild 写成 `TEST_RUNNER_UTERM_REMOTE_SHOTS`）
/// 才跑。图同时挂成 `XCTAttachment`，用 `xcrun xcresulttool export attachments` 导出（同 `SettingsPageSnapshotTests`）。
@MainActor
final class RemoteMacControllerSnapshotTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    private func directory() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_REMOTE_SHOTS"] ?? env["TEST_RUNNER_UTERM_REMOTE_SHOTS"], !raw.isEmpty else {
            throw XCTSkip("设置 UTERM_REMOTE_SHOTS=<目录> 才拍远程 Mac 窗口截图")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func shoot<Content: View>(_ name: String, size: NSSize, dark: Bool, into dir: URL,
                                      @ViewBuilder content: () -> Content) async throws {
        let host = NSHostingView(rootView: AnyView(content()
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], contentView: host, placement: .offScreen)
        windows.append(window)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let fileName = "\(name)-\(dark ? "dark" : "light").png"
        try? png.write(to: dir.appendingPathComponent(fileName))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = fileName
        attachment.lifetime = .keepAlways
        add(attachment)
        window.orderOut(nil)
    }

    func testRenderRemoteMacWindows() async throws {
        let dir = try directory()
        let suite = "RemoteMacControllerSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let key = try identity.localIdentity().publicKey.rawRepresentation
        let macID = UUID()
        try identity.trust(RemotePeer(id: macID, name: "办公室 Mac Studio", publicKey: key, pairedAt: .now,
                                      platform: RemoteDevicePlatform.mac.rawValue))
        try identity.trust(RemotePeer(id: UUID(), name: "家里的 MacBook Pro", publicKey: key,
                                      pairedAt: .now.addingTimeInterval(-86_400 * 12),
                                      platform: RemoteDevicePlatform.mac.rawValue))
        // 调试直连当作一台局域网里在线的 Mac（列表里唯一能伪造出「在线」的入口）。
        defaults.set("127.0.0.1:9", forKey: DefaultsKey.remoteDebugEndpoint)
        let directory = RemoteMacDirectory(identity: identity, defaults: defaults, adoptsRelayAsDefault: false)
        let client = RemoteMacClient(macName: "办公室 Mac Studio", endpoint: .hostPort(host: "127.0.0.1", port: 9),
                                     identity: identity)
        let desktop = RemoteDesktopWindowModel(
            client: client, session: RemoteDesktopSession(client: client, maxWidth: 1920, maxHeight: 1080))
        let log = RemotePathMatrixLog(defaults: defaults)
        let runID = UUID()
        func probe(_ mode: RemotePathProbeMode, _ connected: Bool, failure: String? = nil,
                   setup: Int? = nil, rtt: Double? = nil) -> RemotePathProbeResult {
            var result = RemotePathProbeResult(runID: runID, mode: mode, network: "Wi-Fi · 有 IPv6",
                                               connected: connected, failure: failure)
            result.setupMillis = setup
            result.roundTripMillis = rtt
            result.roundTripP95Millis = rtt.map { $0 * 1.8 }
            result.lossPercent = connected ? 0 : nil
            return result
        }
        log.append([probe(.localNetwork, false, failure: "Mac 不在这个局域网里"),
                    probe(.directIPv6, true, setup: 1240, rtt: 18.4),
                    probe(.directIPv4, false, failure: "打洞超时"),
                    probe(.relay, true, setup: 620, rtt: 42.7)])
        // 「配对其他 Mac」：局域网里两台不在本机 iCloud 账户里的 Mac（账户里一台都没登记），和一台都没找到。
        let strangers = RemoteMacDirectory(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()),
                                           defaults: defaults, adoptsRelayAsDefault: false, accountDevices: { [] })
        strangers.setDiscovered([UUID(): ("设计部的 iMac", .hostPort(host: "192.168.1.20", port: 4000)),
                                 UUID(): ("会议室 Mac mini", .hostPort(host: "192.168.1.21", port: 4000))])
        let nobody = RemoteMacDirectory(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()),
                                        defaults: defaults, adoptsRelayAsDefault: false, accountDevices: { [] })
        let diagnostics = RemotePathDiagnosticsModel(log: log, networkLabel: { "Wi-Fi · 有 IPv6" })
        diagnostics.reloadHistory()
        for dark in [false, true] {
            try await shoot("diagnostics", size: NSSize(width: 640, height: 900), dark: dark, into: dir) {
                RemoteDiagnosticsContent(model: diagnostics, macID: macID.uuidString)
                    .background(UD.bg).environment(directory)
            }
            try await shoot("desktop-window-connecting", size: NSSize(width: 900, height: 600), dark: dark, into: dir) {
                RemoteDesktopContent(model: desktop).background(Color.black).environment(\.colorScheme, .dark)
            }
            // 欢迎窗口去掉侧栏后的内容区大小。第一台是调试直连（局域网在线），第二台配对过、不在线。
            try await shoot("my-macs-online", size: NSSize(width: 860, height: 560), dark: dark, into: dir) {
                RemoteMacsPane().environment(directory)
            }
            try await shoot("my-macs-offline", size: NSSize(width: 860, height: 560), dark: dark, into: dir) {
                RemoteMacsPane(initialSelectionID: macID.uuidString).environment(directory)
            }
            // 空态直接画：整个面板一出现就开 Bonjour，本机局域网里的 Mac 会混进来。
            try await shoot("my-macs-empty", size: NSSize(width: 860, height: 560), dark: dark, into: dir) {
                RemoteMacsEmptyState {}.background(UD.panel)
            }
            try await shoot("pair-other-mac", size: NSSize(width: 440, height: 430), dark: dark, into: dir) {
                RemotePairingOtherMacSheet { _ in }.environment(strangers)
            }
            try await shoot("pair-other-mac-none", size: NSSize(width: 440, height: 300), dark: dark, into: dir) {
                RemotePairingOtherMacSheet { _ in }.environment(nobody)
            }
            try await shoot("pairing-code", size: NSSize(width: 900, height: 600), dark: dark, into: dir) {
                RemoteMacPairingCodeView(macName: "办公室 Mac Studio", code: "482913").background(UD.bg)
            }
            try await shoot("no-terminals", size: NSSize(width: 900, height: 600), dark: dark, into: dir) {
                RemoteMacStateView(systemImage: "terminal", title: "这台 Mac 上没有打开的终端",
                                   detail: "新建一个，那台 Mac 上也会弹出对应的终端窗口。").background(UD.bg)
            }
        }
        print("[remote-shots] dir=\(dir.path)")
    }
}
