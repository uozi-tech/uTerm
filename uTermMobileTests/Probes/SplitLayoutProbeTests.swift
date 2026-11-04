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

    // MARK: 横向滚动条不进侧边安全区
    //
    // Duo 横屏时状态栏那一列是右侧安全区，内容滚进去看得见、点不到：既不能画进去，也不能在那里命中。
    // 滚到头时最后一项要正好露在安全区以内。

    func testKeyBarStaysOutOfSideSafeArea() async throws {
        let (controller, _) = MobileFakeTerminal.controller(.idle)
        try await assertScrollRowStaysInSafeArea(side: .right, root: VStack(spacing: 0) {
            Color.clear
            TerminalKeyBar(controller: controller)
        })
    }

    func testTabStripStaysOutOfSideSafeArea() async throws {
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let h = try XCTUnwrap(MobileFixtures.firstServer(in: c))
        let (work, _) = MobileFakeTerminal.sessions(
            count: 6, hosts: [h],
            script: MobileFakeTerminalScript(linesPerSecond: 200, seconds: 1, corpus: .ansiColor),
            container: c, relay: HostKeyChallengeRelay())
        defer { for tab in work.terminalTabs { tab.controller.close() } }
        // 状态栏在右侧一列时，条尾的开关挪到那一列，标签的滚动区直接贴着安全区。
        try await assertScrollRowStaysInSafeArea(side: .right, root: VStack(spacing: 0) {
            WorkspaceTabStrip(tabs: work.tabs, activeID: work.focusedPane.activeID,
                              onSelect: { _ in }, onClose: { _ in }, onNew: { _ in }, onBack: {}, onAgent: {},
                              showsTrailingControls: false)
            Color.clear
        }.environment(\.mAccent, M.accent))
    }

    /// 路径条右边是刷新按钮，碰不到右侧安全区；滚动区贴着的是左侧。
    func testPathBarStaysOutOfSideSafeArea() async throws {
        let deep = "/" + (0..<8).map { "directory-with-a-long-name-\($0)" }.joined(separator: "/")
        let provider = MobileFakeSFTPProvider(tree: MobileFakeSFTPTree(directories: [deep: []], home: deep))
        let tab = FileTab(host: ServerProfile(), controller: await MobileFakeSFTP.controller(provider: provider, path: deep))
        try await assertScrollRowStaysInSafeArea(side: .left, root: FilesSessionBody(tab: tab, onClose: {})
            .environment(\.mAccent, M.accent))
    }

    private enum SafeAreaSide { case left, right }

    private func assertScrollRowStaysInSafeArea<Root: View>(side: SafeAreaSide, root: Root,
                                                            line: UInt = #line) async throws {
        defer { MobileProbeWindow.closeAll() }
        let (win, host) = MobileProbeWindow.make(size: CGSize(width: 500, height: 300), placement: .visibleOnScreen,
                                                 isolateHost: true, rootView: root)
        // 夹具默认让 SwiftUI 无视安全区，这里要的正是安全区。
        let column: CGFloat = 84
        host.safeAreaRegions = .all
        switch side {
        case .left: host.additionalSafeAreaInsets.left = column
        case .right: host.additionalSafeAreaInsets.right = column
        }
        try await Task.sleep(for: .milliseconds(600))

        let scroll = try XCTUnwrap(Self.firstHorizontalScrollView(in: win), line: line)
        XCTAssertGreaterThan(scroll.contentSize.width, win.bounds.width - column, "内容要长到需要滚动", line: line)
        let safe = host.view.convert(host.view.safeAreaLayoutGuide.layoutFrame, to: win)
        let midY = scroll.convert(scroll.bounds, to: win).midY
        let clip = try XCTUnwrap(Self.clippingAncestor(of: scroll, narrowerThan: win.bounds.width, in: win), line: line)
        let clipFrame = clip.convert(clip.bounds, to: win)

        let columnPoints: [CGFloat]
        let inside: CGFloat
        switch side {
        case .left:
            XCTAssertGreaterThanOrEqual(clipFrame.minX, safe.minX - 0.5, "画面要裁在安全区以内", line: line)
            columnPoints = [5, safe.minX - 40, safe.minX - 10]
            inside = clipFrame.minX + 20
        case .right:
            XCTAssertLessThanOrEqual(clipFrame.maxX, safe.maxX + 0.5, "画面要裁在安全区以内", line: line)
            columnPoints = [safe.maxX + 10, safe.maxX + 40, win.bounds.maxX - 5]
            inside = clipFrame.maxX - 20
        }
        for x in columnPoints {
            let hit = win.hitTest(CGPoint(x: x, y: midY), with: nil)
            XCTAssertFalse(hit?.isDescendant(of: scroll) ?? false, "x=\(x) 在侧边安全区，不该命中滚动内容", line: line)
        }
        let insideHit = win.hitTest(CGPoint(x: inside, y: midY), with: nil)
        XCTAssertTrue(insideHit?.isDescendant(of: scroll) ?? false, "安全区以内要照常命中", line: line)

        // 滚到贴着安全区的那一头：那一头的内容边缘正好停在裁剪边界上，不缺内容。
        switch side {
        case .left:
            scroll.setContentOffset(CGPoint(x: -scroll.adjustedContentInset.left, y: 0), animated: false)
            try await Task.sleep(for: .milliseconds(200))
            let start = scroll.convert(CGPoint.zero, to: win).x
            XCTAssertEqual(start, clipFrame.minX, accuracy: 0.5, "滚到头时第一项要露全", line: line)
        case .right:
            let end = scroll.contentSize.width + scroll.adjustedContentInset.right - scroll.bounds.width
            scroll.setContentOffset(CGPoint(x: end, y: 0), animated: false)
            try await Task.sleep(for: .milliseconds(200))
            let contentEnd = scroll.convert(CGPoint(x: scroll.contentSize.width, y: 0), to: win).x
            XCTAssertEqual(contentEnd, clipFrame.maxX, accuracy: 0.5, "滚到底时最后一项要露全", line: line)
        }
    }

    private static func firstHorizontalScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.bounds.height < 60 { return scroll }
        for child in view.subviews {
            if let found = firstHorizontalScrollView(in: child) { return found }
        }
        return nil
    }

    private static func clippingAncestor(of view: UIView, narrowerThan width: CGFloat, in win: UIWindow) -> UIView? {
        var current = view.superview
        while let candidate = current, candidate !== win {
            if candidate.clipsToBounds, candidate.bounds.width < width - 0.5 { return candidate }
            current = candidate.superview
        }
        return nil
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews {
            if let found = firstScrollView(in: child) { return found }
        }
        return nil
    }
}
