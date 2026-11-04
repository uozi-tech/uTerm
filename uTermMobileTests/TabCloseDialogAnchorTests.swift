import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 宽屏下关标签的确认框是 popover：它要从被关的那枚标签弹出，而不是工作区正中央。
@MainActor
final class TabCloseDialogAnchorTests: XCTestCase {
    private struct Harness: View {
        let tabs: [MWorkTab]
        let prompt: MTabClosePrompt

        @State private var closePrompt: MTabClosePrompt?

        var body: some View {
            VStack(spacing: 0) {
                WorkspaceTabStrip(tabs: tabs, activeID: tabs.first?.id,
                                  onSelect: { _ in }, onClose: { _ in }, onNew: { _ in },
                                  onBack: {}, onAgent: {},
                                  closePrompt: $closePrompt)
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .task {
                try? await Task.sleep(for: .milliseconds(400))
                closePrompt = prompt
            }
        }
    }

    func testPopoverPointsAtTheTabBeingClosed() async throws {
        defer { MobileProbeWindow.closeAll() }
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let (workspace, _) = MobileFakeTerminal.sessions(
            count: 2, hosts: [host],
            script: MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0),
            container: container, relay: HostKeyChallengeRelay())
        let tabs = workspace.tabs
        let prompt = MTabClosePrompt(tabID: tabs[0].id, kind: .remote(macName: "Mac"))

        let root = Harness(tabs: tabs, prompt: prompt)
            .environment(\.mAccent, M.accent)
            .modelContainer(container)
        let (window, _) = MobileProbeWindow.make(size: CGSize(width: 1000, height: 700),
                                                 placement: .visibleOnScreen,
                                                 isolateHost: true, rootView: root)
        let controller = try XCTUnwrap(window.rootViewController)
        var dialog: UIViewController?
        for _ in 0..<50 where dialog == nil {
            try await Task.sleep(for: .milliseconds(100))
            dialog = controller.presentedViewController
        }
        let presented = try XCTUnwrap(dialog, "确认框没有弹出来")
        try await Task.sleep(for: .milliseconds(500))
        defer { presented.dismiss(animated: false) }
        // 窄屏是底部操作表，弹得出来就行；位置只在宽屏的 popover 上有意义。
        guard window.traitCollection.horizontalSizeClass == .regular else { return }

        let frame = presented.view.convert(presented.view.bounds, to: window)
        print("TABCLOSE popover=\(frame.integral) window=\(window.bounds.size)")
        // 标签条高 48、第一枚标签在左端；popover 应贴在条下方、靠左。
        XCTAssertLessThan(frame.minY, WorkspaceTabStrip.height + 40, "popover 没贴着标签条：\(frame)")
        XCTAssertLessThan(frame.midX, window.bounds.midX, "popover 没靠近第一枚标签：\(frame)")
    }
}
