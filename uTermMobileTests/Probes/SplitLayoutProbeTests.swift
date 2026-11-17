import GhosttyTerminal
import SwiftUI
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
            guard let term = work.tab(pane.activeID)?.terminal else { continue }
            let view = term.controller.terminal.view
            // 视图现在由控制器自己建、恒在；从没挂过的（换引擎之前是「控制器上还没有视图」）照旧跳过。
            guard view.superview != nil || view.hasHostedLayout else { continue }
            let slot = layout.rects[min(index, layout.rects.count - 1)]
            // 按行填满会把视图往下挪零头的上半份（尺寸不变、露出容器底边的那截裁掉）：挪回来再比，比的是容器给它的位置。
            let rect = view.convert(view.bounds, to: win).offsetBy(dx: 0, dy: -term.controller.terminal.link.rowFillOffset)
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

    /// 每一格前台的终端都在画：分屏、挪标签、折叠 / 展开（Duo 外屏 466 宽时只能单格）之后，
    /// 不能有哪个看得见的终端停画——停了画面就永远停在那一刻（真机回归：远控 Claude 标签画面卡死）。
    ///
    /// 「停画」在 Ghostty 上是三件事里的任何一件（都由 `MTerminalContainerView.isOnScreen` → `GhosttyTerminalBridge.setOnScreen`
    /// 写进去；当年的 bug 是外壳切换后旧容器把「不在屏上」写进了新容器接走的视图）：
    /// - 终端记着自己不在屏上（`isOnScreen == false`）；
    /// - 视图被告知不显示（`setSurfaceVisible(false)`：不出帧、放掉 display link。它同时停用系统滚动的手势，
    ///   这里读那个手势的 `isEnabled` 当它的回读，GhosttyKit 没有别的公开读法）；
    /// - surface 被放掉了（`uTermIsSurfaceReleased`，隐藏久了才会）。
    private func frozen(_ work: MobileWorkspace, _ step: String) -> [String] {
        work.panes.enumerated().compactMap { index, pane in
            guard let term = work.tab(pane.activeID)?.terminal else { return nil }
            let terminal = term.controller.terminal
            let view = terminal.view
            guard view.window != nil else { return nil }
            var reasons: [String] = []
            if !terminal.isOnScreen { reasons.append("终端记着不在屏上") }
            if view.uTermSystemScrollView?.panGestureRecognizer.isEnabled == false { reasons.append("视图被设成不显示") }
            if view.uTermIsSurfaceReleased { reasons.append("surface 被放掉了") }
            return reasons.isEmpty ? nil : "\(step) pane\(index): 前台终端停画了（\(reasons.joined(separator: "、"))）"
        }
    }

    func testVisibleTerminalsKeepDrawingAcrossSplitMoveAndFold() async throws {
        defer { MobileProbeWindow.closeAll() }
        let (work, win) = try await mount()
        let folded = CGSize(width: 466, height: 640)
        var problems = frozen(work, "mounted")
        work.split()
        try await Task.sleep(for: .milliseconds(400))
        problems += frozen(work, "split")
        let ids = work.tabs.map(\.id)
        for round in 1...3 {
            work.activate(ids[round % ids.count])
            try await Task.sleep(for: .milliseconds(300))
            work.moveToOtherPane(ids[round % ids.count])
            try await Task.sleep(for: .milliseconds(400))
            problems += frozen(work, "move\(round)")
            try await resize(win, folded)
            problems += frozen(work, "fold\(round)")
            try await resize(win, portrait)
            problems += frozen(work, "unfold\(round)")
            if work.panes.count < 2 {
                work.split()
                try await Task.sleep(for: .milliseconds(400))
                problems += frozen(work, "resplit\(round)")
            }
        }
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
        // 新开的标签的终端视图挂进了窗口、按真实窗格排过版（换引擎之前这里核的是「视图已经挂到控制器上」；
        // 现在视图由控制器自己建、恒在，等价的是它真的上了屏）。
        XCTAssertNotNil(tab.controller.terminal.view.window, "运行中新开的标签，终端视图没挂进窗口")
        XCTAssertTrue(tab.controller.terminal.view.hasHostedLayout, "运行中新开的标签，终端视图没按窗格排过版")
        try await resize(win, landscape)
        XCTAssertEqual(misplaced(work, win, "live-opened"), [])
        for tab in work.terminalTabs { tab.controller.close() }
    }

    /// 快捷键整排都能横向滚动，包括 ctrl / alt，一格窄到放不下时也够得到每个键（收起键盘按钮除外）。
    func testKeyBarScrollsAsOneRow() async throws {
        defer { MobileProbeWindow.closeAll() }
        let (controller, _) = MobileFakeTerminal.controller(.idle)
        let width: CGFloat = 260
        let (win, _) = MobileProbeWindow.make(size: CGSize(width: width, height: 60), placement: .visibleOnScreen,
                                              isolateHost: true, rootView: TerminalKeyBar(controller: controller))
        try await Task.sleep(for: .milliseconds(400))
        let scroll = try XCTUnwrap(Self.firstScrollView(in: win))
        let frame = scroll.convert(scroll.bounds, to: win)
        // 两头各固定一个键（`MKeyBar`）：左边是面板入口（按键 / AI 共用，拇指最顺手），右边是收起键盘按钮（741b31e4）。
        // 要先滚过一整排键才够得到的话，就打不开面板、收不了键盘了。分屏后一格很窄，固定的键不能再多。
        XCTAssertLessThanOrEqual(frame.minX, 60, "左边只留面板入口")
        XCTAssertLessThanOrEqual(width - frame.maxX, 60, "右边只留键盘按钮")
        XCTAssertGreaterThan(scroll.contentSize.width, frame.width)
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

    /// 状态栏占着顶行的设备（灵动岛 / 刘海 iPhone、iPad）：工作区不伸进顶部安全区，标签条排在状态栏下面。
    /// 用真窗口、真安全区走一遍 `MChromeMeasurer`，所以结果取决于跑测试的模拟器。
    func testTabStripStaysBelowStatusBarOnNonFoldables() async throws {
        defer { MobileProbeWindow.closeAll() }
        let screen = try XCTUnwrap(MobileProbeWindow.activeScene()?.screen.bounds.size)
        try XCTSkipIf(MChromeGeometry.isUnfoldedPhone(idiom: UIDevice.current.userInterfaceIdiom, screenSize: screen),
                      "展开的 Duo 就是要让标签条进状态行")

        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let h = try XCTUnwrap(MobileFixtures.firstServer(in: c))
        let relay = HostKeyChallengeRelay()
        let store = MobileStore()
        store.showWorkspace = true
        let (work, _) = MobileFakeTerminal.sessions(
            count: 1, hosts: [h],
            script: MobileFakeTerminalScript(linesPerSecond: 200, seconds: 1, corpus: .ansiColor),
            container: c, relay: relay)
        for tab in work.terminalTabs { _ = await MobileFakeTerminal.waitUntilConnected(tab.controller) }
        let root = WorkspaceScreen().environment(store).environment(relay).environment(work)
            .environment(\.mAccent, M.accent).modelContainer(c).mMeasuresChrome()
        let (win, host) = MobileProbeWindow.make(placement: .visibleOnScreen, isolateHost: true, rootView: root)
        host.safeAreaRegions = .all
        try await Task.sleep(for: .seconds(3))

        let terminal = try XCTUnwrap(work.terminalTabs.first?.controller.terminal)
        let term = terminal.view
        let top = host.view.safeAreaInsets.top
        XCTAssertGreaterThan(top, 0, "这台模拟器竖屏要有顶部安全区")
        // 按行填满会把视图往下挪零头的上半份：减掉它，比的是容器给终端的位置。
        let termTop = term.convert(term.bounds, to: win).minY - terminal.link.rowFillOffset
        let expected = top + WorkspaceTabStrip.height + TerminalSessionBody.terminalInset.vertical
        XCTAssertEqual(termTop, expected, accuracy: 1, "标签条（48pt）要完整排在状态栏下面，且不被撑高")
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
            let lastItem = win.hitTest(CGPoint(x: contentEnd - 10, y: midY), with: nil)
            XCTAssertTrue(lastItem?.isDescendant(of: scroll) ?? false, "滚到底时最后一项要点得到", line: line)
        }
    }

    private static func firstHorizontalScrollView(in view: UIView) -> UIScrollView? {
        // 不按高度认：贴底的滚动条会伸进底部安全区，iPhone 上有 82pt 高。
        if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 0.5 { return scroll }
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
