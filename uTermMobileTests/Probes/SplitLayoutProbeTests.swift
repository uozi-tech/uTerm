import SwiftUI
import SwiftTerm
import UIKit
import XCTest
@testable import uTermMobile

/// 分屏、挪标签、转屏之后，每个前台终端都要落在自己那一格的内容区里。
@MainActor
final class SplitLayoutProbeTests: XCTestCase {
    private let portrait = CGSize(width: 669, height: 900)
    private let landscape = CGSize(width: 900, height: 669)

    private func mount() async throws -> (MobileWorkspace, UIWindow) {
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let h = try XCTUnwrap(MobileFixtures.firstServer(in: c))
        let relay = HostKeyChallengeRelay()
        let store = MobileStore()
        store.showWorkspace = true
        let (work, _) = MobileFakeTerminal.sessions(
            count: 3, hosts: [h],
            script: MobileFakeTerminalScript(linesPerSecond: 200, seconds: 1, corpus: .ansiColor),
            container: c, relay: relay)
        for tab in work.terminalTabs { _ = await MobileFakeTerminal.waitUntilConnected(tab.controller) }
        let root = WorkspaceScreen().environment(store).environment(relay).environment(work)
            .environment(\.mAccent, M.accent).modelContainer(c)
        let (win, _) = MobileProbeWindow.make(size: portrait, placement: .visibleOnScreen,
                                              isolateHost: true, rootView: root)
        try await Task.sleep(for: .seconds(1))
        return (work, win)
    }

    private func resize(_ win: UIWindow, _ size: CGSize) async throws {
        win.frame = CGRect(origin: win.frame.origin, size: size)
        try await Task.sleep(for: .milliseconds(600))
    }

    /// 返回偏离格子的描述；空数组 = 全部就位。
    private func misplaced(_ work: MobileWorkspace, _ win: UIWindow, _ step: String) -> [String] {
        let layout = WorkspaceSplitGeometry(size: win.bounds.size, paneCount: work.panes.count,
                                            preferredAxis: work.splitAxis, fraction: work.splitFraction)
        var problems: [String] = []
        for (index, pane) in work.panes.enumerated() {
            guard let term = work.tab(pane.activeID)?.terminal,
                  let view = term.controller.terminalView else { continue }
            let slot = layout.rects[min(index, layout.rects.count - 1)]
            let rect = view.convert(view.bounds, to: win)
            print("SPLITLAYOUT \(step) pane\(index) slot=\(slot.integral) term=\(rect.integral)")
            if view.window == nil { problems.append("\(step) pane\(index): 不在窗口里"); continue }
            if rect.minX < slot.minX - 1 || rect.maxX > slot.maxX + 1
                || rect.minY < slot.minY + WorkspaceTabStrip.height - 1 || rect.maxY > slot.maxY + 1 {
                problems.append("\(step) pane\(index): term=\(rect.integral) slot=\(slot.integral)")
            }
        }
        return problems
    }

    /// 标签换格后 SwiftUI 不再更新新终端的 frame：布局算得对，UIKit 宿主却永远停在换格那一刻。
    func testTerminalsStayInsideTheirPanes() async throws {
        defer { MobileProbeWindow.closeAll() }
        let (work, win) = try await mount()
        var problems = misplaced(work, win, "mounted")

        work.split()
        try await Task.sleep(for: .milliseconds(400))
        problems += misplaced(work, win, "split")

        let moving = work.tabs.map(\.id)[1]
        work.activate(moving)
        try await Task.sleep(for: .milliseconds(300))
        var size = portrait
        for round in 1...4 {
            work.moveToOtherPane(moving)
            try await Task.sleep(for: .milliseconds(400))
            problems += misplaced(work, win, "move\(round)")
            size = size == portrait ? landscape : portrait
            try await resize(win, size)
            problems += misplaced(work, win, "resize\(round)")
            work.splitFraction = 0.6
            try await Task.sleep(for: .milliseconds(300))
            problems += misplaced(work, win, "fraction\(round)")
            work.splitFraction = 0.5
            try await Task.sleep(for: .milliseconds(300))
        }

        work.unsplit()
        try await Task.sleep(for: .milliseconds(400))
        problems += misplaced(work, win, "unsplit")
        work.split()
        try await Task.sleep(for: .milliseconds(400))
        try await resize(win, size == portrait ? landscape : portrait)
        problems += misplaced(work, win, "resplit")

        for tab in work.terminalTabs { tab.controller.close() }
        XCTAssertEqual(problems, [])
    }

    /// 运行中新开的标签同样要跟着转屏。
    func testTabOpenedLiveFollowsResize() async throws {
        defer { MobileProbeWindow.closeAll() }
        let (work, win) = try await mount()
        work.split()
        try await Task.sleep(for: .milliseconds(400))
        let host = try XCTUnwrap(work.terminalTabs.first?.host)
        let (tab, _) = MobileFakeTerminal.tab(host: host, MobileFakeTerminalScript(linesPerSecond: 200, seconds: 1, corpus: .ansiColor))
        work.open(.terminal(tab), in: work.panes[1].id)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNotNil(tab.controller.terminalView)
        try await resize(win, landscape)
        XCTAssertEqual(misplaced(work, win, "live-opened"), [])
        for tab in work.terminalTabs { tab.controller.close() }
    }

    /// 快捷键整排都能横向滚动，包括 ctrl / alt，一格窄到放不下时也够得到每个键。
    func testKeyBarScrollsAsOneRow() async throws {
        defer { MobileProbeWindow.closeAll() }
        let (controller, _) = MobileFakeTerminal.controller(.idle)
        let width: CGFloat = 260
        let (win, _) = MobileProbeWindow.make(size: CGSize(width: width, height: 60), placement: .visibleOnScreen,
                                              isolateHost: true, rootView: TerminalKeyBar(controller: controller))
        try await Task.sleep(for: .milliseconds(400))
        let scroll = try XCTUnwrap(Self.firstScrollView(in: win))
        let frame = scroll.convert(scroll.bounds, to: win)
        XCTAssertEqual(frame.minX, 0, accuracy: 0.5, "左边不能有固定不动的键")
        XCTAssertEqual(frame.width, width, accuracy: 0.5)
        XCTAssertGreaterThan(scroll.contentSize.width, width)
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews {
            if let found = firstScrollView(in: child) { return found }
        }
        return nil
    }
}
