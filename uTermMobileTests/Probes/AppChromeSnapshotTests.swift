import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 真机手动：`TEST_RUNNER_UTERM_CHROME_SNAPSHOT=1` 时，走 App 自己的 `mMeasuresChrome()`（`MChromeMeasurer` +
/// `MTopBarProbe`，不是 `FoldableChromeProbeTests` 那份重算）量一次 `\.mChrome`，打一行 `CHROME`；再把宿主 App
/// 此刻的窗口截下来作附件（`-resultBundlePath` 取出），看 Agent / 分屏开关实际画在哪。
@MainActor
final class AppChromeSnapshotTests: XCTestCase {
    func testMeasureAndSnapshotTheRunningApp() async throws {
        guard ProcessInfo.processInfo.environment["UTERM_CHROME_SNAPSHOT"] != nil else { throw XCTSkip("按需") }
        let scene = try XCTUnwrap(MobileProbeWindow.activeScene(), "没有前台场景")
        let appWindow = try XCTUnwrap(scene.windows.first { $0.isKeyWindow } ?? scene.windows.first, "没有 App 窗口")

        let sink = ChromeSink()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ChromeReader(sink: sink).mMeasuresChrome())
        window.rootViewController?.view.backgroundColor = .clear
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        // MChromeMeasurer 在 0.4 s、1.2 s 各补量一次，探针也一样：等到读数连续两次不变。
        var previous = ""
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(300))
            let line = sink.describe()
            if line == previous, sink.chrome.root != .zero { break }
            previous = line
        }
        print("CHROME \(sink.describe())")

        let renderer = UIGraphicsImageRenderer(bounds: appWindow.bounds)
        let image = renderer.image { _ in appWindow.drawHierarchy(in: appWindow.bounds, afterScreenUpdates: false) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "app-window"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class ChromeSink {
    var chrome = MChromeGeometry()

    func describe() -> String {
        let c = chrome
        let s = c.safeAreaInsets
        return "screen=\(foldRect(c.screen)) safe=t\(Int(s.top)) l\(Int(s.leading)) b\(Int(s.bottom)) r\(Int(s.trailing)) "
            + "statusBar=\(c.statusBar.map(foldRect) ?? "nil") "
            + "col=\(c.statusColumn.map { "\($0.edge) w\(Int($0.width)) bottom\(Int($0.statusBottom))" } ?? "nil") "
            + "sideCol=\(c.hasSideStatusColumn) vbar=\(c.verticalBarEdge.map { "\($0)" } ?? "nil")/\(c.reportsVerticalBarEdge) "
            + "row=\(c.statusRowHeight.map { "\(Int($0))" } ?? "nil") unfolded=\(c.isUnfoldedPhone)"
    }
}

private struct ChromeReader: View {
    let sink: ChromeSink
    @Environment(\.mChrome) private var chrome

    var body: some View {
        Color.clear.onChange(of: chrome, initial: true) { _, new in sink.chrome = new }
    }
}
