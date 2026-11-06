import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 授权引导窗口的整窗高度：一眼看完、不让人以为下面还有内容。
///
/// 设 `UTERM_PERMISSION_GUIDE_SNAPSHOT_DIR`（xcodebuild 下写成 `TEST_RUNNER_UTERM_PERMISSION_GUIDE_SNAPSHOT_DIR`）
/// 时把浅色 / 深色各一张 PNG 写进该目录（测试宿主有沙盒，目录要在它的容器 tmp 下），供人眼核对版式。
@MainActor
final class PermissionGuideLayoutTests: XCTestCase {
    /// 五项 + 重启提示（最高的一态）：旧版 774pt，13 寸屏扣掉菜单栏和程序坞后已所剩无几；现约 581pt。
    private let worstCaseLimit: CGFloat = 600
    /// 常见情况（四项、无重启提示）：旧版 587pt，现约 448pt。
    private let commonCaseLimit: CGFloat = 470

    /// 本地网络已允许、通知未询问、其余未允许；`everything` 时再加上登录项与重启提示（五项 + 横幅，最高的一态）。
    private func model(everything: Bool) async -> PermissionGuideModel {
        let environment = PermissionGuideEnvironment(
            notificationStatus: { .notAsked },
            requestNotifications: {},
            screenCaptureGranted: { false },
            requestScreenCapture: {},
            postEventsGranted: { false },
            requestPostEvents: {},
            loginItemNeedsApproval: { everything },
            observeLocalNetwork: { update in
                update(.granted)
                return {}
            },
            openSettings: { _ in },
            relaunch: {})
        let model = PermissionGuideModel(environment: environment)
        if everything {
            await model.request(.screenCapture)
        } else {
            await model.refresh()
        }
        return model
    }

    /// 用 `Task.sleep` 让出主线程，不用 `RunLoop.main.run`：用例是 async 的，本身就跑在主队列的一个任务里，
    /// 嵌套跑 runloop 排不到主队列——标题栏高度读数（`DispatchQueue.main.async` 回写）要等用例结束才生效，
    /// 窗口会一直多出 32pt。
    private func layout(_ model: PermissionGuideModel, scheme: ColorScheme) async throws -> (NSHostingView<AnyView>, NSWindow) {
        let root = PermissionGuideView(model: model).environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = [.minSize, .maxSize, .preferredContentSize]
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
                                      styleMask: [.titled, .closable, .fullSizeContentView],
                                      contentView: host)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // `WorkspaceWindowChrome` 会把 window.appearance 置 nil（跟随 NSApp），这里每轮都钉回来，窗口底色才对得上。
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        for _ in 0..<6 {
            window.appearance = appearance
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
        }
        return (host, window)
    }

    private func snapshot(_ host: NSView, name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["UTERM_PERMISSION_GUIDE_SNAPSHOT_DIR"] else { return }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        print("PermissionGuide snapshot: \(url.path) \(Int(host.bounds.width))×\(Int(host.bounds.height))")
    }

    func testCommonCaseFitsCompactly() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let (host, window) = try await layout(await model(everything: false), scheme: scheme)
            defer { window.orderOut(nil) }
            try snapshot(host, name: "permission-guide-common-\(scheme)")
            XCTAssertLessThanOrEqual(window.frame.height, commonCaseLimit, "\(scheme)")
            XCTAssertEqual(window.frame.width, 580, accuracy: 0.5)
        }
    }

    func testWorstCaseStaysWellInsideSmallScreens() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let (host, window) = try await layout(await model(everything: true), scheme: scheme)
            defer { window.orderOut(nil) }
            try snapshot(host, name: "permission-guide-worst-\(scheme)")
            XCTAssertLessThanOrEqual(window.frame.height, worstCaseLimit, "\(scheme)")
        }
    }
}
