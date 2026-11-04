import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 标签条为了不进侧边安全区加了裁剪和 contentShape：长按菜单、拖动分屏不能跟着丢。
@MainActor
final class TabStripInteractionProbeTests: XCTestCase {
    private func firstHorizontalScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 0.5 { return scroll }
        for child in view.subviews {
            if let found = firstHorizontalScrollView(in: child) { return found }
        }
        return nil
    }

    private func interactions(from view: UIView?) -> [UIInteraction] {
        var result: [UIInteraction] = []
        var current = view
        while let candidate = current {
            result += candidate.interactions
            current = candidate.superview
        }
        return result
    }

    func testChipStillOffersLongPressMenuAndDragInsideTheSafeArea() async throws {
        defer { MobileProbeWindow.closeAll() }
        let host = ServerProfile()
        host.name = "主机"
        let tabs: [MWorkTab] = (0..<8).map { _ in .terminal(MobileFakeTerminal.tab(host: host, .idle).0) }
        let strip = VStack(spacing: 0) {
            WorkspaceTabStrip(tabs: tabs, activeID: tabs[0].id, onSelect: { _ in }, onClose: { _ in },
                              onNew: { _ in }, onBack: {}, onAgent: {})
            Spacer()
        }
        let (win, hosting) = MobileProbeWindow.make(size: CGSize(width: 500, height: 300), placement: .visibleOnScreen,
                                                    isolateHost: true, rootView: strip)
        hosting.safeAreaRegions = .all
        hosting.additionalSafeAreaInsets.right = 84
        try await Task.sleep(for: .milliseconds(600))

        let scroll = try XCTUnwrap(firstHorizontalScrollView(in: win))
        let frame = scroll.convert(scroll.bounds, to: win)
        let hit = win.hitTest(CGPoint(x: frame.minX + 40, y: frame.midY), with: nil)
        XCTAssertTrue(hit?.isDescendant(of: scroll) ?? false, "点到标签上")

        let attached = interactions(from: hit)
        XCTAssertTrue(attached.contains { $0 is UIContextMenuInteraction }, "长按菜单还在：\(attached)")
        XCTAssertTrue(attached.contains { $0 is UIDragInteraction }, "拖动分屏还在：\(attached)")
    }
}
