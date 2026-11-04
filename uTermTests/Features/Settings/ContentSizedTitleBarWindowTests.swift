import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 自绘标题栏 + 窗口随内容定高（授权引导窗口）：窗口不能比内容高出一截标题栏安全区。
@MainActor
final class ContentSizedTitleBarWindowTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        var frame: CGRect = .zero
    }

    private func layout(_ root: some View) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = [.minSize, .maxSize, .preferredContentSize]
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                                      styleMask: [.titled, .closable, .fullSizeContentView],
                                      contentView: host)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for _ in 0..<3 {
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return (host, window)
    }

    private func content(_ box: Box) -> some View {
        VStack(spacing: 0) {
            Color.red.frame(height: 38)
            Color.blue.frame(height: 200)
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { box.frame = $0 }
    }

    func testWindowHeightMatchesContentWithoutTitleBarGap() {
        let box = Box()
        let (host, window) = layout(content(box).contentSizedUnderTitleBar())
        defer { window.orderOut(nil) }

        XCTAssertGreaterThan(host.safeAreaInsets.top, 0, "前提：窗口有标题栏安全区")
        XCTAssertEqual(host.bounds.height, 238, accuracy: 0.5, "窗口高度应正好等于内容")
        XCTAssertEqual(box.frame.minY, 0, accuracy: 0.5, "内容顶到窗口最上沿（标题栏自绘）")
        XCTAssertEqual(box.frame.height, 238, accuracy: 0.5)
    }
}
