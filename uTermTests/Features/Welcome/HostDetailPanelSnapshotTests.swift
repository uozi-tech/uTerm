import AppKit
import SwiftData
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 主机详情面板（普通主机 / 仅 SFTP）渲染成 PNG，供改动前后逐像素比对。不做断言。
///
/// **不进常规全量**：设置了 `UTERM_WELCOME_SHOTS=1`（经 xcodebuild 写成 `TEST_RUNNER_UTERM_WELCOME_SHOTS`）才跑。
/// 图写进测试宿主沙盒的 tmp 下 `welcome-shots/`，路径打在日志里，同时挂成 `XCTAttachment`。
@MainActor
final class HostDetailPanelSnapshotTests: XCTestCase {
    private func directory() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_WELCOME_SHOTS"] ?? env["TEST_RUNNER_UTERM_WELCOME_SHOTS"], !raw.isEmpty else {
            throw XCTSkip("设置 UTERM_WELCOME_SHOTS=1 才拍主机详情截图")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("welcome-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func shoot<Content: View>(_ name: String, size: NSSize, dark: Bool, into dir: URL,
                                      @ViewBuilder content: () -> Content) async throws {
        let host = NSHostingView(rootView: content()
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], contentView: host, placement: .offScreen)
        defer { window.orderOut(nil) }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let fileName = "\(name)-\(dark ? "dark" : "light").png"
        try png.write(to: dir.appendingPathComponent(fileName))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = fileName
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRenderHostDetailPanel() async throws {
        let dir = try directory()
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ServerProfile.self, configurations: config)
        let context = ModelContext(container)

        // 「上次连接」留空（显示「从未」）：相对时间会随运行时刻变，前后两次截图就比不了。
        let normal = ServerProfile()
        normal.name = "prod-api-01"
        normal.host = "10.0.12.34"
        normal.username = "deploy"
        normal.port = 2222
        normal.group = "生产"
        context.insert(normal)
        let filesOnly = ServerProfile()
        filesOnly.name = "assets-bucket"
        filesOnly.host = "files.example.com"
        filesOnly.username = "sftp"
        filesOnly.sftpOnly = true
        context.insert(filesOnly)

        for dark in [false, true] {
            for (name, profile) in [("host-detail", normal), ("host-detail-sftp-only", filesOnly)] {
                try await shoot(name, size: NSSize(width: 320, height: 420), dark: dark, into: dir) {
                    HostDetailPanel(profile: profile, groupColor: UD.accent,
                                    onConnect: {}, onOpenTerminal: {}, onBrowseSFTP: {})
                        .background(UD.panel)
                }
            }
        }
        print("[welcome-shots] dir=\(dir.path)")
    }
}
