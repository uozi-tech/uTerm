import AppKit
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
        try identity.trust(RemotePeer(id: UUID(), name: "办公室 Mac Studio", publicKey: key, pairedAt: .now,
                                      platform: RemoteDevicePlatform.mac.rawValue))
        let directory = RemoteMacDirectory(identity: identity, defaults: defaults, adoptsRelayAsDefault: false)
        for dark in [false, true] {
            try await shoot("my-macs", size: NSSize(width: 620, height: 560), dark: dark, into: dir) {
                RemoteMacsWindowView().environment(directory)
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
